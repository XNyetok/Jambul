import SwiftUI

struct IslandView: View {
    let model: IslandModel

    var body: some View {
        let presentation = model.presentation
        let notch = model.notch
        let layout = model.layout
        let shape = IslandShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius)

        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .shadow(color: .black.opacity(presentation == .expanded ? 0.45 : 0), radius: 16, y: 6)

            // Clipped separately from the shadow, so content never draws outside the island while it morphs.
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
                    ExpandedContent(model: model)
                        .frame(width: IslandLayout.expandedSize.width, height: IslandLayout.expandedSize.height)
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

/// A center with the timer and Keep Awake, either of them on. Neither holds the Mac awake or the screen on, which they
/// would for as long as the preview lives, and Keep Awake remembers nothing.
@MainActor
private func previewActivities(timer running: Bool = false, keepAwake on: Bool = false) -> ActivityCenter {
    let activities = ActivityCenter()
    let timer = TimerActivity(activities: activities, keepsMacAwake: false)
    let keepAwake = KeepAwakeActivity(activities: activities, defaults: UserDefaults(suiteName: "preview") ?? .standard,
                                      bootSession: nil, holdsScreen: false)
    activities.register(timer)
    activities.register(keepAwake)
    if running { timer.start(.seconds(25 * 60)) }
    if on { keepAwake.start(since: .now.addingTimeInterval(-65 * 60)) } else { keepAwake.stop() }
    return activities
}

#Preview("Timer Tab") {
    IslandPreview(model: IslandModel(notch: previewNotch, activities: previewActivities(), presentation: .expanded))
}

#Preview("Timer") {
    IslandPreview(model: IslandModel(notch: previewNotch, activities: previewActivities(timer: true)))
}

#Preview("Timer Expanded") {
    IslandPreview(model: IslandModel(notch: previewNotch, activities: previewActivities(timer: true),
                                     presentation: .expanded))
}

#Preview("Keep Awake") {
    IslandPreview(model: IslandModel(notch: previewNotch, activities: previewActivities(keepAwake: true)))
}

#Preview("Keep Awake Expanded") {
    IslandPreview(model: IslandModel(notch: previewNotch, activities: previewActivities(keepAwake: true),
                                     presentation: .expanded))
}

#Preview("Timer and Keep Awake") {
    IslandPreview(model: IslandModel(notch: previewNotch, activities: previewActivities(timer: true, keepAwake: true)))
}
#endif
