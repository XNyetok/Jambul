import SwiftUI
import Testing
@testable import Jambul

/// With more than two activities live, those past the first take turns left of the notch.
@MainActor
final class CompactTurnsTests {
    private let notch = NotchMetrics(size: CGSize(width: 180, height: 32), compactHeight: 33)
    private let activities = ActivityCenter()
    private let first = TestActivity(id: "first", isLive: true, priority: .high, compactSlotWidth: 42)
    private let second = TestActivity(id: "second", isLive: true, compactSlotWidth: 16)
    private let third = TestActivity(id: "third", isLive: true, priority: .low, compactSlotWidth: 22)
    private let fourth = TestActivity(id: "fourth", isLive: false, priority: .low, compactSlotWidth: 16)

    /// Three live activities, the first the most important, and a fourth that can start. Turns come by themselves
    /// only once a test shortens them; until then a test takes them by hand.
    private func threeLive() -> IslandModel {
        for activity in [first, second, third, fourth] { activities.register(activity) }
        return IslandModel(notch: notch, activities: activities)
    }

    private func shown(_ model: IslandModel) -> [String] { model.compactActivities.map(\.id) }

    @Test func theOthersTakeTurnsLeftOfTheNotchAndTheFirstKeepsTheRight() {
        let model = threeLive()
        #expect(shown(model) == ["first", "second"])
        model.takeNextCompactTurn()
        #expect(shown(model) == ["first", "third"])
        model.takeNextCompactTurn()
        #expect(shown(model) == ["first", "second"])
    }

    @Test func theIslandKeepsItsSizeAsTheyTakeTurns() {
        let model = threeLive()
        // Room for the widest of those taking turns, whoever shows.
        #expect(model.compactLeadingWidth == 22)
        let size = model.layout.size
        model.takeNextCompactTurn()
        #expect(shown(model) == ["first", "third"])
        #expect(model.layout.size == size)
        #expect(model.compactSlotWidth == 42)
    }

    /// Whoever has the turn keeps it as another activity starts or ends: an index into the list sent the glyph
    /// jumping to an activity that hadn't changed.
    @Test func whoeverHasTheTurnKeepsItAsOthersStartAndEnd() async throws {
        let model = threeLive()
        model.takeNextCompactTurn()
        #expect(shown(model) == ["first", "third"])
        fourth.isLive = true
        try await waitUntil { model.liveActivities.count == 4 }
        #expect(shown(model) == ["first", "third"])
        second.isLive = false
        try await waitUntil { model.liveActivities.count == 3 }
        #expect(shown(model) == ["first", "third"])
        // And the next turn goes to the one after it.
        model.takeNextCompactTurn()
        #expect(shown(model) == ["first", "fourth"])
    }

    @Test func whenTheOneWithTheTurnEndsTheSecondShows() async throws {
        let model = threeLive()
        fourth.isLive = true
        try await waitUntil { model.liveActivities.count == 4 }
        model.takeNextCompactTurn()
        #expect(shown(model) == ["first", "third"])
        third.isLive = false
        try await waitUntil { model.liveActivities.count == 3 }
        #expect(shown(model) == ["first", "second"])
    }

    @Test func turnsComeByThemselvesWhileTheIslandRestsBesideTheNotch() async throws {
        let model = threeLive()
        model.compactTurnLength = .milliseconds(30)
        try await waitUntil(timeout: .seconds(5)) { model.compactTurn >= 2 }
    }

    @Test func twoLiveActivitiesTakeNoTurns() async throws {
        third.isLive = false
        let model = threeLive()
        model.compactTurnLength = .milliseconds(20)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.compactTurn == 0)
    }

    /// Under the pointer the island is lifted, and whoever shows there stays: nothing changes under a resting pointer.
    /// Once the pointer has gone, turns go on.
    @Test func nobodyTakesATurnWhileThePointerRestsOnTheIsland() async throws {
        let model = threeLive()
        model.pointer(.island, isInside: true)
        model.clicked()
        model.clicked()
        #expect(model.presentation == .lifted)
        model.compactTurnLength = .milliseconds(20)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.compactTurn == 0)
        model.pointer(.island, isInside: false)
        try await waitUntil(timeout: .seconds(5)) { model.compactTurn >= 1 }
    }

    /// Nothing wakes Jambul while nobody can see the island; turns go on once someone can.
    @Test func nobodyTakesATurnWhileTheIslandIsOutOfSight() async throws {
        let model = threeLive()
        model.islandWentOutOfSight()
        #expect(!model.isVisible)
        model.compactTurnLength = .milliseconds(20)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.compactTurn == 0)
        model.visibilityMayHaveChanged()
        try await waitUntil(timeout: .seconds(5)) { model.compactTurn >= 1 }
    }

    @Test func nobodyTakesATurnWhileTheIslandIsHiddenForAFullScreenApp() async throws {
        let model = threeLive()
        model.isHidden = true
        model.compactTurnLength = .milliseconds(20)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.compactTurn == 0)
    }

    @Test func turnsStopOnceOnlyTwoAreLive() async throws {
        let model = threeLive()
        model.compactTurnLength = .milliseconds(20)
        try await waitUntil(timeout: .seconds(5)) { model.compactTurn >= 1 }
        third.isLive = false
        try await waitUntil { model.liveActivities.count == 2 }
        let turns = model.compactTurn
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.compactTurn == turns)
    }
}
