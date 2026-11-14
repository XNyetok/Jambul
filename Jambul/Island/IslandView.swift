import SwiftUI

struct IslandView: View {
    let model: IslandModel
    @Namespace private var glyphs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the glyph that left its slot beside the notch has reached its place in the open island.
    @State private var glyphLanded = false

    var body: some View {
        let presentation = model.presentation
        let notch = model.notch
        let layout = model.layout
        let shape = IslandShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius)
        let compact = model.compactActivities
        let showsCompact = !compact.isEmpty && (presentation == .compact || presentation == .lifted)
        // The glyph left of the notch, if it has a place in the open island to travel to.
        let glyph = compact.isEmpty || reduceMotion ? nil : CompactContent.leadingGlyph(of: compact)

        ZStack(alignment: .top) {
            // No shadow: its window is only a little larger than the open island and cut the shadow off in a line.
            shape.fill(.black)

            // Clipped, so content never draws outside the island while it morphs.
            ZStack(alignment: .top) {
                if showsCompact, let slotWidth = model.compactSlotWidth, let leadingWidth = model.compactLeadingWidth {
                    // Each slot changes on its own (`CompactContent`), so a countdown that stays holds still.
                    CompactContent(activities: compact, notch: notch, leadingWidth: leadingWidth, slotWidth: slotWidth)
                        .transition(Motion.contentTransition)
                }
                if presentation == .peek, let peek = model.peek {
                    PeekContent(peek: peek)
                        .padding(.top, notch.size.height + 8)
                        .padding(.horizontal, 22)
                        .id(peek.id)
                        .transition(Motion.contentTransition)
                }
                if presentation == .expanded {
                    // Laid out at full size and revealed by the clip, so it doesn't reflow as the island grows.
                    let size = IslandLayout.expandedSize(showsClock: model.isFullScreen)
                    ExpandedContent(model: model)
                        .frame(width: size.width, height: size.height)
                        .transition(Motion.contentTransition)
                }
            }
            .environment(\.islandGlyphInFlight, presentation == .expanded && !glyphLanded ? glyph : nil)
            .overlayPreferenceValue(IslandGlyphsShown.self, alignment: .top) { shown in
                // The glyph left of the notch, over the content: laid out in its slot as `CompactContent` would, and in
                // the open island moved to its own place if it has one, where it gives way once it lands to the glyph
                // that belongs there.
                let place = presentation == .expanded ? glyph.flatMap { shown[$0] } : nil
                if !compact.isEmpty, showsCompact || place != nil, let slotWidth = model.compactSlotWidth,
                   let leadingWidth = model.compactLeadingWidth {
                    // Landed, it is hidden but stays as it is, ticking or blinking unseen while the island is open:
                    // told that nobody can see it, a glyph could trade one view for another, and the new one would
                    // start its way back from the slot rather than fly there.
                    let isShown = showsCompact || !glyphLanded
                    let inset = IslandLayout.compactInset(notch)
                    HStack(spacing: 0) {
                        IslandGlyphFlyer(glyph: CompactContent.leading(of: compact), place: place, glyphs: glyphs)
                            .frame(width: leadingWidth, height: IslandLayout.compactGlyphHeight)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, inset)
                    .frame(width: notch.size.width + leadingWidth + slotWidth + 2 * inset, height: notch.compactHeight)
                    // On its own short fade either way, so it is there as soon as it sets off back.
                    .animation(Motion.glyphLanding) { $0.opacity(isShown ? 1 : 0) }
                    .foregroundStyle(.white)
                    .id(CompactContent.leadingID(of: compact))
                    .transition(Motion.contentTransition)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
            .clipShape(shape)
            .environment(\.islandIsVisible, model.isVisible)
            .environment(\.islandGlyphs, glyphs)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .contentShape(shape)
        .onHover { model.pointer(.island, isInside: $0) }
        .onTapGesture { model.clicked() }
        .offset(x: layout.xOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .task(id: FlightPhase(presentation: presentation, showsCompact: showsCompact)) {
            // Open, the glyph has landed once its flight is over; back beside the notch, it is ready to fly again.
            if presentation == .expanded {
                try? await Task.sleep(for: Motion.glyphFlight)
                if !Task.isCancelled { withAnimation(Motion.glyphLanding) { glyphLanded = true } }
            } else if showsCompact {
                glyphLanded = false
            }
        }
    }
}

/// What decides whether the glyph left of the notch has landed: where the island is, and whether it has such a glyph.
private struct FlightPhase: Equatable {
    let presentation: IslandPresentation
    let showsCompact: Bool
}

#if DEBUG
private let previewNotch = NotchMetrics(size: CGSize(width: 179, height: 32), compactHeight: 33)

private struct IslandPreview: View {
    let model: IslandModel

    var body: some View {
        let canvas = IslandLayout.canvasSize(previewNotch)
        IslandView(model: model)
            .frame(width: canvas.width, height: canvas.height)
            .background(.indigo.gradient)
    }
}

#Preview("Hover") {
    IslandPreview(model: IslandModel(notch: previewNotch, activities: ActivityCenter()))
}

#Preview("Compact") {
    let activities = ActivityCenter()
    let demo = DemoActivity()
    demo.isLive = true
    activities.register(demo)
    return IslandPreview(model: IslandModel(notch: previewNotch, activities: activities))
}

#Preview("Peek") {
    let peek = Peek(symbol: "bolt.fill", tint: .green, title: "Charging", detail: "80%")
    return IslandPreview(model: IslandModel(notch: previewNotch, activities: ActivityCenter(),
                                            presentation: .peek, peek: peek))
}

/// A center with Jambul's tabs, the timer or Keep Awake on if asked, the battery with a reading, and the usage limits
/// with two subscriptions. Neither the timer nor Keep Awake holds the Mac awake or the screen on, which they would for as
/// long as the preview lives, and nothing is remembered.
@MainActor
private func previewActivities(timer running: Bool = false, keepAwake on: Bool = false) -> ActivityCenter {
    let activities = ActivityCenter()
    let home = HomeActivity(activities: activities)
    let timer = TimerActivity(activities: activities, keepsMacAwake: false)
    let keepAwake = KeepAwakeActivity(activities: activities, defaults: UserDefaults(suiteName: "preview") ?? .standard,
                                      bootSession: nil, holdsScreen: false)
    let battery = BatteryActivity(activities: activities)
    let usage = UsageActivity(activities: activities)
    activities.registerJambulsActivities(home: home, usage: usage, agent: AgentActivity(activities: activities),
                                         keepAwake: keepAwake, timer: timer, battery: battery)
    if running { timer.start(.seconds(25 * 60)) }
    if on { keepAwake.start(since: .now.addingTimeInterval(-65 * 60)) } else { keepAwake.stop() }
    battery.update(PowerState(percent: 76, isOnExternalPower: false))
    usage.enabled = [.claude, .antigravity]
    let resets = Date.now.addingTimeInterval(3 * 3_600)
    usage.record(UsageReading(provider: .claude, windows: [UsageWindow(id: "five_hour", label: "5h", used: 0.42,
                                                                       resetsAt: resets)], measuredAt: .now))
    usage.record(UsageReading(provider: .antigravity, windows: [UsageWindow(id: "weekly", label: "wk", used: 0.18,
                                                                            resetsAt: resets)], measuredAt: .now))
    return activities
}

/// The island open on the tab with this id, as a click on it leaves it.
@MainActor
private func openIsland(on tab: String, _ activities: ActivityCenter) -> IslandModel {
    let model = IslandModel(notch: previewNotch, activities: activities, presentation: .expanded)
    model.selectTab(tab)
    return model
}

#Preview("Home") {
    IslandPreview(model: IslandModel(notch: previewNotch, activities: previewActivities(keepAwake: true),
                                     presentation: .expanded))
}

#Preview("Timer Tab") {
    IslandPreview(model: openIsland(on: "timer", previewActivities()))
}

#Preview("Timer") {
    IslandPreview(model: IslandModel(notch: previewNotch, activities: previewActivities(timer: true)))
}

#Preview("Timer Expanded") {
    IslandPreview(model: openIsland(on: "timer", previewActivities(timer: true)))
}

#Preview("Keep Awake") {
    IslandPreview(model: IslandModel(notch: previewNotch, activities: previewActivities(keepAwake: true)))
}

#Preview("Keep Awake Expanded") {
    IslandPreview(model: openIsland(on: "keepAwake", previewActivities(keepAwake: true)))
}

#Preview("Timer and Keep Awake") {
    IslandPreview(model: IslandModel(notch: previewNotch, activities: previewActivities(timer: true, keepAwake: true)))
}
#endif
