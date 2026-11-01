import Testing
@testable import Jambul

@MainActor
struct ActivityCenterTests {
    @Test func theHighestPriorityLiveActivityWins() {
        let center = ActivityCenter()
        center.register(TestActivity(id: "low", isLive: true, priority: .low))
        center.register(TestActivity(id: "high", isLive: true, priority: .high))
        center.register(TestActivity(id: "asleep", isLive: false, priority: .high))
        #expect(center.liveActivity?.id == "high")
    }

    @Test func tiesGoToTheFirstRegistered() {
        let center = ActivityCenter()
        center.register(TestActivity(id: "first", isLive: true))
        center.register(TestActivity(id: "second", isLive: true))
        #expect(center.liveActivity?.id == "first")
    }

    @Test func everyLiveActivityComesMostImportantFirst() {
        let center = ActivityCenter()
        center.register(TestActivity(id: "first", isLive: true))
        center.register(TestActivity(id: "asleep", isLive: false, priority: .high))
        center.register(TestActivity(id: "high", isLive: true, priority: .high))
        center.register(TestActivity(id: "second", isLive: true))
        #expect(center.liveActivities.map(\.id) == ["high", "first", "second"])
    }

    @Test func nothingIsLiveByDefault() {
        let center = ActivityCenter()
        center.register(TestActivity())
        #expect(center.liveActivity == nil)
    }
}
