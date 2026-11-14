import SwiftUI

extension TimerActivity {
    /// The dial, small: the slice of an hour that is left.
    var compactLeading: some View {
        TimerTicks(timer: self) { remaining in
            TimerMiniDial(fraction: Self.dialFraction(remaining))
                .frame(width: IslandLayout.compactGlyphHeight, height: IslandLayout.compactGlyphHeight)
        }
        .opacity(shown.isPaused ? Self.pausedOpacity : 1)
    }

    /// In the dial's color, so the two sides beside the notch read as one countdown.
    var compactTrailing: some View {
        TimerTicks(timer: self) { remaining in
            Text(Self.format(remaining))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .fixedSize()
        }
        .foregroundStyle(tint)
        .opacity(shown.isPaused ? Self.pausedOpacity : 1)
    }

    /// The dial on the left, where it sits beside the notch; the quick starts while idle, and the countdown and its
    /// controls once started.
    var tab: some View {
        TimerTab(timer: self)
    }

    /// Its card on Home: the small dial and the time left in its color, ticking like the countdown beside the notch, or
    /// an empty dial and "Off".
    var homeCard: some View {
        HomeCardContent(state.isPaused ? Text("Paused") : Text("Timer")) {
            TimerTicks(timer: self) { remaining in
                TimerMiniDial(fraction: self.state == .idle ? 0 : Self.dialFraction(remaining),
                              isOn: self.state != .idle)
                    .frame(width: HomeCardStyle.glyphHeight, height: HomeCardStyle.glyphHeight)
            }
            .opacity(state.isPaused ? Self.pausedOpacity : 1)
            .islandGlyph(compactGlyph)
        } value: {
            if state == .idle {
                Text("Off")
                    .foregroundStyle(.secondary)
            } else {
                TimerTicks(timer: self) { remaining in
                    Text(Self.format(remaining))
                }
                .foregroundStyle(tint)
                .opacity(state.isPaused ? Self.pausedOpacity : 1)
            }
        }
    }

    /// How much of the dial the slice covers with `remaining` seconds left: the minutes of an hour, as on a kitchen
    /// timer, so 25 minutes is five twelfths of the dial and 5 minutes a sliver. An hour or more fills it.
    static func dialFraction(_ remaining: TimeInterval) -> Double {
        min(max(remaining / 3_600, 0), 1)
    }

    /// "4:59", or "1:02:03" from an hour up, like the system's own timer text. Seconds round up as they do there, so
    /// the display reaches 0:00 just as the time is up.
    static func format(_ remaining: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let pattern: Duration.TimeFormatStyle.Pattern = showsHours(remaining) ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(shownSeconds(remaining)).formatted(.time(pattern: pattern).locale(locale))
    }

    /// Whether the countdown shows hours, like "1:00:00", from an hour up.
    static func showsHours(_ remaining: TimeInterval) -> Bool {
        shownSeconds(remaining) >= 3_600
    }

    /// The whole seconds shown. Ticks land on whole seconds before the end, give or take a rounding error that mustn't
    /// add a second.
    private static func shownSeconds(_ remaining: TimeInterval) -> Int {
        max(Int((remaining - 0.001).rounded(.up)), 0)
    }

    /// A countdown's length, short, like "25 min" or "1 hr, 30 min", as "Timer done" says it.
    static func lengthText(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated).locale(locale))
    }

    /// A quick start's length in words, like "25 minutes" or "1 hour", as its tab says it under the pointer.
    static func lengthTitle(_ length: Duration, locale: Locale = .autoupdatingCurrent) -> String {
        length.formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(locale))
    }

    /// The first tick of the display: a whole number of seconds before the end, so every tick lands just as a second
    /// of the countdown runs out.
    static func firstTick(of interval: ClosedRange<Date>) -> Date {
        let seconds = interval.upperBound.timeIntervalSince(interval.lowerBound).rounded(.up)
        return interval.upperBound.addingTimeInterval(-seconds)
    }

    fileprivate static let pausedOpacity = 0.5
}

extension TimerActivity {
    /// Below the countdown: when it ends, like "Ends 16:30", or that it is paused.
    static func endLine(for state: State, locale: Locale = .autoupdatingCurrent) -> String {
        switch state {
        case .idle: ""
        case .paused: String(localized: "Paused")
        case .running(let interval): endLine(at: interval.upperBound, locale: locale)
        }
    }

    /// "Ends 16:30".
    static func endLine(at end: Date, locale: Locale = .autoupdatingCurrent) -> String {
        String(localized: "Ends \(end.formatted(.dateTime.hour().minute().locale(locale)))")
    }
}

/// The timer's tab: the dial, then what to start or the countdown. The dial stays one view throughout, so its slice
/// winds from a quick start under the pointer into the countdown, and back to empty as the countdown stops.
private struct TimerTab: View {
    let timer: TimerActivity
    /// The quick start under the pointer, shown on the dial and below the name before a click.
    @State private var preview: Duration?

    var body: some View {
        let isIdle = timer.state == .idle
        HStack(spacing: 16) {
            TimerTicks(timer: timer) { remaining in
                TimerDial(fraction: isIdle ? TimerActivity.dialFraction(preview.map { $0 / .seconds(1) } ?? 0)
                                           : TimerActivity.dialFraction(remaining),
                          glyph: timer.compactGlyph)
            }
            // Second by second the slice moves without animation; these are the moves it winds through.
            .animation(Motion.dialWind, value: preview)
            .animation(Motion.dialWind, value: timer.shown.total)
            .animation(Motion.dialWind, value: isIdle)
            .opacity(!isIdle && timer.shown.isPaused ? TimerActivity.pausedOpacity : 1)
            ZStack(alignment: .leading) {
                if isIdle {
                    TimerStarts(timer: timer, preview: $preview)
                        .transition(Motion.contentTransition)
                } else {
                    TimerCountdown(timer: timer)
                        .transition(Motion.contentTransition)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.tabStateChange, value: isIdle)
        }
        .foregroundStyle(.white)
        // A quick start the pointer crossed as the countdown took the buttons' place would otherwise wind the dial to
        // it once the countdown stops.
        .onChange(of: isIdle) { preview = nil }
    }
}

/// The quick starts: round buttons as on Apple Watch, the one under the pointer shown on the dial with when it would
/// end, before a click starts it. The last length started is ringed.
private struct TimerStarts: View {
    let timer: TimerActivity
    @Binding var preview: Duration?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(preview.map { TimerActivity.lengthTitle($0) } ?? String(localized: "Timer"))
                .font(IslandLayout.tabTitleFont)
            Group {
                if let preview {
                    // When it would end, kept right while the pointer rests on it across a minute.
                    TimelineView(.everyMinute) { context in
                        Text(TimerActivity.endLine(at: context.date.addingTimeInterval(preview / .seconds(1))))
                    }
                } else {
                    Text("Pick a length")
                }
            }
            .font(IslandLayout.tabDetailFont)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
            HStack(spacing: TimerChipStyle.spacing) {
                ForEach(TimerActivity.presets, id: \.self) { length in
                    Button {
                        preview = nil
                        timer.start(length)
                    } label: {
                        TimerChipLabel(length: length)
                    }
                    .buttonStyle(TimerChipStyle(isLast: timer.lastLength == length))
                    .onHover { if $0 { preview = length } }
                    .accessibilityLabel(Text("Start \(TimerActivity.lengthTitle(length))"))
                }
            }
            // The preview clears only as the pointer leaves the row, not in the gaps between buttons, where it would
            // flicker back to "Pick a length" and the dial would start to unwind.
            .contentShape(.rect)
            .onHover { if !$0 { preview = nil } }
            .padding(.top, 10)
        }
        .lineLimit(1)
    }
}

/// A quick start's minutes over "min".
private struct TimerChipLabel: View {
    let length: Duration

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "\(Int(length / .seconds(60)))")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("min")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.75)
        }
    }
}

/// A quick start: a flat orange circle that brightens under the pointer and sinks while pressed, like the island's
/// other buttons, with the whole circle as its hit area. The last length started has a ring.
private struct TimerChipStyle: ButtonStyle {
    static let size: CGFloat = 34
    static let spacing: CGFloat = 6

    let isLast: Bool

    func makeBody(configuration: Configuration) -> some View {
        TimerChip(configuration: configuration, isLast: isLast)
    }
}

private struct TimerChip: View {
    let configuration: ButtonStyleConfiguration
    let isLast: Bool
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(.orange)
            .frame(width: TimerChipStyle.size, height: TimerChipStyle.size)
            .background(.orange.opacity(configuration.isPressed ? 0.34 : isHovered ? 0.28 : 0.16), in: .circle)
            .overlay {
                if isLast { Circle().strokeBorder(.orange.opacity(0.8), lineWidth: 1.6) }
            }
            .contentShape(.circle)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .onHover { isHovered = $0 }
            .animation(Motion.buttonPress, value: configuration.isPressed)
            .animation(Motion.tabHover, value: isHovered)
    }
}

/// The countdown: the time left and when it ends, then +1, pause or resume, and cancel.
private struct TimerCountdown: View {
    let timer: TimerActivity

    var body: some View {
        HStack(spacing: 12) {
            TimerTicks(timer: timer) { remaining in
                VStack(alignment: .leading, spacing: 2) {
                    Text(TimerActivity.format(remaining))
                        .font(TimerActivity.showsHours(remaining) ? IslandLayout.tabLongCountdownFont
                              : IslandLayout.tabCountdownFont)
                        .monospacedDigit()
                        .fixedSize()
                    Text(TimerActivity.endLine(for: timer.shown))
                        .font(IslandLayout.tabDetailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .opacity(timer.shown.isPaused ? TimerActivity.pausedOpacity : 1)
            Spacer(minLength: 0)
            TimerControls(timer: timer)
        }
    }
}

/// Draws `content` for the time left, and again on each second the countdown passes while it runs. A paused or idle
/// timer draws once, and so does one nobody can see (`islandIsVisible`). It follows `shown`, so a countdown that has
/// just stopped keeps its time while it leaves.
///
/// One `TimelineView` throughout, waiting a day between redraws while nothing counts, so what it draws stays one view
/// as the countdown starts, pauses or stops, and can move between them on an animation, like the dial's slice.
///
/// Measured on the MacBook Air: about 0.35% CPU while running, and nothing while paused. The system's own timer text
/// cost more, and rolling digits kept SwiftUI drawing at 60 fps, with memory growing, for as long as the timer ran.
struct TimerTicks<Content: View>: View {
    let timer: TimerActivity
    @ViewBuilder let content: (_ remaining: TimeInterval) -> Content
    @Environment(\.islandIsVisible) private var isVisible

    var body: some View {
        let shown = timer.shown
        let interval = Self.ticking(timer, isVisible: isVisible)
        TimelineView(.periodic(from: interval.map { TimerActivity.firstTick(of: $0) } ?? .now,
                               by: interval == nil ? Self.restingRedraw : 1)) { context in
            content(shown.remaining(at: context.date))
        }
    }

    /// The countdown to redraw each second, if any: a running one that someone can see. It goes by the timer's state,
    /// not by what it shows, which keeps a countdown that has stopped or finished until the next one starts.
    static func ticking(_ timer: TimerActivity, isVisible: Bool) -> ClosedRange<Date>? {
        guard isVisible, case .running(let interval) = timer.state else { return nil }
        return interval
    }

    /// How often it redraws while nothing counts: a day, which in practice is never, since anything that changes what
    /// it draws gives it a new start.
    static var restingRedraw: TimeInterval { 86_400 }
}

/// The timer's dial on its tab: a faint orange face with a mark every five minutes, a longer one every quarter hour,
/// and the slice of the hour that is left, shrinking back toward the top as on a kitchen timer.
struct TimerDial: View {
    var fraction: Double
    /// The small dial beside the notch, which lands on the slice's circle as the island opens: its slice fills its own
    /// circle, as this one's fills the slice's circle, so the two meet edge to edge.
    var glyph: String?

    var body: some View {
        let size = IslandLayout.tabDialSize
        ZStack {
            Circle()
                .fill(.orange.opacity(0.12))
            TimerDialMarks()
                .stroke(.white.opacity(0.34), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            TimerSlice(fraction: fraction)
                .fill(.orange)
                .frame(width: size * (1 - 2 * Self.sliceInset), height: size * (1 - 2 * Self.sliceInset))
                .islandGlyph(glyph)
            Circle()
                .fill(.white)
                .frame(width: size * Self.knob, height: size * Self.knob)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// From the face's edge to the slice's, and the knob in the middle, as parts of the dial's size.
    static let sliceInset: CGFloat = 0.125
    static let knob: CGFloat = 0.1
}

/// The dial small, beside the notch and on Home: an orange disc with the slice of the hour that is left, or a dim disc
/// while the timer is off.
struct TimerMiniDial: View {
    var fraction: Double
    var isOn = true

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? Color.orange.opacity(0.3) : Color.white.opacity(0.2))
            TimerSlice(fraction: fraction)
                .fill(.orange)
        }
        .accessibilityHidden(true)
    }
}

/// A slice of the circle from the top, clockwise, covering `fraction` of it.
struct TimerSlice: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let fraction = min(max(fraction, 0), 1)
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) / 2
        guard fraction > 0.0005 else { return Path() }
        guard fraction < 0.9995 else {
            return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius,
                                          height: 2 * radius))
        }
        var path = Path()
        path.move(to: center)
        // Counterclockwise as Core Graphics counts, which is clockwise on screen, where y grows downward.
        path.addArc(center: center, radius: radius, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// The dial's marks: twelve, one every five minutes, the four at the quarter hours longer.
struct TimerDialMarks: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) / 2
        var path = Path()
        for mark in 0..<12 {
            let angle = Double(mark) * .pi / 6 - .pi / 2
            let inner = radius * (mark % 3 == 0 ? 0.8 : 0.86), outer = radius * 0.94
            path.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
            path.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
        }
        return path
    }
}

/// +1 minute, pause or resume, and cancel, beside the countdown on the timer's tab: round, as on the iPhone's Dynamic
/// Island, with pause the one in the timer's color.
struct TimerControls: View {
    let timer: TimerActivity

    var body: some View {
        HStack(spacing: 8) {
            Button { timer.addMinute() } label: {
                Text(verbatim: "+1")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.islandIcon())
            .accessibilityLabel(Text("Add a Minute"))
            Button {
                if timer.isPaused { timer.resume() } else { timer.pause() }
            } label: {
                Image(systemName: timer.shown.isPaused ? "play.fill" : "pause.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .animation(Motion.valueChange, value: timer.shown.isPaused)
            }
            .buttonStyle(.islandIcon(tint: timer.tint, prominent: true))
            .accessibilityLabel(timer.shown.isPaused ? Text("Resume") : Text("Pause"))
            Button { timer.stop() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.islandIcon())
            .accessibilityLabel(Text("Cancel"))
        }
    }

}
