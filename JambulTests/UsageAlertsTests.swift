import Foundation
import Testing
@testable import Jambul

struct UsageAlertsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ used: Double, resetsIn interval: TimeInterval = 3_600, window: String = "five_hour",
                         provider: UsageProvider = .claude) -> UsageReading {
        UsageReading(provider: provider, windows: [
            UsageWindow(id: window, label: "5h", used: used, resetsAt: now.addingTimeInterval(interval)),
        ], measuredAt: now)
    }

    @Test(arguments: [(0.5, nil), (0.8, UsageAlerts.Kind.warning80), (0.94, .warning80), (0.95, .warning95),
                      (0.999, .warning95), (1.0, .out)])
    func eachLevelHasItsWarning(used: Double, kind: UsageAlerts.Kind?) {
        #expect(UsageAlerts().warning(for: reading(used), at: now)?.kind == kind)
    }

    @Test func aWarningComesOnceItHasShown() throws {
        var alerts = UsageAlerts()
        let warning = try #require(alerts.warning(for: reading(0.82), at: now))
        // Until the island has shown it, every new reading still asks for it.
        #expect(alerts.warning(for: reading(0.83), at: now) == warning.with(used: 0.83))
        alerts.markShown(warning)
        #expect(alerts.warning(for: reading(0.85), at: now) == nil)
        #expect(alerts.warning(for: reading(0.96), at: now)?.kind == .warning95)
    }

    @Test func jumpingPastALevelSaysOnlyTheHigherOne() throws {
        var alerts = UsageAlerts()
        let warning = try #require(alerts.warning(for: reading(0.97), at: now))
        #expect(warning.kind == .warning95)
        alerts.markShown(warning)
        // 80% is covered by the 95% already shown.
        #expect(alerts.warning(for: reading(0.97), at: now) == nil)
        #expect(alerts.warning(for: reading(1), at: now)?.kind == .out)
    }

    @Test func aResetTimeThatDriftsIsTheSameWindow() throws {
        var alerts = UsageAlerts()
        alerts.markShown(try #require(alerts.warning(for: reading(0.81), at: now)))
        // Ten minutes later on the clock it resets at, as a provider may say from one reading to the next.
        #expect(alerts.warning(for: reading(0.84, resetsIn: 3_600 + 600), at: now) == nil)
    }

    @Test func theNextWindowWarnsAgain() throws {
        var alerts = UsageAlerts()
        alerts.markShown(try #require(alerts.warning(for: reading(0.81), at: now)))
        // Five hours later: a new window that resets five hours after the first.
        let later = now.addingTimeInterval(5 * 3_600)
        let next = UsageReading(provider: .claude, windows: [
            UsageWindow(id: "five_hour", label: "5h", used: 0.81, resetsAt: later.addingTimeInterval(3_600)),
        ], measuredAt: later)
        #expect(alerts.warning(for: next, at: later)?.kind == .warning80)
    }

    @Test func eachWindowAndProviderKeepsItsOwnRecord() throws {
        var alerts = UsageAlerts()
        alerts.markShown(try #require(alerts.warning(for: reading(0.81), at: now)))
        #expect(alerts.warning(for: reading(0.81, window: "seven_day"), at: now)?.kind == .warning80)
        #expect(alerts.warning(for: reading(0.81, provider: .codex), at: now)?.kind == .warning80)
    }

    @Test func aWindowThatReached95SaysBackOnceItResets() throws {
        var alerts = UsageAlerts()
        alerts.markShown(try #require(alerts.warning(for: reading(0.96, resetsIn: 60), at: now)))
        #expect(alerts.backAlerts(at: now).isEmpty)
        let afterReset = now.addingTimeInterval(61)
        let back = try #require(alerts.backAlerts(at: afterReset).first)
        #expect(back.kind == .back)
        #expect(back.provider == .claude)
        #expect(back.windowID == "five_hour")
        alerts.markShown(back)
        #expect(alerts.backAlerts(at: afterReset).isEmpty)
    }

    @Test func aWindowThatOnlyReached80SaysNothingWhenItResets() throws {
        var alerts = UsageAlerts()
        alerts.markShown(try #require(alerts.warning(for: reading(0.85, resetsIn: 60), at: now)))
        #expect(alerts.backAlerts(at: now.addingTimeInterval(61)).isEmpty)
    }

    @Test func aWindowThatHasResetWarnsOfNothing() {
        #expect(UsageAlerts().warning(for: reading(1, resetsIn: -1), at: now) == nil)
    }

    @Test func oldWindowsAreForgotten() throws {
        var alerts = UsageAlerts()
        alerts.markShown(try #require(alerts.warning(for: reading(0.96, resetsIn: 60), at: now)))
        alerts.forgetOld(at: now.addingTimeInterval(UsageAlerts.memory + 61))
        #expect(alerts.records.isEmpty)
    }

    @Test func theRecordSurvivesARelaunch() throws {
        var alerts = UsageAlerts()
        alerts.markShown(try #require(alerts.warning(for: reading(0.96), at: now)))
        let saved = try JSONEncoder().encode(alerts)
        let restored = try JSONDecoder().decode(UsageAlerts.self, from: saved)
        #expect(restored == alerts)
        #expect(restored.warning(for: reading(0.97), at: now) == nil)
    }
}

private extension UsageAlerts.Alert {
    func with(used: Double) -> Self {
        var copy = self
        copy.used = used
        return copy
    }
}
