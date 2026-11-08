import Foundation
import Testing
@testable import Jambul

@MainActor
private final class Clock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

@MainActor
private final class PeekLog {
    var peeks: [Peek] = []
}

@MainActor
@Suite(.serialized)
struct UsageActivityTests {
    private let activities = ActivityCenter()
    private let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
    private let log = PeekLog()

    private func makeUsage(defaults: UserDefaults? = nil) -> UsageActivity {
        activities.onPeek = { [log] in log.peeks.append($0) }
        let usage = UsageActivity(activities: activities, defaults: defaults, now: { [clock] in clock.now })
        usage.enabled = [.claude, .antigravity]
        return usage
    }

    private func claude(_ used: Double, resetsIn interval: TimeInterval = 3_600) -> UsageReading {
        UsageReading(provider: .claude, windows: [
            UsageWindow(id: "five_hour", label: "5h", used: used, resetsAt: clock.now.addingTimeInterval(interval)),
            UsageWindow(id: "seven_day", label: "7d", used: 0.2, resetsAt: clock.now.addingTimeInterval(86_400)),
        ], measuredAt: clock.now)
    }

    @Test func comesBesideTheNotchFrom95Percent() {
        let usage = makeUsage()
        usage.record(claude(0.94))
        #expect(!usage.isLive)
        usage.record(claude(0.95))
        #expect(usage.isLive)
        #expect(usage.pressing?.provider == .claude)
        #expect(usage.pressing?.window.id == "five_hour")
    }

    @Test func leavesOnceTheLimitStartsOver() {
        let usage = makeUsage()
        usage.record(claude(1, resetsIn: 60))
        #expect(usage.isLive)
        clock.now = clock.now.addingTimeInterval(61)
        usage.checkResets()
        #expect(!usage.isLive)
    }

    @Test func aSubscriptionTurnedOffCountsForNothing() {
        let usage = makeUsage()
        usage.enabled = [.antigravity]
        usage.record(claude(0.99))
        #expect(!usage.isLive)
        #expect(log.peeks.isEmpty)
    }

    @Test func aWarningIsOnlyRecordedOnceTheIslandShowedIt() throws {
        let usage = makeUsage()
        usage.record(claude(0.81))
        let first = try #require(log.peeks.last)
        #expect(!first.mustBeSeen)
        #expect(first.logo == "ClaudeLogo")
        #expect(first.progress == 0.81)
        // Not shown yet, so new numbers ask again; the newer peek replaces the waiting one on the island.
        usage.record(claude(0.82))
        #expect(log.peeks.count == 2)
        // Another activity's peek showing says nothing about this one.
        usage.peekWasShown(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done"))
        usage.record(claude(0.83))
        #expect(log.peeks.count == 3)
        usage.peekWasShown(try #require(log.peeks.last))
        usage.record(claude(0.84))
        #expect(log.peeks.count == 3)
    }

    @Test func at95PercentThePeekMustBeSeen() throws {
        let usage = makeUsage()
        usage.record(claude(0.96))
        let peek = try #require(log.peeks.last)
        #expect(peek.mustBeSeen)
        #expect(peek.motion == .pulse)
    }

    @Test func runningOutSaysWhenItComesBack() throws {
        let usage = makeUsage()
        usage.record(claude(1))
        let peek = try #require(log.peeks.last)
        #expect(peek.mustBeSeen)
        #expect(peek.motion == .sleep)
        #expect(peek.progress == 1)
    }

    @Test func saysBackWhenALimitThatReached95StartsOver() throws {
        let usage = makeUsage()
        usage.record(claude(0.96, resetsIn: 60))
        usage.peekWasShown(try #require(log.peeks.last))
        clock.now = clock.now.addingTimeInterval(61)
        usage.checkResets()
        let back = try #require(log.peeks.last)
        #expect(back.motion == .bounce)
        #expect(!back.mustBeSeen)
        usage.peekWasShown(back)
        usage.checkResets()
        #expect(log.peeks.last?.id == back.id)
    }

    @Test func aLimitThatOnlyReached80SaysNothingWhenItStartsOver() throws {
        let usage = makeUsage()
        usage.record(claude(0.85, resetsIn: 60))
        usage.peekWasShown(try #require(log.peeks.last))
        let count = log.peeks.count
        clock.now = clock.now.addingTimeInterval(61)
        usage.checkResets()
        #expect(log.peeks.count == count)
    }

    /// Two Claude Code sessions each report the limits they last heard, a point apart.
    @Test func aLowerNumberForTheSameWindowDoesntFlicker() {
        let usage = makeUsage()
        usage.record(claude(0.82))
        usage.record(claude(0.81))
        #expect(usage.readings[.claude]?.windows.first?.used == 0.82)
        usage.record(claude(0.83))
        #expect(usage.readings[.claude]?.windows.first?.used == 0.83)
        // The next window starts low again.
        usage.record(claude(0.05, resetsIn: 5 * 3_600 + 3_600))
        #expect(usage.readings[.claude]?.windows.first?.used == 0.05)
    }

    @Test func theNumbersAndWarningsSurviveARelaunch() throws {
        let suiteName = "JambulTests.Usage"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let before = makeUsage(defaults: defaults)
        before.record(claude(0.96))
        before.peekWasShown(try #require(log.peeks.last))
        let count = log.peeks.count

        let after = makeUsage(defaults: defaults)
        #expect(after.readings[.claude]?.windows.first?.used == 0.96)
        #expect(after.isLive)
        after.record(claude(0.97))
        #expect(log.peeks.count == count)
    }

    /// Each fits the 36 pt beside the notch at 13 pt (measured: "100%" 38 pt and "23h59" 42 pt don't).
    @Test(arguments: [(4_800, "1h20"), (2_700, "45m"), (59, "1m"), (-5, "0m"), (7_200, "2h00"), (41_400, "12h"),
                      (108_000, "1d6h"), (259_200, "3d"), (604_740, "7d"), (1_728_000, "20d")] as [(TimeInterval, String)])
    func theCountdownFitsBesideTheNotch(remaining: TimeInterval, text: String) {
        #expect(UsageActivity.countdown(remaining) == text)
    }

    @Test func aPercentageNeverReads100BeforeTheLimitRunsOut() {
        #expect(UsageActivity.percentText(0.999).hasPrefix("99"))
        #expect(UsageActivity.percentText(1).hasPrefix("100"))
    }

    @Test func aLimitDaysAwaySaysWhichDayItComesBack() {
        let now = clock.now
        #expect(UsageActivity.backText(now.addingTimeInterval(60), now: now).hasPrefix("back at"))
        #expect(!UsageActivity.backText(now.addingTimeInterval(3 * 86_400), now: now).hasPrefix("back at"))
    }

    @Test func onlyRequestsMeanClaudeIsWorking() {
        let usage = makeUsage()
        usage.noteClaudeRequestTime(1_000, session: "a")
        #expect(!usage.isClaudeWorking)
        // The status line on its timer, with no new request.
        usage.noteClaudeRequestTime(1_000, session: "a")
        #expect(!usage.isClaudeWorking)
        usage.noteClaudeRequestTime(1_500, session: "a")
        #expect(usage.isClaudeWorking)
        clock.now = clock.now.addingTimeInterval(UsageActivity.claudeWorkingFor + 1)
        #expect(!usage.isClaudeWorking)
    }

    @Test func aWindowWithoutAResetTimeCanGoDown() {
        let usage = makeUsage()
        let window = { (used: Double) in
            UsageReading(provider: .codex, windows: [UsageWindow(id: "primary", label: "5h", used: used, resetsAt: nil)],
                         measuredAt: clock.now)
        }
        usage.record(window(0.5))
        usage.record(window(0.2))
        #expect(usage.readings[.codex]?.windows.first?.used == 0.2)
    }

    @Test func usageStartsWithClaudeAndAntigravityAndAsksBeforeClaude() throws {
        let suiteName = "JambulTests.UsagePreferences"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = Preferences(defaults: defaults)
        #expect(preferences.usageProviders == [.claude, .antigravity])
        #expect(!preferences.claudeStatusLineAgreed)
        preferences.usageProviders = [.codex]
        preferences.claudeStatusLineAgreed = true
        let relaunched = Preferences(defaults: defaults)
        #expect(relaunched.usageProviders == [.codex])
        #expect(relaunched.claudeStatusLineAgreed)
    }
}

/// The island tells activities when a peek really shows: one that waits, or that nobody can see, isn't told yet.
@MainActor
struct PeekShownTests {
    private let activities = ActivityCenter()
    private let log = PeekLog()

    private func makeModel() -> IslandModel {
        activities.onPeekShown = { [log] in log.peeks.append($0) }
        return IslandModel(notch: NotchMetrics(size: CGSize(width: 180, height: 32), compactHeight: 33),
                           activities: activities)
    }

    @Test func theIslandTellsWhenAPeekShows() {
        let model = makeModel()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Hi"))
        #expect(model.presentation == .peek)
        #expect(log.peeks.map(\.title) == ["Hi"])
    }

    @Test func aPeekThatWaitsIsToldOnceItShows() async throws {
        let model = makeModel()
        model.pointer(.island, isInside: true)
        model.clicked()
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Later", duration: .seconds(2)))
        #expect(log.peeks.isEmpty)
        model.pointer(.island, isInside: false)
        try await waitUntil { !log.peeks.isEmpty }
        #expect(log.peeks.map(\.title) == ["Later"])
    }

    @Test func aPeekNobodyCanSeeIsNotTold() {
        let model = makeModel()
        model.canBeSeen = { false }
        activities.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Hi"))
        #expect(log.peeks.isEmpty)
    }
}
