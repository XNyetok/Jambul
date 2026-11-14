import SwiftUI

/// The live activities beside the notch: leading slot, a gap for the notch itself, trailing slot. Alone, an activity
/// takes both slots; with two, the more important one keeps the right, and the other shows its glyph on the left. Each
/// slot is as wide as what it holds, so both sit close to the notch.
struct CompactContent: View {
    /// The most important first; only the first two show.
    let activities: [any IslandActivity]
    let notch: NotchMetrics
    let leadingWidth: CGFloat
    let slotWidth: CGFloat
    @Environment(\.islandGlyphs) private var glyphs

    var body: some View {
        // Each slot is known by what fills it, so a slot that keeps its content holds still while the other changes.
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                // In the island the glyph is drawn over the content, where this slot is (`IslandGlyphFlyer`).
                if glyphs == nil {
                    Self.leading(of: activities)
                        .id(Self.leadingID(of: activities))
                        .transition(Motion.contentTransition)
                }
            }
            .frame(width: leadingWidth, alignment: .leading)
            Color.clear
                .frame(width: notch.size.width)
            ZStack(alignment: .trailing) {
                AnyView(activities[0].compactTrailing)
                    .id(activities[0].id)
                    .transition(Motion.contentTransition)
            }
            .frame(width: slotWidth, alignment: .trailing)
        }
        .padding(.horizontal, IslandLayout.compactInset(notch))
        .frame(height: notch.compactHeight)
        .foregroundStyle(.white)
    }

    /// What shows left of the notch: the second activity's glyph, or the only one's.
    static func leading(of activities: [any IslandActivity]) -> AnyView {
        activities.count > 1 ? activities[1].compactMinimal : AnyView(activities[0].compactLeading)
    }

    /// The minimal glyph and an activity's own leading view differ even for the same activity.
    static func leadingID(of activities: [any IslandActivity]) -> String {
        activities.count > 1 ? "\(activities[1].id).minimal" : activities[0].id
    }

    /// What that glyph is, if the open island shows it too.
    static func leadingGlyph(of activities: [any IslandActivity]) -> String? {
        (activities.count > 1 ? activities[1] : activities[0]).compactGlyph
    }
}

struct PeekContent: View {
    let peek: Peek

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                PeekIcon(peek: peek)
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle = peek.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let detail = peek.detail {
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let progress = peek.progress {
                PeekProgress(fraction: progress, tint: peek.tint, drains: peek.motion == .bounce)
            }
        }
        .lineLimit(1)
        .foregroundStyle(.white)
    }

    /// The title, with its emphasis in the peek's color.
    private var title: Text {
        guard let emphasis = peek.emphasis, let range = peek.title.range(of: emphasis) else { return Text(peek.title) }
        let before = Text(peek.title[..<range.lowerBound]), after = Text(peek.title[range.upperBound...])
        return Text("\(before)\(Text(emphasis).foregroundStyle(peek.tint))\(after)")
    }
}

/// A peek's symbol or logo, moving once as the peek comes out.
private struct PeekIcon: View {
    let peek: Peek
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false
    @State private var beat = 0
    /// How often the bell has rung, for `ring`: once, as the peek comes out.
    @State private var rings = 0

    var body: some View {
        icon
            // Only a logo is sized; a symbol keeps its own size, so the other peeks don't move.
            .frame(width: peek.logo == nil ? nil : 18, height: peek.logo == nil ? nil : 18)
            .rotationEffect(.degrees(rotation))
            .scaleEffect(scale)
            .opacity(peek.motion == .sleep && arrived ? Motion.Usage.asleepOpacity : 1)
            .phaseAnimator(phases, trigger: beat) { content, phase in
                content
                    .scaleEffect(peek.motion == .pulse ? phase : 1)
                    .offset(x: peek.motion == .shake ? phase : 0, y: peek.motion == .bounce ? phase : 0)
            } animation: { _ in peek.motion == .shake ? Motion.Agent.shake : Motion.Usage.beat }
            .background {
                if peek.motion == .bounce, !reduceMotion { PeekSparks(color: peek.tint) }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(peek.motion == .sleep ? Motion.Usage.fallAsleep : Motion.Usage.turn) { arrived = true }
                if peek.motion != .shake { beat += 1 }
            }
            .task {
                guard peek.motion == .shake, !reduceMotion else { return }
                try? await Task.sleep(for: Motion.Agent.shakeAfter, tolerance: Motion.timerTolerance)
                if !Task.isCancelled { beat += 1 }
            }
            .task {
                guard peek.motion == .ring, !reduceMotion else { return }
                try? await Task.sleep(for: Motion.timerRingAfter, tolerance: Motion.timerTolerance)
                if !Task.isCancelled { rings += 1 }
            }
    }

    @ViewBuilder private var icon: some View {
        if peek.motion == .draw {
            let shown = arrived || reduceMotion
            PeekCheck(tint: peek.tint, scale: shown ? 1 : 0, drawn: shown ? 1 : 0)
        } else if let closing = peek.motion.eyesClosing {
            PeekEyes(tint: peek.tint, closing: closing)
        } else if let logo = peek.logo {
            Image(logo)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: peek.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(peek.tint)
                .symbolEffect(.wiggle, options: .nonRepeating, value: rings)
        }
    }

    private var rotation: Double {
        switch peek.motion {
        case .spin: arrived || reduceMotion ? 0 : Motion.Usage.turnFrom
        case .sleep: arrived ? Motion.Usage.asleepTilt : 0
        default: 0
        }
    }

    private var scale: Double {
        switch peek.motion {
        case .spin: arrived || reduceMotion ? 1 : Motion.Usage.turnScale
        case .sleep: arrived ? Motion.Usage.asleepScale : 1
        default: 1
        }
    }

    /// Scales for a pulse, offsets for a bounce or a shake; with Reduce Motion, only the resting value.
    private var phases: [Double] {
        switch peek.motion {
        case .pulse: reduceMotion ? [1] : Motion.Usage.pulseScales
        case .bounce: reduceMotion ? [0] : Motion.Usage.bounceOffsets
        case .shake: reduceMotion ? [0] : Motion.Agent.shakeOffsets
        default: [1]
        }
    }
}

/// Keep Awake's eyes on a peek: open as it comes out, then closing as `closing` says, once the peek is out of its blur.
private struct PeekEyes: View {
    let tint: Color
    let closing: EyesClosing
    @State private var asleep = false

    var body: some View {
        KeepAwakeEyes(size: .card, isOpen: !asleep, closing: closing, tint: tint, lidColor: tint.opacity(0.7),
                      keepsTheBeat: false)
            .accessibilityHidden(true)
            .task {
                try? await Task.sleep(for: Motion.peekEyesWait, tolerance: Motion.timerTolerance)
                if !Task.isCancelled { asleep = true }
            }
    }
}

/// `checkmark.circle.fill` drawn rather than shown, so it can pop in and draw its check: the circle at `scale` of its
/// size, and the check drawn along `drawn` of its stroke, each animating as it changes. Laid out as the symbol, which it
/// matches once both are 1, so the title sits where it does on other peeks.
struct PeekCheck: View {
    let tint: Color
    let scale: CGFloat
    let drawn: CGFloat
    /// The circle's diameter as a part of the symbol's width, and the check's stroke as a part of the circle's
    /// (measured on the symbol).
    private static let circle: CGFloat = 0.85
    private static let stroke: CGFloat = 0.094

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 17, weight: .semibold))
            .hidden()
            .overlay {
                GeometryReader { proxy in
                    let diameter = proxy.size.width * Self.circle
                    ZStack {
                        Circle().fill(tint)
                        CheckStroke()
                            .trim(from: 0, to: drawn)
                            .stroke(style: StrokeStyle(lineWidth: diameter * Self.stroke, lineCap: .round,
                                                       lineJoin: .round))
                            .blendMode(.destinationOut)
                            .animation(Motion.Agent.checkDraw, value: drawn)
                    }
                    .frame(width: diameter, height: diameter)
                    .compositingGroup()
                    .scaleEffect(scale)
                    .animation(Motion.Agent.checkPop, value: scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
    }
}

/// The check of `checkmark.circle.fill` as one stroke, from its short end down to its corner and up to its long end, so
/// it draws in that order. Measured on the symbol, as parts of its circle.
private struct CheckStroke: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.315, 0.536))
        path.addLine(to: point(0.4475, 0.699))
        path.addLine(to: point(0.681, 0.331))
        return path
    }
}

/// Sparks flying out from a logo that has just come back.
private struct PeekSparks: View {
    let color: Color
    @State private var flown = false

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 3, height: 3)
                    .offset(y: flown ? -Motion.Usage.sparkReach : 0)
                    .rotationEffect(.degrees(Double(index) * 60))
                    .opacity(flown ? 0 : 1)
            }
        }
        .onAppear {
            withAnimation(Motion.Usage.sparks) { flown = true }
        }
    }
}

/// The thin bar under a peek's message, filling to `fraction`, or draining to it from full.
private struct PeekProgress: View {
    let fraction: Double
    let tint: Color
    let drains: Bool
    @State private var shown = false

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.white.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * max(shown ? fraction : (drains ? 1 : 0), 0.02))
                }
        }
        .frame(height: 2)
        .onAppear {
            withAnimation(drains ? Motion.Usage.drain : Motion.Usage.fill) { shown = true }
        }
    }
}

/// The open island: the tabs on both sides of the camera, the day and time right below it while a full-screen app
/// hides the menu bar's, and below that the chosen activity's tab. One activity at a time, so two never mix on one
/// screen; Home, the first tab, sums them all up.
struct ExpandedContent: View {
    let model: IslandModel

    var body: some View {
        let notch = model.notch
        let tabs = model.tabs
        let sides = IslandLayout.tabSides(count: tabs.count)
        let showsClock = model.isFullScreen
        ZStack(alignment: .top) {
            IslandTabBar(tabs: tabs, selected: model.selectedTab,
                         buttonWidth: IslandLayout.tabButtonWidth(count: sides.leading, notch: notch)) {
                model.selectTab($0)
            }
            .padding(.horizontal, IslandLayout.expandedContentInset)
            .frame(height: notch.size.height)

            if showsClock {
                IslandClock()
                    .frame(height: IslandLayout.clockRowHeight)
                    .padding(.top, notch.size.height + IslandLayout.expandedContentTopGap)
                    .transition(.opacity)
            }

            // Centered in what is left below the notch. Each tab is a row centered on its glyph, so the glyph sits in
            // the same place on every tab, however tall the text beside it.
            ZStack {
                if let tab = tabs.first(where: { $0.id == model.selectedTab }) {
                    tab.anyTab
                        .id(tab.id)
                        .transition(Motion.tabContentTransition(arrivingFrom: model.tabArrivesFrom))
                }
            }
            .environment(\.selectIslandTab, SelectTabAction { model.selectTab($0, replacingWhatWasClicked: true) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, notch.size.height + IslandLayout.expandedContentTopGap
                     + (showsClock ? IslandLayout.clockRowHeight : 0))
            .padding(.bottom, IslandLayout.expandedContentBottomInset)
            .padding(.horizontal, IslandLayout.expandedContentInset)
        }
        .foregroundStyle(.white)
    }
}

/// One button per activity, split between the two sides of the camera (`IslandLayout.tabSides`): each side lines up
/// with the edge of the content below it, the left on its left and the right on its right. A symbol shows in color
/// while its activity has something going on (`tabTint`), chosen or not; the chosen tab sits on a highlight that
/// slides over as the choice changes, across the camera too.
struct IslandTabBar: View {
    let tabs: [any IslandActivity]
    let selected: String?
    /// Each button's width, narrower than `IslandLayout.tabButtonSize` when more tabs must fit (`tabButtonWidth`).
    var buttonWidth = IslandLayout.tabButtonSize.width
    let select: (String) -> Void
    @Namespace private var highlight

    var body: some View {
        let sides = IslandLayout.tabSides(count: tabs.count)
        HStack(spacing: 0) {
            IslandTabGroup(tabs: Array(tabs.prefix(sides.leading)), selected: selected, buttonWidth: buttonWidth,
                           highlight: highlight, select: select)
            Spacer(minLength: 0)
            IslandTabGroup(tabs: Array(tabs.suffix(sides.trailing)), selected: selected, buttonWidth: buttonWidth,
                           highlight: highlight, select: select)
        }
    }
}

/// The tabs on one side of the camera.
struct IslandTabGroup: View {
    let tabs: [any IslandActivity]
    let selected: String?
    var buttonWidth = IslandLayout.tabButtonSize.width
    let highlight: Namespace.ID
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: IslandLayout.tabButtonSpacing) {
            ForEach(tabs, id: \.id) { activity in
                let isSelected = activity.id == selected
                Button { select(activity.id) } label: {
                    IslandTabLabel(symbol: activity.tabSymbol, tint: activity.tabTint, isSelected: isSelected,
                                   width: buttonWidth)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(.white.opacity(0.15))
                                    .matchedGeometryEffect(id: "highlight", in: highlight)
                            }
                        }
                }
                .buttonStyle(IslandTabButtonStyle())
                .accessibilityLabel(Text(activity.title))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// A tab's symbol: in the activity's color while it has something going on, otherwise white on the chosen tab and dim on
/// the others, a little brighter under the pointer. Color says what is live; the highlight says which tab is chosen.
private struct IslandTabLabel: View {
    let symbol: String
    let tint: Color?
    let isSelected: Bool
    let width: CGFloat
    @State private var isHovered = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint ?? .white.opacity(isSelected ? 1 : isHovered ? 0.72 : 0.5))
            .frame(width: width, height: IslandLayout.tabButtonSize.height)
            .onHover { isHovered = $0 }
            .animation(Motion.tabHover, value: isHovered)
    }
}

/// A tab's button: the whole pill is its hit area, so a click anywhere on it changes the tab rather than toggling the
/// island, and it sinks a little while pressed, like the island's other buttons.
private struct IslandTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Motion.buttonPress, value: configuration.isPressed)
    }
}

/// The day and time, for while a full-screen app hides the menu bar's clock. Redrawn each minute while it shows, since
/// the island can stay open across one.
struct IslandClock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            IslandClockFace(date: context.date)
        }
    }
}

/// What `IslandClock` shows at `date`, like "Mon 2  09:41", as the person's locale writes it, centered below the camera.
/// It once sat beside the notch, where a 12-hour clock's AM and PM could push the day and date past the 106.5 pt there;
/// below the camera they fit, but in a narrower room the date still gives way first, then the day, never the time.
struct IslandClockFace: View {
    let date: Date

    /// How much of the day goes before the time, most first. The clock shows the first that fits.
    static var days: [Date.FormatStyle?] {
        [.dateTime.weekday(.abbreviated).day(), .dateTime.weekday(.abbreviated), nil]
    }

    var body: some View {
        let days = Self.days
        ViewThatFits(in: .horizontal) {
            IslandClockLine(date: date, day: days[0])
            IslandClockLine(date: date, day: days[1])
            IslandClockLine(date: date, day: days[2])
        }
    }
}

/// The time at `date`, after the day written in `day`'s format if there is one.
struct IslandClockLine: View {
    let date: Date
    let day: Date.FormatStyle?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let day {
                Text(date, format: day)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }
}
