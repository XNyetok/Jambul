import SwiftUI
@testable import Jambul

@MainActor
@Observable
final class TestActivity: IslandActivity {
    let id: String
    var isLive: Bool
    var priority: ActivityPriority
    let compactSlotWidth: CGFloat

    init(id: String = "test", isLive: Bool = false, priority: ActivityPriority = .normal, compactSlotWidth: CGFloat = 36) {
        self.id = id
        self.isLive = isLive
        self.priority = priority
        self.compactSlotWidth = compactSlotWidth
    }

    var compactLeading: some View { EmptyView() }
    var compactTrailing: some View { EmptyView() }
}

/// A test activity with a tab in the open island, like the timer and Keep Awake.
@MainActor
@Observable
final class TabbedTestActivity: IslandActivity {
    let id: String
    var isLive: Bool
    var priority: ActivityPriority

    init(id: String, isLive: Bool = false, priority: ActivityPriority = .normal) {
        self.id = id
        self.isLive = isLive
        self.priority = priority
    }

    var compactLeading: some View { EmptyView() }
    var compactTrailing: some View { EmptyView() }
    var tab: some View { Text(id) }
}
