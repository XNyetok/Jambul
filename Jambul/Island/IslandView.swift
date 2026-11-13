import SwiftUI

struct IslandView: View {
    let model: IslandModel

    var body: some View {
        let presentation = model.presentation
        let notch = model.notch
        let layout = model.layout
        let shape = IslandShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius)

        ZStack(alignment: .top) {
            // No shadow: its window is only a little larger than the open island and cut the shadow off in a line.
            shape.fill(.black)

            // Clipped, so content never draws outside the island while it morphs.
            ZStack(alignment: .top) {
                let compact = model.compactActivities
                if !compact.isEmpty, let slotWidth = model.compactSlotWidth,
                   presentation == .compact || presentation == .lifted {
                    // Each slot changes on its own (`CompactContent`), so a countdown that stays holds still.
                    CompactContent(activities: compact, notch: notch, slotWidth: slotWidth)
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
            .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
            .clipShape(shape)
            .environment(\.islandIsVisible, model.isVisible)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .contentShape(shape)
        .onHover { model.pointer(.island, isInside: $0) }
        .onTapGesture { model.clicked() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
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
