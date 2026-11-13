import CoreGraphics
import Foundation
import Testing
@testable import Jambul

/// These run against real time: hover intent is 60 ms by default and the exit grace 120 ms. A CI machine can stall long
/// enough for timers due close together to run in either order, so wait for what should have happened (`waitUntil`)
/// rather than sleep past it, and keep a check that something hasn't happened yet far from when it's due.
@MainActor
struct IslandModelTests {
    private let activities = ActivityCenter()

    private func makeModel(on center: ActivityCenter? = nil) -> IslandModel {
        IslandModel(notch: NotchMetrics(size: CGSize(width: 180, height: 32), compactHeight: 33),
                    activities: center ?? activities)
    }

    @Test func hoveringTheNotchLiftsThenExpands() async throws {
        let model = makeModel()
        model.pointer(.notch, isInside: true)
        #expect(model.presentation == .lifted)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .expanded)
    }

    /// The island's panel makes room for a change as it hears of it. Resized while the change was being stored, it made
    /// SwiftUI draw the island as it was and miss the change.
    @Test func theWindowsHearOfAChangeBeforeAnyOfItIsStored() {
        let model = makeModel()
        var heard: [String] = []
        model.onWillChange = { [unowned model] next in heard.append("\(model.presentation) → \(next)") }
        model.pointer(.notch, isInside: true)
        #expect(heard == ["idle → lifted"])
        #expect(model.presentation == .lifted)
    }

    /// A timer never fires early, so however slow the machine, the island can't open before the slow intent is over.
    @Test func aSlowerHoverSpeedWaitsLonger() async throws {
        let model = makeModel()
        model.hoverIntent = HoverSpeed.slow.intent
        let hovered = ContinuousClock.now
        model.pointer(.notch, isInside: true)
        #expect(model.presentation == .lifted)
        try await waitUntil { model.presentation == .expanded }
        #expect(hovered.duration(to: .now) >= HoverSpeed.slow.intent)
    }

    /// A stall can only make one try slower, so the quickest of a few has to beat half the default intent.
    @Test func theFastHoverSpeedOpensAtOnce() async throws {
        var quickest = Duration.seconds(1)
        for _ in 0..<5 {
            let model = makeModel()
            model.hoverIntent = HoverSpeed.fast.intent
            let hovered = ContinuousClock.now
            model.pointer(.notch, isInside: true)
            try await waitUntil { model.presentation == .expanded }
            quickest = min(quickest, hovered.duration(to: .now))
        }
        #expect(quickest < HoverSpeed.normal.intent / 2)
    }

    @Test func resettingForgetsThePointer() async throws {
        let model = makeModel()
        model.pointer(.notch, isInside: true)
        model.clicked()
        model.reset()
        #expect(model.presentation == .idle)

        // The next arrival hovers it open like any other.
        model.pointer(.notch, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .expanded)
    }

    @Test func leavingBeforeTheHoverIntentCancelsOpening() async throws {
        let model = makeModel()
        model.pointer(.notch, isInside: true)
        model.pointer(.notch, isInside: false)
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.presentation == .idle)
    }

    @Test func movingFromTheNotchOntoTheIslandKeepsItOpen() async throws {
        let model = makeModel()
        model.pointer(.notch, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        model.pointer(.island, isInside: true)
        model.pointer(.notch, isInside: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .expanded)
    }

    @Test func clickingOpensWithoutWaitingForTheHoverIntent() {
        let model = makeModel()
        model.pointer(.notch, isInside: true)
        #expect(model.presentation == .lifted)
        model.clicked()
        #expect(model.presentation == .expanded)
    }

    @Test func clickingAnOpenIslandFoldsItBackUnderThePointer() {
        let model = makeModel()
        model.pointer(.notch, isInside: true)
        model.clicked()
        #expect(model.presentation == .expanded)
        model.clicked()
        #expect(model.presentation == .lifted)
        model.clicked()
        #expect(model.presentation == .expanded)
    }

    @Test func aClickClosedIslandStaysClosedUntilThePointerLeaves() async throws {
        let model = makeModel()
        model.pointer(.notch, isInside: true)
        model.clicked()
        model.clicked()
        // Moving around on the island doesn't reopen it.
        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .lifted)

        model.pointer(.island, isInside: false)
        model.pointer(.notch, isInside: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .idle)

        // Coming back hovers it open as usual.
        model.pointer(.notch, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .expanded)
    }

    @Test func clickingAnOpenIslandWithThePointerElsewhereClosesIt() {
        let model = makeModel()
        model.clicked()
        model.clicked()
        #expect(model.presentation == .idle)
    }

    @Test func aLiveActivityRestsInCompact() async throws {
        let activity = TestActivity()
        activities.register(activity)
        let model = makeModel()

        activity.isLive = true
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.presentation == .compact)
        #expect(model.activity?.id == activity.id)

        activity.isLive = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.presentation == .idle)
        #expect(model.activity == nil)
    }

    // MARK: Several activities at once

    @Test func twoLiveActivitiesShareTheCompactIsland() async throws {
        let timer = TestActivity(id: "timer", priority: .high, compactSlotWidth: 42)
        let other = TestActivity(id: "other", compactSlotWidth: 36)
        activities.register(other)
        activities.register(timer)
        let model = makeModel()
        other.isLive = true
        timer.isLive = true
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.presentation == .compact)
        #expect(model.compactActivities.map(\.id) == ["timer", "other"])
        // Both sides as wide as the wider one needs, so the island stays centered on the notch.
        #expect(model.compactSlotWidth == 42)
    }

    @Test func onlyTheTwoMostImportantRestBesideTheNotch() {
        activities.register(TestActivity(id: "a", isLive: true))
        activities.register(TestActivity(id: "b", isLive: true, priority: .high))
        activities.register(TestActivity(id: "c", isLive: true, compactSlotWidth: 80))
        let model = makeModel()
        #expect(model.liveActivities.map(\.id) == ["b", "a", "c"])
        #expect(model.compactActivities.map(\.id) == ["b", "a"])
        #expect(model.compactSlotWidth == 36)
    }

    @Test func theOpenIslandIsOneSizeWhateverIsLive() {
        let quiet = makeModel()
        quiet.clicked()
        for id in ["a", "b", "c"] { activities.register(TestActivity(id: id, isLive: true)) }
        let busy = makeModel()
        busy.clicked()
        // One size on every tab and with any number live, so the island never grows or shrinks under the pointer.
        #expect(quiet.layout.size == IslandLayout.expandedSize)
        #expect(busy.layout.size == IslandLayout.expandedSize)
        #expect(IslandLayout.expandedSize.height + IslandLayout.canvasMargin <= IslandLayout.canvasSize(busy.notch).height)
    }

    @Test func anotherActivityGoingLiveWhileOpenKeepsTheIslandOpenAndGuardsTheDoubleClick() async throws {
        let first = TestActivity(id: "first", isLive: true)
        let second = TestActivity(id: "second")
        activities.register(first)
        activities.register(second)
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        #expect(model.acceptsPress(clickCount: 1))
        second.isLive = true
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.presentation == .expanded)
        #expect(model.liveActivities.map(\.id) == ["first", "second"])
        // The open island's content changed under the pointer, so the rest of a double click begun before is aimed
        // elsewhere.
        #expect(!model.acceptsPress(clickCount: 2))
    }

    @Test func oneActivityEndingLeavesTheOtherBesideTheNotch() async throws {
        let first = TestActivity(id: "first", isLive: true)
        let second = TestActivity(id: "second", isLive: true)
        activities.register(first)
        activities.register(second)
        let model = makeModel()
        first.isLive = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.presentation == .compact)
        #expect(model.compactActivities.map(\.id) == ["second"])
    }

    @Test func newsAboutTheTabTheOwnerChoseKeepsOnlyForItsTime() async throws {
        let first = TabbedTestActivity(id: "first", isLive: true, priority: .high)
        let second = TabbedTestActivity(id: "second", isLive: true)
        activities.register(first)
        activities.register(second)
        let model = makeModel()
        let transitions = TransitionLog(model)
        model.pointer(.island, isInside: true)
        model.clicked()
        model.selectTab(second.id)
        // The second activity's tab was right there on the open island.
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Done", duration: .milliseconds(100),
                             mustBeSeen: true, source: second.id))
        try await Task.sleep(for: .milliseconds(300))
        model.pointer(.island, isInside: false)
        try await waitUntil { model.presentation == .compact }
        // Nothing follows: a stall can only hold back a peek that shouldn't come, never make one come.
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.presentation == .compact)
        #expect(!transitions.steps.contains { $0.hasSuffix("peek") })
    }

    @Test func newsAboutALiveActivityOnAnotherTabWaitsOutTheOpenIsland() async throws {
        let first = TabbedTestActivity(id: "first", isLive: true, priority: .high)
        let second = TabbedTestActivity(id: "second", isLive: true)
        activities.register(first)
        activities.register(second)
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        #expect(model.selectedTab == first.id)
        // Like the timer ending while Keep Awake's tab shows: the owner hasn't seen it.
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Done", duration: .milliseconds(500),
                             mustBeSeen: true, source: second.id))
        // Open well past the news's own time.
        try await Task.sleep(for: .milliseconds(700))
        model.pointer(.island, isInside: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.presentation == .peek)
        #expect(model.peek?.title == "Done")
    }

    @Test func leavingAnOpenIslandReturnsToCompact() async throws {
        activities.register(TestActivity(isLive: true))
        let model = makeModel()
        model.clicked()
        #expect(model.presentation == .expanded)
        model.pointer(.island, isInside: true)
        model.pointer(.island, isInside: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .compact)
    }

    @Test func aPeekDismissesItself() async throws {
        let model = makeModel()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Hi", duration: .milliseconds(100)))
        #expect(model.presentation == .peek)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.presentation == .idle)
    }

    @Test func hoveringAPeekOpensTheIsland() async throws {
        let model = makeModel()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Hi", duration: .milliseconds(100)))
        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .expanded)
    }

    @Test func peeksDontInterruptAnOpenIsland() {
        let model = makeModel()
        model.clicked()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Hi"))
        #expect(model.presentation == .expanded)
    }

    @Test func aPeekThatArrivedWhileOpenShowsAsTheIslandCloses() async throws {
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .seconds(1)))
        #expect(model.presentation == .expanded)

        model.pointer(.island, isInside: false)
        try await waitUntil { model.presentation == .peek }
        #expect(model.peek?.title == "Timer done")
        // It stays for its time once it shows.
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.presentation == .peek)
        try await waitUntil { model.presentation == .idle }
    }

    @Test func aPeekHeldPastItsDurationIsDropped() async throws {
        let model = makeModel()
        let transitions = TransitionLog(model)
        model.pointer(.island, isInside: true)
        model.clicked()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Hi", duration: .milliseconds(100)))
        try await Task.sleep(for: .milliseconds(200))

        model.pointer(.island, isInside: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .idle)
        #expect(!transitions.steps.contains { $0.hasSuffix("peek") })
    }

    @Test func newsTheOwnerMustSeeWaitsOutAnOpenIsland() async throws {
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        activities.peek(Peek(symbol: "battery.25", tint: .red, title: "Low battery", duration: .milliseconds(500),
                             mustBeSeen: true, source: "battery"))
        // Open well past the warning's own time.
        try await Task.sleep(for: .milliseconds(700))

        model.pointer(.island, isInside: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.presentation == .peek)
        #expect(model.peek?.title == "Low battery")
    }

    @Test func newsDuringTheHoverIntentAboutAnotherTabWaitsOutTheOpenIsland() async throws {
        let first = TabbedTestActivity(id: "first", isLive: true, priority: .high)
        let second = TabbedTestActivity(id: "second", isLive: true)
        activities.register(first)
        activities.register(second)
        let model = makeModel()
        let transitions = TransitionLog(model)
        model.pointer(.notch, isInside: true)
        #expect(model.presentation == .lifted)
        // While the hover is about to open the island, news the owner must see about the second activity.
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Done", duration: .milliseconds(300),
                             mustBeSeen: true, source: second.id))
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.presentation == .expanded)
        #expect(model.selectedTab == first.id)
        // Open on the first activity's tab well past the news's own time.
        try await Task.sleep(for: .milliseconds(500))
        model.pointer(.notch, isInside: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(transitions.steps.contains { $0.hasSuffix("peek") }, "\(transitions.steps)")
    }

    @Test func newsSeenOnItsTabStaysSeenWhenTheIslandReopensOnAnother() async throws {
        let first = TabbedTestActivity(id: "first", isLive: true, priority: .high)
        let second = TabbedTestActivity(id: "second", isLive: true)
        activities.register(first)
        activities.register(second)
        let model = makeModel()
        let transitions = TransitionLog(model)
        model.pointer(.island, isInside: true)
        model.clicked()
        #expect(model.selectedTab == first.id)
        // Like the timer ending on its own tab: the owner saw it there, then looked at the other tab.
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Done", duration: .milliseconds(300),
                             mustBeSeen: true, source: first.id))
        first.isLive = false
        try await Task.sleep(for: .milliseconds(50))
        model.selectTab(second.id)

        // Clicked closed and open again within the news's own time, now on the other tab.
        model.clicked()
        #expect(model.presentation == .lifted)
        model.clicked()
        #expect(model.selectedTab == second.id)
        // Open well past the news's own time: it has gone stale.
        try await Task.sleep(for: .milliseconds(700))
        model.pointer(.island, isInside: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!transitions.steps.contains { $0.hasSuffix("peek") }, "\(transitions.steps)")
    }

    @Test func newsAboutWhatTheOpenIslandShowsKeepsOnlyForItsTime() async throws {
        let activity = TabbedTestActivity(id: "timer", isLive: true)
        activities.register(activity)
        let model = makeModel()
        let transitions = TransitionLog(model)
        model.pointer(.island, isInside: true)
        model.clicked()
        // Like the timer ending on its tab, which the island opened on: the owner saw it there.
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .milliseconds(100),
                             mustBeSeen: true, source: activity.id))
        try await Task.sleep(for: .milliseconds(300))

        model.pointer(.island, isInside: false)
        try await waitUntil { model.presentation == .compact }
        // Nothing follows: a stall can only hold back a peek that shouldn't come, never make one come.
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.presentation == .compact)
        #expect(!transitions.steps.contains { $0.hasSuffix("peek") })
    }

    @Test func aPeekDuringTheHoverIntentWaitsForTheIslandToClose() async throws {
        let model = makeModel()
        model.pointer(.notch, isInside: true)
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Hi", duration: .seconds(2)))
        try await waitUntil { model.presentation == .expanded }

        model.pointer(.notch, isInside: false)
        try await waitUntil { model.presentation == .peek }
    }

    @Test func aNewPeekDoesntCancelAHoverInProgress() async throws {
        let model = makeModel()
        let transitions = TransitionLog(model)
        model.hoverIntent = HoverSpeed.slow.intent
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging", duration: .seconds(1)))
        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(50))
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .milliseconds(400)))
        // It waits rather than flash under the pointer for what is left of the hover intent.
        #expect(model.peek?.title == "Charging")
        // Past the new peek's duration too: running out mustn't fold the island that has opened since.
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.presentation == .expanded)
        #expect(transitions.steps == ["idle → peek", "peek → expanded"])
    }

    @Test func aPeekThatArrivedAsAHoverOpenedAPeekShowsAsTheIslandCloses() async throws {
        let model = makeModel()
        // An intent far longer than any setting, so the second peek arrives well before the hover opens the island.
        model.hoverIntent = .milliseconds(600)
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging", duration: .seconds(2)))
        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(50))
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .seconds(2)))
        try await waitUntil { model.presentation == .expanded }

        model.pointer(.island, isInside: false)
        try await waitUntil { model.presentation == .peek }
        #expect(model.peek?.title == "Timer done")
    }

    @Test func aPeekStaysWhileThePointerRestsOnIt() async throws {
        let model = makeModel()
        // An intent far longer than any setting, so the check below stays well clear of it on a machine that stalls.
        model.hoverIntent = .milliseconds(600)
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Hi", duration: .milliseconds(50)))
        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(150))
        // Past the peek's own duration, but the pointer is on it.
        #expect(model.presentation == .peek)
        try await waitUntil { model.presentation == .expanded }
    }

    @Test func aPeekNeverClosesUnderARestingPointer() async throws {
        let model = makeModel()
        let transitions = TransitionLog(model)
        model.hoverIntent = HoverSpeed.slow.intent
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging", duration: .seconds(1)))
        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(20))
        // A second, shorter peek arrives, and would run out, while the hover intent is still running.
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .milliseconds(50)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.presentation == .expanded)
        #expect(transitions.steps == ["idle → peek", "peek → expanded"])
    }

    // MARK: Tabs

    /// Two activities with a tab, the first the more important, and one without.
    private func registerTabbedActivities() -> (first: TabbedTestActivity, second: TabbedTestActivity, other: TestActivity) {
        let first = TabbedTestActivity(id: "first", priority: .high)
        let other = TestActivity(id: "other")
        let second = TabbedTestActivity(id: "second")
        activities.register(first)
        activities.register(other)
        activities.register(second)
        return (first, second, other)
    }

    @Test func onlyActivitiesWithATabGetOneInTheirOrder() {
        let (first, second, _) = registerTabbedActivities()
        #expect(makeModel().tabs.map(\.id) == [first.id, second.id])
    }

    @Test func theIslandFirstOpensOnTheFirstTabEvenWithSomethingLive() {
        let (first, second, _) = registerTabbedActivities()
        // Like Keep Awake coming back on as Jambul relaunches: the island still opens on Home, the first tab.
        second.isLive = true
        let model = makeModel()
        model.clicked()
        #expect(model.selectedTab == first.id)
    }

    @Test func theIslandHoversOpenAgainOnTheTabItShowedLast() async throws {
        let (_, second, _) = registerTabbedActivities()
        let model = makeModel()
        model.pointer(.notch, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .expanded)
        model.selectTab(second.id)

        // Closed by the pointer leaving, then hovered open again.
        model.pointer(.notch, isInside: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.presentation == .idle)
        model.pointer(.notch, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .expanded)
        #expect(model.selectedTab == second.id)
    }

    @Test func aTabTheOwnerOnlyLookedAtIsWhereTheIslandOpensNext() {
        let (_, second, _) = registerTabbedActivities()
        let model = makeModel()
        // A look at the usage limits, starting nothing there, then a click to close and one to open again.
        model.clicked()
        model.selectTab(second.id)
        model.clicked()
        #expect(model.presentation == .idle)
        model.clicked()
        #expect(model.selectedTab == second.id)
    }

    @Test func activitiesStartingAndEndingDontMoveTheTab() async throws {
        let (first, second, other) = registerTabbedActivities()
        let model = makeModel()
        model.clicked()
        model.selectTab(second.id)
        model.clicked()
        // With the island shut: the more important one starting, as the timer can from the menu bar, and one without a
        // tab, like the debug menu's demo.
        first.isLive = true
        other.isLive = true
        try await Task.sleep(for: .milliseconds(50))
        model.clicked()
        #expect(model.selectedTab == second.id)

        model.clicked()
        first.isLive = false
        try await Task.sleep(for: .milliseconds(50))
        model.clicked()
        #expect(model.selectedTab == second.id)
    }

    @Test func aNewIslandStartsOnTheFirstTabAgain() {
        let (_, second, _) = registerTabbedActivities()
        let before = makeModel()
        before.clicked()
        before.selectTab(second.id)
        #expect(before.selectedTab == second.id)

        // Jambul launched again: its activities registered anew, and a new island, which opens on Home again.
        let relaunched = ActivityCenter()
        relaunched.register(TabbedTestActivity(id: "first", priority: .high))
        relaunched.register(TabbedTestActivity(id: "second"))
        let model = makeModel(on: relaunched)
        model.clicked()
        #expect(model.selectedTab == "first")
    }

    @Test func theTabStaysPutWhileActivitiesStartAndEnd() async throws {
        let (first, second, _) = registerTabbedActivities()
        let model = makeModel()
        model.clicked()
        model.selectTab(second.id)
        first.isLive = true
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.presentation == .expanded)
        #expect(model.selectedTab == second.id)

        first.isLive = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.selectedTab == second.id)
    }

    @Test func choosingATabLeavesTheIslandOpenUnderThePointer() {
        let (_, second, _) = registerTabbedActivities()
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        model.selectTab(second.id)
        #expect(model.presentation == .expanded)
        #expect(model.selectedTab == second.id)
    }

    @Test func aTabsContentComesInFromTheSideItsTabLiesOn() {
        let (first, second, _) = registerTabbedActivities()
        let model = makeModel()
        model.clicked()
        model.selectTab(second.id)
        #expect(model.tabArrivesFrom == .trailing)
        model.selectTab(first.id)
        #expect(model.tabArrivesFrom == .leading)
    }

    // MARK: Clicks on content that has changed

    @Test func theRestOfADoubleClickOnContentThatChangedIsIgnored() async throws {
        let activity = TestActivity()
        activities.register(activity)
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        // The first click of a double click on "25 min" starts the timer, whose countdown takes the quick starts' place.
        #expect(model.acceptsPress(clickCount: 1))
        activity.isLive = true
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.activity?.id == activity.id)

        // The rest of it was aimed at the quick starts, not at the countdown.
        #expect(!model.acceptsPress(clickCount: 2))
        #expect(!model.acceptsPress(clickCount: 3))
        #expect(model.presentation == .expanded)
    }

    @Test func aFreshClickRightAfterTheContentChangesCounts() async throws {
        // Stop, then "25 min" straight away: two clicks of their own, and the second must land.
        let activity = TestActivity(isLive: true)
        activities.register(activity)
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        activity.isLive = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.activity == nil)

        #expect(model.acceptsPress(clickCount: 1))
        model.clicked()
        #expect(model.presentation == .lifted)
    }

    @Test func aDoubleClickBegunOnTheNewContentCountsInFull() async throws {
        let activity = TestActivity()
        activities.register(activity)
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        activity.isLive = true
        try await Task.sleep(for: .milliseconds(50))

        // Like two quick clicks on "+1 min".
        #expect(model.acceptsPress(clickCount: 1))
        #expect(model.acceptsPress(clickCount: 2))
    }

    @Test func theGuardOnChangedContentEndsWithTheOpenIsland() async throws {
        let activity = TestActivity()
        activities.register(activity)
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        activity.isLive = true
        try await Task.sleep(for: .milliseconds(50))

        // Leaving right away closes the island, and nothing on it is left to guard.
        model.pointer(.island, isInside: false)
        try await waitUntil { model.presentation == .compact }
        #expect(model.acceptsPress(clickCount: 2))
    }

    // MARK: Never narrowing from under the pointer

    @Test func anActivityEndingUnderTheLiftedIslandKeepsItsRoom() async throws {
        let activity = TestActivity(isLive: true)
        activities.register(activity)
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        model.clicked()
        #expect(model.presentation == .lifted)
        #expect(model.compactSlotWidth == activity.compactSlotWidth)

        // Like a timer ending while the pointer rests on its digits.
        activity.isLive = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.activity == nil)
        #expect(model.presentation == .lifted)
        #expect(model.compactSlotWidth == activity.compactSlotWidth)

        // Once the pointer goes, the island settles to its own size.
        model.pointer(.island, isInside: false)
        try await waitUntil { model.presentation == .idle }
        #expect(model.compactSlotWidth == nil)
    }

    @Test func aPeekArrivingAtAClickClosedIslandShowsAtOnce() {
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        model.clicked()
        #expect(model.presentation == .lifted)

        // Nothing is about to open the island, and the peek only grows from the lifted pill.
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done"))
        #expect(model.presentation == .peek)
    }

    @Test func aNewPeekWaitsBehindOnesAlreadyWaitingAtAClickClosedIsland() async throws {
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        activities.peek(Peek(symbol: "battery.25", tint: .red, title: "Low battery", duration: .seconds(2),
                             mustBeSeen: true, source: "battery"))
        model.clicked()
        #expect(model.presentation == .lifted)

        activities.peek(Peek(symbol: "bird.fill", tint: .orange, title: "Hello", duration: .seconds(2), source: "demo"))
        #expect(model.presentation == .lifted)
        // Once the pointer goes they show in turn, the one the owner must see first.
        model.pointer(.island, isInside: false)
        try await waitUntil { model.presentation == .peek }
        #expect(model.peek?.title == "Low battery")
    }

    @Test func aTimerEndingUnderAClickClosedIslandPeeksUntilThePointerGoes() async throws {
        let timer = TestActivity(id: "timer", isLive: true)
        activities.register(timer)
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        model.clicked()
        let transitions = TransitionLog(model)

        // As the real timer ends: the peek in the same turn as the end, the end reaching the island a turn later.
        timer.isLive = false
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .milliseconds(300),
                             mustBeSeen: true, source: timer.id))
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.presentation == .peek)
        #expect(model.activity == nil)
        // Past its time, with the pointer still resting on it.
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.presentation == .peek)

        model.pointer(.island, isInside: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .idle)
        #expect(model.compactSlotWidth == nil)
        #expect(transitions.steps == ["lifted → peek", "peek → idle"])
    }

    // MARK: Peeks that appear under the pointer

    @Test func aPeekThatAppearsUnderTheMovingPointerDoesntOpenTheIsland() async throws {
        let model = makeModel()
        model.isPointerOnIsland = { true }
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .milliseconds(600)))
        // The pointer only reports arriving as it moves on.
        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .peek)
    }

    @Test func aPeekThatAppearedUnderThePointerKeepsItsTimeWhenThePointerLeaves() async throws {
        let model = makeModel()
        model.isPointerOnIsland = { true }
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .milliseconds(600)))
        model.pointer(.island, isInside: true)
        model.pointer(.island, isInside: false)
        // Well past the exit grace, which closes a peek the pointer came to.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.presentation == .peek)
        try await Task.sleep(for: .milliseconds(450))
        #expect(model.presentation == .idle)
    }

    @Test func hoverCountsOnceThePointerHasLeftAPeekThatAppearedUnderIt() async throws {
        let model = makeModel()
        let watch = WatchLog()
        model.watchesPointer = { watch.calls.append($0) }
        model.isPointerOnIsland = { true }
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .seconds(2)))
        model.pointer(.island, isInside: true)
        model.pointer(.island, isInside: false)
        // The pointer watch ends with the exit grace, once hover no longer waits for the pointer to leave.
        try await waitUntil { watch.calls == [true, false] }

        // Coming back is coming for the peek.
        model.pointer(.island, isInside: true)
        try await waitUntil { model.presentation == .expanded }
    }

    @Test func aPeekWhoseTimeRunsOutUnderThePointerStaysUntilThePointerGoes() async throws {
        let model = makeModel()
        model.isPointerOnIsland = { true }
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .milliseconds(100)))
        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.presentation == .peek)

        model.pointer(.island, isInside: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .idle)
    }

    @Test func aClickStillOpensAPeekThatAppearedUnderThePointer() {
        let model = makeModel()
        model.isPointerOnIsland = { true }
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done"))
        model.pointer(.island, isInside: true)
        model.clicked()
        #expect(model.presentation == .expanded)
    }

    @Test func aPointerThatSlipsOffAPeekUnreportedHasLeftIt() async throws {
        let model = makeModel()
        model.isPointerOnIsland = { true }
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .seconds(2)))
        // Its first move lands off the peek, so the island never hears of it; the pointer watch does.
        model.pointerIsOffIsland()
        try await Task.sleep(for: .milliseconds(100))

        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .expanded)
    }

    @Test func thePointerIsWatchedOnlyWhileHoverWaitsForItToLeaveAPeek() {
        let model = makeModel()
        let watch = WatchLog()
        model.watchesPointer = { watch.calls.append($0) }
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging", source: "battery"))
        #expect(watch.calls.isEmpty)

        model.isPointerOnIsland = { true }
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", source: "timer"))
        #expect(watch.calls == [true])
        model.pointerIsOffIsland()
        #expect(watch.calls == [true, false])
    }

    @Test func thePointerWatchEndsWithThePeek() async throws {
        let model = makeModel()
        let watch = WatchLog()
        model.watchesPointer = { watch.calls.append($0) }
        model.isPointerOnIsland = { true }
        // A pointer resting where the peek appears never reports arriving, so the peek goes in its own time.
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .milliseconds(100)))
        #expect(watch.calls == [true])
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.presentation == .idle)
        #expect(watch.calls == [true, false])
    }

    @Test func aPeekArrivingJustAsThePointerLeftAClickClosedIslandOpensOnHover() async throws {
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        model.clicked()
        // Within the exit grace, the peek appears away from the pointer that just left.
        model.pointer(.island, isInside: false)
        try await Task.sleep(for: .milliseconds(30))
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging", duration: .seconds(2)))
        #expect(model.presentation == .peek)
        try await Task.sleep(for: .milliseconds(300))

        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .expanded)
    }

    @Test func aPeekReplacingOneThePointerJustLeftOpensOnHover() async throws {
        let model = makeModel()
        let pointer = PointerSpot(isOnIsland: true)
        model.isPointerOnIsland = { pointer.isOnIsland }
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "First", duration: .seconds(2), source: "a"))
        model.pointer(.island, isInside: true)
        pointer.isOnIsland = false
        model.pointer(.island, isInside: false)
        // Within the exit grace, a newer peek takes its place.
        try await Task.sleep(for: .milliseconds(30))
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Second", duration: .seconds(2), source: "b"))
        #expect(model.peek?.title == "Second")
        try await Task.sleep(for: .milliseconds(300))

        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .expanded)
    }

    @Test func aPeekHeldThroughAClickCloseOpensOnHover() async throws {
        let model = makeModel()
        model.pointer(.notch, isInside: true)
        model.clicked()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .seconds(2)))
        model.clicked()
        #expect(model.presentation == .lifted)

        // Leaving shows the held peek, and coming back onto it hovers it open like any other.
        model.pointer(.notch, isInside: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.presentation == .peek)
        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.presentation == .expanded)
    }

    @Test func closingByClickWithThePointerElsewhereShowsAHeldPeek() {
        let model = makeModel()
        model.clicked()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .seconds(5)))
        model.clicked()
        #expect(model.presentation == .peek)
    }

    @Test func resettingDropsAHeldPeek() async throws {
        let model = makeModel()
        let transitions = TransitionLog(model)
        model.pointer(.notch, isInside: true)
        model.clicked()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .seconds(2)))
        model.reset()

        model.pointer(.notch, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        model.pointer(.notch, isInside: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.presentation == .idle)
        #expect(!transitions.steps.contains { $0.hasSuffix("peek") })
    }

    @Test func aLiveChangeWhileThePointerCrossesOverDoesntReopenAClickClosedIsland() async throws {
        let activity = TestActivity()
        activities.register(activity)
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        model.clicked()
        #expect(model.presentation == .lifted)

        // Out and back within the exit grace, as between the notch's window and the island's, with a timer starting
        // in between: the pointer never really left, so the click-close still holds.
        model.pointer(.island, isInside: false)
        activity.isLive = true
        // The live update is a main-actor task, not a timer, so one turn delivers it well inside the exit grace.
        await Task.yield()
        #expect(model.activity?.id == activity.id)
        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.presentation == .lifted)
    }

    // MARK: When nobody can see the island

    @Test func theIslandIsOutOfSightWhileHiddenLockedOrAsleep() {
        let model = makeModel()
        let screen = Visibility()
        model.canBeSeen = { screen.canBeSeen }
        #expect(model.isVisible)

        model.isHidden = true
        #expect(!model.isVisible)
        model.isHidden = false
        #expect(model.isVisible)

        screen.canBeSeen = false
        model.islandWentOutOfSight()
        #expect(!model.isVisible)
        screen.canBeSeen = true
        model.visibilityMayHaveChanged()
        #expect(model.isVisible)
    }

    @Test func goingOutOfSightIsTakenAtItsWord() {
        let model = makeModel()
        // What `canBeSeen` reads still says the screen is unlocked, behind the notification.
        model.islandWentOutOfSight()
        #expect(!model.isVisible)
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", mustBeSeen: true))
        #expect(!model.isVisible)
    }

    @Test func theIslandOutForAPeekWhileHiddenIsOnScreen() async throws {
        activities.register(TestActivity(isLive: true))
        let model = makeModel()
        model.isHidden = true
        #expect(!model.isVisible)
        activities.peek(Peek(symbol: "battery.25", tint: .red, title: "Low battery", duration: .milliseconds(400),
                             mustBeSeen: true, source: "battery"))
        #expect(model.isVisible)

        // Hovered open over the full-screen app, its countdown keeps going.
        model.pointer(.island, isInside: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .expanded)
        #expect(model.isVisible)

        // Back at rest, it hides again.
        model.pointer(.island, isInside: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.isResting)
        #expect(!model.isVisible)
    }

    @Test func aPeekTheOwnerMustSeeWaitsUntilSomeoneCanSeeTheIsland() async throws {
        let model = makeModel()
        let screen = Visibility()
        model.canBeSeen = { screen.canBeSeen }
        screen.canBeSeen = false
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .milliseconds(300),
                             mustBeSeen: true))
        #expect(model.presentation == .idle)
        // Its time doesn't run out while it waits.
        try await Task.sleep(for: .milliseconds(400))
        model.visibilityMayHaveChanged()
        #expect(model.presentation == .idle)

        screen.canBeSeen = true
        model.visibilityMayHaveChanged()
        #expect(model.presentation == .peek)
        #expect(model.peek?.title == "Timer done")
        try await Task.sleep(for: .milliseconds(500))
        model.visibilityMayHaveChanged()
        #expect(model.presentation == .idle)
    }

    @Test func otherPeeksNobodyCouldSeeAreDropped() {
        let model = makeModel()
        let screen = Visibility()
        model.canBeSeen = { screen.canBeSeen }
        screen.canBeSeen = false
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging"))
        screen.canBeSeen = true
        model.visibilityMayHaveChanged()
        #expect(model.presentation == .idle)
    }

    @Test func aPeekThatWaitedToBeSeenStillWaitsForAnOpenIslandToClose() async throws {
        let model = makeModel()
        let screen = Visibility()
        model.canBeSeen = { screen.canBeSeen }
        model.pointer(.island, isInside: true)
        model.clicked()
        screen.canBeSeen = false
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .seconds(2),
                             mustBeSeen: true))
        screen.canBeSeen = true
        model.visibilityMayHaveChanged()
        #expect(model.presentation == .expanded)

        model.pointer(.island, isInside: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.presentation == .peek)
        #expect(model.peek?.title == "Timer done")
    }

    @Test func aHiddenIslandOnlyComesOutForAPeekTheOwnerMustSee() {
        let model = makeModel()
        model.isHidden = true
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging"))
        #expect(model.presentation == .idle)
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", mustBeSeen: true))
        #expect(model.presentation == .peek)
    }

    @Test func peeksTheOwnerMustSeeShowInTurnOnceSomeoneCan() async throws {
        let model = makeModel()
        let screen = Visibility()
        model.canBeSeen = { screen.canBeSeen }
        screen.canBeSeen = false
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .milliseconds(300),
                             mustBeSeen: true, source: "timer"))
        activities.peek(Peek(symbol: "battery.25", tint: .red, title: "Low battery", duration: .seconds(1),
                             mustBeSeen: true, source: "battery"))
        screen.canBeSeen = true
        model.visibilityMayHaveChanged()
        #expect(model.peek?.title == "Timer done")
        try await waitUntil { model.peek?.title == "Low battery" }
        #expect(model.presentation == .peek)
    }

    @Test func aShowingPeekTheOwnerMustSeeWaitsAgainWhenTheScreenLocks() async throws {
        let model = makeModel()
        let screen = Visibility()
        model.canBeSeen = { screen.canBeSeen }
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .milliseconds(300),
                             mustBeSeen: true))
        #expect(model.presentation == .peek)

        screen.canBeSeen = false
        model.islandWentOutOfSight()
        #expect(model.presentation == .idle)
        // Past its time, which only runs while someone can see it.
        try await Task.sleep(for: .milliseconds(400))
        screen.canBeSeen = true
        model.visibilityMayHaveChanged()
        #expect(model.presentation == .peek)
        #expect(model.peek?.title == "Timer done")
    }

    @Test func aPeekTheOwnerMustSeeKeepsWaitingWhileAnotherRunsOutUnseen() async throws {
        let model = makeModel()
        let screen = Visibility()
        model.canBeSeen = { screen.canBeSeen }
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging", duration: .milliseconds(200),
                             source: "battery"))
        screen.canBeSeen = false
        model.islandWentOutOfSight()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .milliseconds(300),
                             mustBeSeen: true, source: "timer"))
        // The charging peek closes behind the lock screen, and the timer's mustn't take its place there.
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.presentation == .idle)

        screen.canBeSeen = true
        model.visibilityMayHaveChanged()
        #expect(model.peek?.title == "Timer done")
    }

    @Test func otherWaitingPeeksGoWhenNobodyCanSeeThem() async throws {
        let model = makeModel()
        let transitions = TransitionLog(model)
        let screen = Visibility()
        model.canBeSeen = { screen.canBeSeen }
        model.pointer(.island, isInside: true)
        model.clicked()
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging", duration: .seconds(2)))
        screen.canBeSeen = false
        model.islandWentOutOfSight()
        screen.canBeSeen = true
        model.visibilityMayHaveChanged()

        model.pointer(.island, isInside: false)
        try await waitUntil { model.presentation == .idle }
        // Nothing follows: a stall can only hold back a peek that shouldn't come, never make one come.
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.presentation == .idle)
        #expect(!transitions.steps.contains { $0.hasSuffix("peek") })
    }

    // MARK: Taking turns

    @Test func anotherActivitysPeekWaitsForOneTheOwnerMustSee() async throws {
        let model = makeModel()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .seconds(1),
                             mustBeSeen: true, source: "timer"))
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging", duration: .milliseconds(500),
                             source: "battery"))
        #expect(model.peek?.title == "Timer done")
        // Its time from arrival runs out while it waits, but it gets its whole time once its turn comes.
        try await waitUntil { model.peek?.title == "Charging" }
        #expect(model.presentation == .peek)
        try await waitUntil { model.presentation == .idle }
    }

    @Test func onesTheOwnerMustSeeGoFirst() async throws {
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging", duration: .seconds(2),
                             source: "battery"))
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .seconds(2),
                             mustBeSeen: true, source: "timer"))
        model.pointer(.island, isInside: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.peek?.title == "Timer done")
    }

    @Test func newsWaitingBehindAPeekTheOwnerMustSeeStillGetsItsTurn() async throws {
        let keepAwake = TabbedTestActivity(id: "keepAwake", isLive: true)
        activities.register(keepAwake)
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        // Open on Keep Awake's tab, its news keeps only for its time, while the battery's waits as long as it takes.
        #expect(model.selectedTab == keepAwake.id)
        // The battery falls to 20% with the island open: its warning, then Keep Awake saying it turned off for it.
        activities.peek(Peek(symbol: "battery.25", tint: .red, title: "Low battery", duration: .seconds(1),
                             mustBeSeen: true, source: "battery"))
        activities.peek(Peek(symbol: "eye.slash.fill", tint: .orange, title: "Keep Awake off",
                             duration: .milliseconds(800), mustBeSeen: true, source: keepAwake.id))
        try await Task.sleep(for: .milliseconds(100))

        // Closing within Keep Awake's own time, it follows the warning, though its time from arrival has run out.
        model.pointer(.island, isInside: false)
        try await waitUntil { model.peek?.title == "Low battery" }
        try await waitUntil { model.peek?.title == "Keep Awake off" }
        #expect(model.presentation == .peek)
    }

    @Test func aNewerPeekFromTheSameActivityReplacesItsOwn() {
        let model = makeModel()
        activities.peek(Peek(symbol: "battery.25", tint: .red, title: "Low battery", duration: .seconds(5),
                             mustBeSeen: true, source: "battery"))
        // Plugging in answers a low battery, even one the owner must see.
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging", source: "battery"))
        #expect(model.peek?.title == "Charging")
    }

    @Test func aNewerPeekFromTheSameActivityReplacesItsOwnWhileItWaits() async throws {
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        activities.peek(Peek(symbol: "bolt.fill", tint: .green, title: "Charging", duration: .seconds(2),
                             source: "battery"))
        activities.peek(Peek(symbol: "battery.75", tint: .white, title: "On battery", duration: .seconds(1),
                             source: "battery"))

        model.pointer(.island, isInside: false)
        try await waitUntil { model.presentation == .peek }
        #expect(model.peek?.title == "On battery")
        // Its older news doesn't follow it.
        try await waitUntil { model.presentation == .idle }
    }

    @Test func hidingTheIslandKeepsAPeekTheOwnerMustSee() {
        let model = makeModel()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .seconds(2),
                             mustBeSeen: true))
        model.isHidden = true
        model.reset()
        #expect(model.presentation == .peek)
        #expect(model.peek?.title == "Timer done")
    }

    @Test func hidingTheOpenIslandBringsOutAPeekTheOwnerMustSee() {
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done", duration: .seconds(2),
                             mustBeSeen: true))
        #expect(model.presentation == .expanded)
        model.isHidden = true
        model.reset()
        #expect(model.presentation == .peek)
    }
}

/// Whether anyone can see the island, as a test sets it.
@MainActor
private final class Visibility {
    var canBeSeen = true
}

/// Where the pointer is, as a test moves it without the island hearing.
@MainActor
private final class PointerSpot {
    var isOnIsland: Bool

    init(isOnIsland: Bool) {
        self.isOnIsland = isOnIsland
    }
}

/// Each time the island asks to start or stop watching the pointer.
@MainActor
private final class WatchLog {
    var calls: [Bool] = []
}
