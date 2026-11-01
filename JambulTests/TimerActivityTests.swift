import AppKit
import SwiftUI
import Testing
@testable import Jambul

/// Most of these run on a clock the test moves by hand; the ones about the real wait use short real durations.
@MainActor
struct TimerActivityTests {
    private let activities = ActivityCenter()
    private let clock = TestClock()
    private let log = FinishLog()

    init() {
        activities.onPeek = { [log] in log.peeks.append($0) }
    }

    private func makeTimer() -> TimerActivity {
        TimerActivity(activities: activities, now: { [clock] in clock.now }, onFinish: { [log] in log.chimes += 1 })
    }

    @Test func startingCountsDownFromNow() {
        let timer = makeTimer()
        let start = clock.now
        timer.start(.seconds(300))
        #expect(timer.isLive)
        #expect(timer.state == .running(start...start.addingTimeInterval(300)))
        clock.advance(by: 60)
        #expect(timer.remaining(at: clock.now) == 240)
        #expect(timer.fraction(at: clock.now) == 0.8)
    }

    @Test func pausingHoldsTheTimeLeft() {
        let timer = makeTimer()
        timer.start(.seconds(300))
        clock.advance(by: 60)
        timer.pause()
        clock.advance(by: 100)
        #expect(timer.isLive)
        #expect(timer.isPaused)
        #expect(timer.remaining(at: clock.now) == 240)
    }

    @Test func resumingPicksUpWhereItPaused() {
        let timer = makeTimer()
        let start = clock.now
        timer.start(.seconds(300))
        clock.advance(by: 60)
        timer.pause()
        clock.advance(by: 100)
        timer.resume()
        // The whole interval moves by the pause, so the ring picks up where it stopped too.
        #expect(timer.state == .running(start.addingTimeInterval(100)...start.addingTimeInterval(400)))
        #expect(timer.remaining(at: clock.now) == 240)
    }

    @Test func addingAMinuteGrowsTheTimeLeftAndTheWhole() {
        let timer = makeTimer()
        let start = clock.now
        timer.start(.seconds(300))
        clock.advance(by: 290)
        timer.addMinute()
        #expect(timer.state == .running(start...start.addingTimeInterval(360)))
        #expect(timer.remaining(at: clock.now) == 70)
        #expect(timer.fraction(at: clock.now) <= 1)
    }

    @Test func addingAMinuteWhilePausedStaysPaused() {
        let timer = makeTimer()
        timer.start(.seconds(300))
        clock.advance(by: 60)
        timer.pause()
        timer.addMinute()
        clock.advance(by: 30)
        #expect(timer.isPaused)
        #expect(timer.remaining(at: clock.now) == 300)
    }

    @Test func aResumedTimerFinishesAtItsShiftedEnd() async throws {
        let timer = TimerActivity(activities: activities, onFinish: { [log] in log.chimes += 1 })
        timer.start(.milliseconds(400))
        try await Task.sleep(for: .milliseconds(50))
        timer.pause()
        try await Task.sleep(for: .milliseconds(300))
        timer.resume()
        // About 350 ms were left: the first end has passed, the new one hasn't.
        try await Task.sleep(for: .milliseconds(100))
        #expect(timer.isRunning)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!timer.isLive)
        #expect(log.chimes == 1)
    }

    @Test func pausingJustAfterTheEndFinishesInstead() {
        let timer = makeTimer()
        timer.start(.seconds(300))
        // The time is up, but the wake-up hasn't run yet.
        clock.advance(by: 300.004)
        timer.pause()
        #expect(!timer.isLive)
        #expect(log.chimes == 1)
        #expect(log.peeks.map(\.title) == ["Timer done"])
    }

    @Test func aCountdownNeedsTimeToCount() {
        let timer = makeTimer()
        timer.start(.seconds(-5))
        timer.start(.zero)
        #expect(!timer.isLive)
    }

    @Test func idleTimersIgnoreTheControls() {
        let timer = makeTimer()
        timer.pause()
        timer.resume()
        timer.addMinute()
        timer.stop()
        #expect(timer.state == .idle)
        #expect(!timer.isLive)
        #expect(timer.remaining(at: clock.now) == 0)
        #expect(timer.fraction(at: clock.now) == 0)
    }

    @Test func stoppingEndsQuietly() {
        let timer = makeTimer()
        timer.start(.seconds(300))
        timer.stop()
        clock.advance(by: 400)
        timer.checkTime()
        #expect(timer.state == .idle)
        #expect(log.peeks.isEmpty)
        #expect(log.chimes == 0)
    }

    @Test func finishingPeeksAndChimesOnce() async throws {
        let timer = TimerActivity(activities: activities, onFinish: { [log] in log.chimes += 1 })
        timer.start(.milliseconds(100))
        try await Task.sleep(for: .milliseconds(300))
        #expect(timer.state == .idle)
        #expect(log.chimes == 1)
        #expect(log.peeks.map(\.title) == ["Timer done"])
        #expect(log.peeks.first?.duration == TimerActivity.donePeekDuration)
        // The owner asked to be told, so it waits for them if nobody can see the island.
        #expect(log.peeks.first?.mustBeSeen == true)
    }

    @Test func aTimerThatEndedDuringSleepFinishesOnceOnWake() {
        let timer = makeTimer()
        timer.start(.seconds(300))
        clock.advance(by: 3_600)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        // A second wake finds nothing left to finish.
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(timer.state == .idle)
        #expect(log.chimes == 1)
        #expect(log.peeks.count == 1)
    }

    @Test func anEndReachedInADarkWakeWaitsForTheFullWake() {
        let timer = makeTimer()
        timer.start(.seconds(300))
        // Both notifications go out in the same turn, so no other test's timer ever sees the Mac asleep.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        clock.advance(by: 3_600)
        // The wake-up fires in a dark wake, with the display off and no sound.
        timer.checkTime()
        #expect(timer.isRunning)
        #expect(log.chimes == 0)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!timer.isLive)
        #expect(log.chimes == 1)
        #expect(log.peeks.count == 1)
    }

    @Test func aChangedClockIsCheckedAtOnce() async throws {
        let timer = makeTimer()
        timer.start(.seconds(300))
        clock.advance(by: 3_600)
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!timer.isLive)
        #expect(log.chimes == 1)
    }

    @Test func theMacMaySleepAgainOnceTheCountdownStops() {
        let timer = makeTimer()
        timer.start(.seconds(300))
        #expect(timer.isKeepingMacAwake)
        timer.pause()
        #expect(!timer.isKeepingMacAwake)
        timer.resume()
        #expect(timer.isKeepingMacAwake)
        timer.stop()
        #expect(!timer.isKeepingMacAwake)

        timer.start(.seconds(300))
        clock.advance(by: 300)
        timer.checkTime()
        #expect(!timer.isLive)
        #expect(!timer.isKeepingMacAwake)
    }

    @Test func aTimerCanLeaveTheMacFreeToSleep() {
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        timer.start(.seconds(300))
        #expect(timer.isRunning)
        #expect(!timer.isKeepingMacAwake)
    }

    @Test func aRegisteredTimerGoesAwayWithItsCenter() async throws {
        weak var timer: TimerActivity?
        do {
            let center = ActivityCenter()
            let running = TimerActivity(activities: center)
            center.register(running)
            running.start(.seconds(300))
            timer = running
        }
        // The center reads its new live activity a turn later, and lets go of itself then.
        try await Task.sleep(for: .milliseconds(50))
        #expect(timer == nil)
    }

    @Test func checkingBeforeTheEndKeepsCounting() {
        let timer = makeTimer()
        timer.start(.seconds(300))
        clock.advance(by: 299)
        timer.checkTime()
        #expect(timer.isRunning)
        #expect(log.chimes == 0)
    }

    @Test func aPausedTimerNeverFinishes() {
        let timer = makeTimer()
        timer.start(.seconds(300))
        timer.pause()
        clock.advance(by: 3_600)
        timer.checkTime()
        #expect(timer.isPaused)
        #expect(log.chimes == 0)
    }

    @Test func theTimerOutranksOtherLiveActivities() {
        let center = ActivityCenter()
        center.register(TestActivity(id: "other", isLive: true))
        let timer = TimerActivity(activities: center)
        center.register(timer)
        #expect(center.liveActivity?.id == "other")
        timer.start(.seconds(60))
        #expect(center.liveActivity?.id == timer.id)
        timer.stop()
        #expect(center.liveActivity?.id == "other")
    }

    @Test func theTimerHasATabAndAPlainActivityDoesnt() {
        #expect(makeTimer().hasTab)
        #expect(!TestActivity().hasTab)
    }

    @Test func theCompactSlotFitsTheLongestCountdown() {
        let timer = makeTimer()
        // The widest countdown under an hour and the widest after; digits are all one width.
        for seconds in [59 * 60 + 59, 9 * 3_600 + 59 * 60 + 59] {
            timer.start(.seconds(seconds))
            timer.pause()
            let width = NSHostingView(rootView: timer.compactTrailing).fittingSize.width
            #expect(width <= timer.compactSlotWidth, "\(seconds) s is drawn \(width) pt wide")
        }
    }

    @Test func itsTabFitsBelowTheNotchIdleOrCounting() {
        let timer = makeTimer()
        let notch = NotchMetrics(size: CGSize(width: 179, height: 32), compactHeight: 33)
        let room = CGSize(width: IslandLayout.expandedSize.width - 2 * IslandLayout.expandedContentInset,
                          height: IslandLayout.expandedContentRoom(notch))
        // Idle with its quick starts, then counting down from the widest time with its controls.
        for counting in [false, true] {
            if counting {
                timer.start(.seconds(9 * 3_600 + 59 * 60 + 59))
                timer.pause()
            }
            let size = NSHostingView(rootView: timer.tab).fittingSize
            #expect(size.width <= room.width && size.height <= room.height, "\(size) in \(room)")
        }
    }

    @Test func itsTabSaysWhenTheCountdownEnds() {
        let english = Locale(identifier: "en_US")
        let end = clock.now.addingTimeInterval(300)
        let line = TimerActivity.endLine(for: .running(clock.now...end), locale: english)
        #expect(line == "Ends \(end.formatted(.dateTime.hour().minute().locale(english)))")
        #expect(TimerActivity.endLine(for: .paused(clock.now...end, at: clock.now), locale: english) == "Paused")
    }

    @Test func stoppingLeavesTheLastTimeOnScreenWhileTheViewGoes() {
        let timer = makeTimer()
        timer.start(.seconds(300))
        clock.advance(by: 60)
        timer.pause()
        let left = timer.shown.remaining(at: clock.now)
        timer.stop()
        // The view leaving the island draws this, not 0:00 and an empty ring.
        #expect(!timer.isLive)
        #expect(timer.shown.remaining(at: clock.now) == left)
        #expect(timer.shown.isPaused)

        timer.start(.seconds(600))
        #expect(timer.shown == timer.state)
    }

    // MARK: Display

    @Test func theCountdownRoundsUpToTheNextSecond() {
        let english = Locale(identifier: "en_US")
        #expect(TimerActivity.format(300, locale: english) == "5:00")
        #expect(TimerActivity.format(299.4, locale: english) == "5:00")
        #expect(TimerActivity.format(299, locale: english) == "4:59")
        #expect(TimerActivity.format(59.5, locale: english) == "1:00")
        #expect(TimerActivity.format(0.4, locale: english) == "0:01")
        // It reaches 0:00 just as the time is up, and stays there.
        #expect(TimerActivity.format(0, locale: english) == "0:00")
        #expect(TimerActivity.format(-3, locale: english) == "0:00")
        #expect(TimerActivity.format(3_599.5, locale: english) == "1:00:00")
        #expect(TimerActivity.format(3_700, locale: english) == "1:01:40")
    }

    @Test func aTickARoundingErrorPastASecondDoesntAddOne() {
        let english = Locale(identifier: "en_US")
        #expect(TimerActivity.format(180.000_000_1, locale: english) == "3:00")
        #expect(TimerActivity.format(179.999_999_9, locale: english) == "3:00")
    }

    @Test func aRunningCountdownTicksOnlyWhileSomeoneCanSeeIt() {
        let interval = clock.now...clock.now.addingTimeInterval(300)
        #expect(TimerTicks<EmptyView>.ticking(.running(interval), isVisible: true) == interval)
        // Behind the hidden island, a sleeping display or the lock screen, it draws once and holds still.
        #expect(TimerTicks<EmptyView>.ticking(.running(interval), isVisible: false) == nil)
        #expect(TimerTicks<EmptyView>.ticking(.paused(interval, at: clock.now), isVisible: true) == nil)
    }

    @Test func ticksLandOnWholeSecondsBeforeTheEnd() {
        let start = clock.now
        #expect(TimerActivity.firstTick(of: start...start.addingTimeInterval(300)) == start)
        // After a resume the bounds sit on fractions of a second; ticks follow the end, not the start.
        let end = start.addingTimeInterval(300.4)
        #expect(TimerActivity.firstTick(of: start...end) == end.addingTimeInterval(-301))
    }

    // MARK: On the island

    private func makeIsland(with timer: TimerActivity) -> IslandModel {
        activities.register(timer)
        return IslandModel(notch: NotchMetrics(size: CGSize(width: 180, height: 32), compactHeight: 33),
                           activities: activities)
    }

    @Test func startingFromItsTabKeepsTheIslandOpenOnIt() async throws {
        let timer = makeTimer()
        let island = makeIsland(with: timer)
        island.pointer(.island, isInside: true)
        island.clicked()
        #expect(island.presentation == .expanded)
        #expect(island.selectedTab == timer.id)

        timer.start(.seconds(300))
        try await Task.sleep(for: .milliseconds(50))
        #expect(island.presentation == .expanded)
        #expect(island.activity?.id == timer.id)
        #expect(island.selectedTab == timer.id)
    }

    @Test func theTimerStartsFromTheOpenIslandWhileAnotherActivityIsLive() async throws {
        let timer = makeTimer()
        let other = TestActivity(id: "other", isLive: true)
        activities.register(other)
        let island = makeIsland(with: timer)
        island.pointer(.island, isInside: true)
        island.clicked()
        // The other activity has no tab, so the timer's opens, with its quick durations.
        #expect(island.selectedTab == timer.id)

        timer.start(.seconds(300))
        try await Task.sleep(for: .milliseconds(50))
        #expect(island.presentation == .expanded)
        #expect(island.liveActivities.map(\.id) == [timer.id, other.id])
        #expect(island.selectedTab == timer.id)
        // Beside the notch, the other activity's glyph on the left and the countdown on the right.
        #expect(island.compactActivities.map(\.id) == [timer.id, other.id])
    }

    @Test func stoppingWhileOpenStaysOnTheTimersTab() async throws {
        let timer = makeTimer()
        let island = makeIsland(with: timer)
        timer.start(.seconds(300))
        island.pointer(.island, isInside: true)
        island.clicked()
        try await Task.sleep(for: .milliseconds(50))
        #expect(island.activity?.id == timer.id)

        timer.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(island.presentation == .expanded)
        #expect(island.activity == nil)
        #expect(island.selectedTab == timer.id)
    }

    @Test func finishingAtRestGoesStraightToThePeek() async throws {
        let timer = makeTimer()
        let island = makeIsland(with: timer)
        let transitions = TransitionLog(island)
        timer.start(.seconds(300))
        try await Task.sleep(for: .milliseconds(50))
        #expect(island.presentation == .compact)

        clock.advance(by: 300)
        timer.checkTime()
        try await Task.sleep(for: .milliseconds(50))
        // Never folding into the notch first, only to grow out again for the peek.
        #expect(transitions.steps == ["idle → compact", "compact → peek"])
        #expect(island.peek?.title == "Timer done")
        #expect(island.activity == nil)
    }
}

@MainActor
private final class TestClock {
    private(set) var now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func advance(by seconds: TimeInterval) {
        now.addTimeInterval(seconds)
    }
}

@MainActor
private final class FinishLog {
    var peeks: [Peek] = []
    var chimes = 0
}
