import SwiftUI

extension TimerActivity {
    var compactLeading: some View {
        TimerTicks(timer: self) { _, fraction in
            TimerRing(fraction: fraction, lineWidth: 2.5)
                .frame(width: 16, height: 16)
        }
        .opacity(shown.isPaused ? Self.pausedOpacity : 1)
    }

    /// In the ring's color, so the two sides beside the notch read as one countdown.
    var compactTrailing: some View {
        TimerTicks(timer: self) { remaining, _ in
            Text(Self.format(remaining))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .fixedSize()
        }
        .foregroundStyle(tint)
        .opacity(shown.isPaused ? Self.pausedOpacity : 1)
    }

    /// The quick starts while idle; the countdown and its controls once started. The ring stays on the left either
    /// way, where it sits beside the notch.
    var tab: some View {
        ZStack {
            if state == .idle {
                TimerStartTab(timer: self)
                    .transition(Motion.contentTransition)
            } else {
                TimerCountdownTab(timer: self)
                    .transition(Motion.contentTransition)
            }
        }
        .animation(Motion.tabStateChange, value: state == .idle)
        .foregroundStyle(.white)
    }

    /// Its card on Home: the time left in its color, ticking like the countdown beside the notch, or "Off".
    var homeCard: some View {
        HomeCardContent(state.isPaused ? Text("Paused") : Text("Timer")) {
            Image(systemName: tabSymbol)
                .foregroundStyle(state == .idle ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .islandGlyph(compactGlyph)
        } value: {
            if state == .idle {
                Text("Off")
                    .foregroundStyle(.secondary)
            } else {
                TimerTicks(timer: self) { remaining, _ in
                    Text(Self.format(remaining))
                }
                .foregroundStyle(tint)
                .opacity(state.isPaused ? Self.pausedOpacity : 1)
            }
        }
    }

    /// "4:59", or "1:02:03" from an hour up, like the system's own timer text. Seconds round up as they do there, so
    /// the display reaches 0:00 just as the time is up.
    static func format(_ remaining: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        // Ticks land on whole seconds before the end, give or take a rounding error that mustn't add a second.
        let seconds = max(Int((remaining - 0.001).rounded(.up)), 0)
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds).formatted(.time(pattern: pattern).locale(locale))
    }

    /// The first tick of the display: a whole number of seconds before the end, so every tick lands just as a second
    /// of the countdown runs out.
    static func firstTick(of interval: ClosedRange<Date>) -> Date {
        let seconds = interval.upperBound.timeIntervalSince(interval.lowerBound).rounded(.up)
        return interval.upperBound.addingTimeInterval(-seconds)
    }

    fileprivate static let pausedOpacity = 0.5
}

/// The timer's tab while idle: an empty ring, and the quick starts in the timer's color.
private struct TimerStartTab: View {
    let timer: TimerActivity

    var body: some View {
        HStack(spacing: 14) {
            TimerRing(fraction: 0, lineWidth: IslandLayout.tabRingWidth)
                .frame(width: IslandLayout.tabGlyphHeight, height: IslandLayout.tabGlyphHeight)
                .islandGlyph(timer.compactGlyph)
            VStack(alignment: .leading, spacing: 2) {
                Text("Timer")
                    .font(IslandLayout.tabTitleFont)
                Text("Choose a length")
                    .font(IslandLayout.tabDetailFont)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(TimerActivity.presets, id: \.self) { preset in
                    Button { timer.start(preset) } label: {
                        Text(preset, format: .units(allowed: [.minutes], width: .abbreviated))
                    }
                }
            }
            .buttonStyle(.islandProminent(tint: timer.tint))
        }
    }
}

/// The timer's tab once started: the ring and the time left, when it ends, and its controls.
private struct TimerCountdownTab: View {
    let timer: TimerActivity

    var body: some View {
        HStack(spacing: 14) {
            TimerTicks(timer: timer) { remaining, fraction in
                HStack(spacing: 14) {
                    TimerRing(fraction: fraction, lineWidth: IslandLayout.tabRingWidth)
                        .frame(width: IslandLayout.tabGlyphHeight, height: IslandLayout.tabGlyphHeight)
                        .islandGlyph(timer.compactGlyph)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(TimerActivity.format(remaining))
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .fixedSize()
                        Text(TimerActivity.endLine(for: timer.shown))
                            .font(IslandLayout.tabDetailFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .opacity(timer.shown.isPaused ? TimerActivity.pausedOpacity : 1)
            Spacer(minLength: 0)
            TimerControls(timer: timer)
        }
    }
}

extension TimerActivity {
    /// Below the countdown: when it ends, like "Ends 16:30", or that it is paused.
    static func endLine(for state: State, locale: Locale = .autoupdatingCurrent) -> String {
        switch state {
        case .idle: ""
        case .paused: String(localized: "Paused")
        case .running(let interval):
            String(localized: "Ends \(interval.upperBound.formatted(.dateTime.hour().minute().locale(locale)))")
        }
    }
}

/// Draws `content` for the time left, and again on each second the countdown passes while it runs. A paused or idle
/// timer draws once, and so does one nobody can see (`islandIsVisible`). It follows `shown`, so a countdown that has
/// just stopped keeps its time while it leaves.
///
/// Measured on the MacBook Air: about 0.35% CPU while running, and nothing while paused. The system's own timer text
/// cost more, and rolling digits kept SwiftUI drawing at 60 fps, with memory growing, for as long as the timer ran.
struct TimerTicks<Content: View>: View {
    let timer: TimerActivity
    @ViewBuilder let content: (_ remaining: TimeInterval, _ fraction: Double) -> Content
    @Environment(\.islandIsVisible) private var isVisible

    var body: some View {
        let state = timer.shown
        if let interval = Self.ticking(state, isVisible: isVisible) {
            TimelineView(.periodic(from: TimerActivity.firstTick(of: interval), by: 1)) { context in
                content(state.remaining(at: context.date), state.fraction(at: context.date))
            }
        } else {
            let now = Date.now
            content(state.remaining(at: now), state.fraction(at: now))
        }
    }

    /// The countdown to redraw each second, if any: a running one that someone can see.
    static func ticking(_ state: TimerActivity.State, isVisible: Bool) -> ClosedRange<Date>? {
        guard isVisible, case .running(let interval) = state else { return nil }
        return interval
    }
}

/// What's left of the countdown, as an arc that shrinks back toward the top.
struct TimerRing: View {
    var fraction: Double
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(.orange.opacity(0.3), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.orange, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// +1 minute, pause or resume, and stop, beside the countdown on the timer's tab.
struct TimerControls: View {
    let timer: TimerActivity

    var body: some View {
        HStack(spacing: 10) {
            Button("+1 min") { timer.addMinute() }
                .buttonStyle(.island())
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
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.islandIcon())
            .accessibilityLabel(Text("Stop"))
        }
    }
}
