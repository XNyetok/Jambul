import AppKit
import os
import SwiftUI

/// Keeps the screen on, and with it the Mac awake, until the owner turns it off: for waiting on an agent or a download
/// away from the Mac. Otherwise macOS dims the display, sleeps it and locks the Mac within minutes. Agents in Claude
/// Code already keep the Mac itself awake, but not the screen.
///
/// It holds one power assertion and checks nothing while on. It turns itself off as the battery runs low, and stays on
/// across a relaunch of Jambul, since a build relaunches it, possibly while an agent is still working; but not across a
/// restart of the Mac, nor after the owner quits Jambul.
@MainActor
@Observable
final class KeepAwakeActivity: IslandActivity {
    /// It turns off as the battery falls to one of these on battery, the levels the battery warns at: 20%, or 5% if it
    /// was turned on below 20%.
    static let offLevels = BatteryActivity.lowLevels
    static let offPeekDuration: Duration = .seconds(5)

    let id = "keepAwake"
    var title: String { String(localized: "Keep Awake") }
    var isLive: Bool { since != nil }
    var tint: Color { .cyan }
    var tabSymbol: String { "eye.fill" }
    var homeCardIsQuiet: Bool { !isOn }
    /// The eye, which its card on Home shows too.
    var compactGlyph: String? { "keepAwake.eye" }

    /// When it was turned on; nil while off.
    private(set) var since: Date?
    /// On only until Claude Code's sessions finish their turns, rather than until the owner turns it off.
    private(set) var untilAgentsFinish = false
    /// Whether a Claude Code session is in a turn now, for offering to stay on until it finishes. Read inside views, so
    /// they follow it.
    @ObservationIgnored var agentsAreWorking: @MainActor () -> Bool = { false }
    /// True for the moment the eye takes to close after it is turned off, before it leaves the island.
    private(set) var isClosing = false

    /// On, as far as the owner is concerned: turned on and not yet turned off.
    var isOn: Bool { since != nil && !isClosing }

    /// Whether this is holding the screen on right now.
    var isKeepingScreenOn: Bool { assertion != nil }

    /// The eye on one side and the laptop on the other, however long it has been on.
    var compactSlotWidth: CGFloat { Self.glyphSlotWidth }

    /// Weak, since the center holds its activities.
    @ObservationIgnored private weak var activities: ActivityCenter?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bootSession: String?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let holdsScreen: Bool
    @ObservationIgnored private var assertion: (any NSObjectProtocol)?
    @ObservationIgnored private var lastPower: PowerState?
    @ObservationIgnored private var closeTask: Task<Void, Never>?

    /// - Parameters:
    ///   - defaults: Where it remembers being on, for a relaunch; tests pass their own.
    ///   - bootSession: Tells this run of the Mac from the next, so a restart doesn't bring it back.
    ///   - now: The current time; tests pass their own clock.
    ///   - holdsScreen: Whether it really holds the screen on; previews and most tests turn it off.
    init(activities: ActivityCenter, defaults: UserDefaults = .standard,
         bootSession: String? = KeepAwakeActivity.currentBootSession(),
         now: @escaping @MainActor () -> Date = { .now }, holdsScreen: Bool = true) {
        self.activities = activities
        self.defaults = defaults
        self.bootSession = bootSession
        self.now = now
        self.holdsScreen = holdsScreen
        restore()
    }

    /// - Parameter untilAgentsFinish: Turns off by itself once Claude Code's sessions finish their turns.
    func start(untilAgentsFinish: Bool = false) {
        guard !isOn else { return }
        closeTask?.cancel()
        isClosing = false
        self.untilAgentsFinish = untilAgentsFinish
        defaults.set(untilAgentsFinish, forKey: Self.untilAgentsFinishKey)
        begin(since: now())
        Logger.activities.notice("keep awake on\(untilAgentsFinish ? " until agents finish" : "", privacy: .public)")
    }

    /// Jambul stopped following Claude Code's sessions: it stays on, now until the owner turns it off.
    func stopWaitingForAgents() {
        guard untilAgentsFinish else { return }
        untilAgentsFinish = false
        defaults.removeObject(forKey: Self.untilAgentsFinishKey)
    }

    /// Claude Code's last working session finished its turn: off, if it was on only until then.
    func agentsFinished() {
        guard isOn, untilAgentsFinish else { return }
        Logger.activities.notice("keep awake off, agents finished")
        activities?.peek(Peek(symbol: "eye.slash.fill", tint: tint, title: String(localized: "Keep Awake off"),
                              detail: String(localized: "Claude Code finished"), duration: Self.offPeekDuration,
                              source: id))
        stop()
    }

    /// Turns it on as if it had been on since `date`, for the Debug menu and tests.
    func start(since date: Date) {
        closeTask?.cancel()
        isClosing = false
        untilAgentsFinish = false
        defaults.removeObject(forKey: Self.untilAgentsFinishKey)
        begin(since: date)
    }

    /// Lets the screen sleep again at once. The eye closes, and then it leaves the island.
    func stop() {
        guard isOn else { return }
        holdScreen(false)
        forget()
        isClosing = true
        Logger.activities.notice("keep awake off")
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Motion.eyeClose, tolerance: Motion.timerTolerance)
            guard !Task.isCancelled, let self else { return }
            since = nil
            isClosing = false
        }
    }

    /// Quitting Jambul turns it off for good: unlike a relaunch, nothing brings it back.
    func forgetOnQuit() {
        forget()
    }

    /// Takes a battery reading; nil on a Mac without one. Turns off as the charge falls to a low level on battery.
    func update(_ state: PowerState?) {
        guard let state else { return }
        defer { lastPower = state }
        guard isOn, !state.isOnExternalPower, let last = lastPower,
              Self.offLevels.contains(where: { last.percent > $0 && state.percent <= $0 }) else { return }
        Logger.activities.notice("keep awake off, battery at \(state.percent, privacy: .public)%")
        // In the same turn as the change, as the center asks. It follows the battery's own warning.
        activities?.peek(Peek(symbol: "eye.slash.fill", tint: tint, title: String(localized: "Keep Awake off"),
                              detail: String(localized: "Battery \(state.percent)%"), duration: Self.offPeekDuration,
                              mustBeSeen: true, source: id))
        stop()
    }

    /// What its tab says about it: when it was turned on, and from a minute on, for how long, like "On since 09:41" and
    /// then "On since 09:41 · 1h 05m". Never "0m", which read as nothing worth showing.
    /// On until Claude Code finishes, it says so in place of when, like "Until Claude Code finishes · 12m".
    static func sinceLine(since: Date, at date: Date, untilAgentsFinish: Bool = false,
                          locale: Locale = .autoupdatingCurrent) -> String {
        let seconds = date.timeIntervalSince(since)
        if untilAgentsFinish {
            guard seconds >= 60 else { return String(localized: "Until Claude Code finishes") }
            return String(localized: "Until Claude Code finishes · \(elapsed(seconds))")
        }
        let time = since.formatted(.dateTime.hour().minute().locale(locale))
        guard seconds >= 60 else { return String(localized: "On since \(time)") }
        return String(localized: "On since \(time) · \(elapsed(seconds))")
    }

    /// What its card on Home says: "On" for the first minute, then for how long, like "12m" or "1h 05m". Never "0m".
    static func onFor(since: Date, at date: Date) -> String {
        let seconds = date.timeIntervalSince(since)
        return seconds >= 60 ? elapsed(seconds) : String(localized: "On")
    }

    /// How long it has been on, like "12m" or "1h 05m".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 0)
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h " + String(format: "%02dm", minutes % 60) : "\(minutes)m"
    }

    /// This run of the Mac, which a restart changes.
    nonisolated static func currentBootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private func begin(since date: Date) {
        since = date
        holdScreen(true)
        defaults.set(date, forKey: Self.sinceKey)
        defaults.set(bootSession, forKey: Self.bootSessionKey)
    }

    /// Comes back on after a relaunch in the same run of the Mac, from when it was first turned on.
    private func restore() {
        guard let saved = defaults.object(forKey: Self.sinceKey) as? Date else { return }
        guard let bootSession, defaults.string(forKey: Self.bootSessionKey) == bootSession else {
            forget()
            return
        }
        untilAgentsFinish = defaults.bool(forKey: Self.untilAgentsFinishKey)
        begin(since: saved)
        Logger.activities.notice("keep awake back on after a relaunch")
    }

    private func forget() {
        defaults.removeObject(forKey: Self.sinceKey)
        defaults.removeObject(forKey: Self.bootSessionKey)
        defaults.removeObject(forKey: Self.untilAgentsFinishKey)
    }

    private func holdScreen(_ hold: Bool) {
        if hold, holdsScreen, assertion == nil {
            assertion = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled],
                                                              reason: "Keep Awake is on")
        } else if !hold, let assertion {
            ProcessInfo.processInfo.endActivity(assertion)
            self.assertion = nil
        }
    }

    private static let sinceKey = "keepAwake.since"
    private static let bootSessionKey = "keepAwake.bootSession"
    private static let untilAgentsFinishKey = "keepAwake.untilAgentsFinish"
}
