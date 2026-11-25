import AppKit
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

    @Test func neverRestsBesideTheNotchEvenWhenRed() {
        let usage = makeUsage()
        usage.record(claude(0.95))
        #expect(!usage.isLive)
        #expect(usage.tabTint == .red)
        usage.record(claude(1, resetsIn: 60))
        #expect(!usage.isLive)
        clock.now = clock.now.addingTimeInterval(61)
        usage.checkResets()
        #expect(!usage.isLive)
        #expect(usage.tabTint == nil)
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
        #expect(first.logo == .claude)
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

    /// A provider can hand usage back before the window ends.
    @Test func aCurrentNumberCanDropWithinAWindow() throws {
        let usage = makeUsage()
        usage.record(claude(0.97))
        usage.peekWasShown(try #require(log.peeks.last))
        usage.record(claude(0.13))
        #expect(usage.readings[.claude]?.windows.first?.used == 0.13)
        // Two sessions at work still don't flicker, whatever the rounding.
        usage.record(claude(0.11))
        #expect(usage.readings[.claude]?.windows.first?.used == 0.13)
        usage.record(claude(0.10))
        #expect(usage.readings[.claude]?.windows.first?.used == 0.10)
        // Climbing back is news again, and a window that doesn't end high isn't "back".
        usage.record(claude(0.96))
        #expect(log.peeks.count == 2)
        usage.record(claude(0.13))
        clock.now = clock.now.addingTimeInterval(3_601)
        usage.checkResets()
        #expect(log.peeks.count == 2)
    }

    /// An idle Claude Code session repeats the limits it last heard, for hours.
    @Test func aSessionRepeatingOldNumbersChangesNothing() {
        let usage = makeUsage()
        usage.record(claude(0.97), isCurrent: false)
        #expect(usage.readings[.claude]?.windows.first?.used == 0.97)
        usage.record(claude(0.13))
        usage.record(claude(0.97), isCurrent: false)
        usage.record(claude(0.05), isCurrent: false)
        #expect(usage.readings[.claude]?.windows.first?.used == 0.13)
        #expect(log.peeks.count == 1)
        // Nor does it bring back a window that came before this one.
        usage.record(claude(0.99, resetsIn: -3_600), isCurrent: false)
        #expect(usage.readings[.claude]?.windows.first?.used == 0.13)
        // The next window is news from anyone.
        usage.record(claude(0.02, resetsIn: 6 * 3_600), isCurrent: false)
        #expect(usage.readings[.claude]?.windows.first?.used == 0.02)
    }

    @Test func aWarningThatWaitedThroughADropIsNotRecorded() throws {
        let usage = makeUsage()
        usage.record(claude(0.97))
        let waiting = try #require(log.peeks.last)
        usage.record(claude(0.13))
        usage.peekWasShown(waiting)
        clock.now = clock.now.addingTimeInterval(3_601)
        usage.checkResets()
        #expect(log.peeks.count == 1)
    }

    @Test func aSessionsLimitsAreCurrentOnceItsRequestTimeGrows() {
        let usage = makeUsage()
        #expect(!usage.noteClaudeRequestTime(1_000, session: "a"))
        #expect(!usage.noteClaudeRequestTime(1_000, session: "a"))
        #expect(usage.noteClaudeRequestTime(1_500, session: "a"))
    }

    /// A concurrent session finishing a long request with the lower limits it started with does not flicker the window
    /// down; a genuine handback is still accepted once confirmed across time or another session.
    @Test func aLongRequestInAnotherSessionDoesNotFlickerClaudeDown() {
        let usage = makeUsage()
        usage.record(claude(0.49), session: "s2")
        // Another session finishes a long turn holding the 45% it started with.
        usage.record(claude(0.45), session: "s1")
        #expect(usage.readings[.claude]?.windows.first?.used == 0.49)
        // Even a second quick reading from s1 within the window does not drop it.
        clock.now = clock.now.addingTimeInterval(5)
        usage.record(claude(0.45), session: "s1")
        #expect(usage.readings[.claude]?.windows.first?.used == 0.49)
        // s2 still sees 49%, clearing the held drop; an idle repeat from s2 doesn't.
        usage.record(claude(0.49), session: "s2")
        #expect(usage.readings[.claude]?.windows.first?.used == 0.49)
        usage.record(claude(0.13), session: "s1")
        usage.record(claude(0.49), isCurrent: false, session: "s2")
        // A second session seeing the drop confirms it immediately.
        usage.record(claude(0.13), session: "s3")
        #expect(usage.readings[.claude]?.windows.first?.used == 0.13)

        // The session that set the peak can still drop immediately on its own.
        usage.record(claude(0.82), session: "s3")
        usage.record(claude(0.13), session: "s3")
        #expect(usage.readings[.claude]?.windows.first?.used == 0.13)

        // When quota really is handed back, s1 alone confirms it after working longer.
        usage.record(claude(0.90), session: "s2")
        usage.record(claude(0.13), session: "s1")
        #expect(usage.readings[.claude]?.windows.first?.used == 0.90)
        clock.now = clock.now.addingTimeInterval(UsageActivity.claudeWorkingFor)
        usage.record(claude(0.13), session: "s1")
        #expect(usage.readings[.claude]?.windows.first?.used == 0.13)

        // A new window resets the peak session.
        usage.record(claude(0.50, resetsIn: 6 * 3_600), session: "s2")
        usage.record(claude(0.05, resetsIn: 12 * 3_600), session: "s1")
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
        #expect(!after.isLive)
        #expect(after.tabTint == .red)
        after.record(claude(0.97))
        #expect(log.peeks.count == count)
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

    @Test func codexKeepsTheNewestReadingEvenWhenTheNumbersStayTheSame() {
        let usage = makeUsage()
        let first = UsageReading(provider: .codex, windows: [
            UsageWindow(id: "primary", label: "5h", used: 0.33, resetsAt: clock.now.addingTimeInterval(3_600)),
        ], measuredAt: clock.now)
        usage.record(first)
        var confirmed = first
        confirmed.measuredAt.addTimeInterval(60)
        usage.record(confirmed)
        #expect(usage.readings[.codex] == confirmed)

        var late = first
        late.windows[0].used = 0.9
        usage.record(late)
        #expect(usage.readings[.codex] == confirmed)

        var lower = confirmed
        lower.measuredAt.addTimeInterval(60)
        lower.windows[0].used = 0.32
        usage.record(lower)
        #expect(usage.readings[.codex] == lower)
    }

    @Test func usageStartsWithClaudeOnlyAndDropsPausedAntigravityFromLegacyDefaults() throws {
        let suiteName = "JambulTests.UsagePreferences"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = Preferences(defaults: defaults)
        #expect(preferences.usageProviders == [.claude])
        #expect(!preferences.claudeStatusLineAgreed)
        preferences.usageProviders = [.codex, .antigravity]
        #expect(preferences.usageProviders == [.codex])
        preferences.claudeStatusLineAgreed = true
        let relaunched = Preferences(defaults: defaults)
        #expect(relaunched.usageProviders == [.codex])
        #expect(relaunched.claudeStatusLineAgreed)

        // Upgrading from an older version that saved Antigravity enabled still keeps it disabled.
        defaults.set(["claude", "antigravity"], forKey: "usageProviders")
        let upgraded = Preferences(defaults: defaults)
        #expect(upgraded.usageProviders == [.claude])
    }

    /// Each AI tool's symbol fills most of its square without spilling out, and no two are alike. The capitals come
    /// from the system font at run time, so a failed lookup would leave a tool without one.
    @Test func everyToolHasItsOwnSymbol() {
        let square = CGRect(x: 0, y: 0, width: 16, height: 16)
        let outlines = UsageProvider.allCases.map { ProviderSymbolShape(provider: $0).path(in: square) }
        for outline in outlines {
            let bounds = outline.boundingRect
            #expect(bounds.height > square.height * 0.6)
            #expect(square.insetBy(dx: -0.5, dy: -0.5).contains(bounds))
        }
        #expect(Set(outlines.map(\.description)).count == outlines.count)
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
