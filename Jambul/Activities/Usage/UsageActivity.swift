import os
import SwiftUI

/// The usage limits of the owner's AI subscriptions: a tab with each one, peeks at 80% and 95%, and a place beside the
/// notch from 95% until the limit starts over.
///
/// It only holds what the sources hand it and the time each limit starts over; nothing here runs on a timer, except a
/// single wait for the next limit to start over.
@MainActor
@Observable
final class UsageActivity: IslandActivity {
    /// Beside the notch from here.
    static let liveFrom = 0.95
    static let warningPeekDuration: Duration = .seconds(3)
    /// The must-see ones, as long as a low battery's.
    static let urgentPeekDuration = BatteryActivity.lowPeekDuration
    /// Claude Code updates its status line while it works; this long without one, it has stopped.
    static let claudeWorkingFor: TimeInterval = 20

    let id = "usage"
    var title: String { String(localized: "Usage") }
    var tint: Color { .purple }
    var tabSymbol: String { "gauge.with.dots.needle.33percent" }
    var priority: ActivityPriority { .low }

    /// The subscriptions the owner turned on, in the order the tab shows them.
    var enabled: [UsageProvider] = [] {
        didSet { scheduleNextReset() }
    }
    /// Subscriptions turned on that still wait to be connected in Settings.
    var needsConnecting: Set<UsageProvider> = []
    /// Each subscription's last reading.
    private(set) var readings: [UsageProvider: UsageReading] = [:]
    /// Why a subscription has no numbers to show.
    private(set) var problems: [UsageProvider: String] = [:]
    /// When Claude Code last spent time on a request, which is when it's working.
    private(set) var claudeWorkingAt: Date?
    /// The time each Claude Code session's requests have taken so far.
    @ObservationIgnored private var claudeRequestTime: [String: Double] = [:]
    /// Moves on each time a limit starts over, so what depends on the clock is worked out again.
    private var resetCount = 0

    /// Called as the tab opens, to ask for numbers that are old.
    @ObservationIgnored var onTabAppear: (@MainActor () -> Void)?
    /// Called from a subscription's "Connect" button.
    @ObservationIgnored var onConnect: (@MainActor (UsageProvider) -> Void)?
    /// Weak, since the center holds its activities.
    @ObservationIgnored private weak var activities: ActivityCenter?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var alerts = UsageAlerts()
    /// Alerts whose peeks wait for the island, by peek: one is only recorded once it has shown.
    @ObservationIgnored private var waitingAlerts: [Peek.ID: UsageAlerts.Alert] = [:]
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    private static let readingsKey = "usageReadings"
    private static let alertsKey = "usageAlerts"

    /// - Parameters:
    ///   - defaults: Where the last numbers and the warnings already shown are kept for the next launch; nil keeps
    ///     them in memory, as tests and previews do.
    ///   - now: The current time; tests pass their own clock.
    init(activities: ActivityCenter, defaults: UserDefaults? = nil, now: @escaping @MainActor () -> Date = { .now }) {
        self.activities = activities
        self.defaults = defaults
        self.now = now
        if let data = defaults?.data(forKey: Self.readingsKey),
           let saved = try? JSONDecoder().decode([UsageReading].self, from: data) {
            readings = Dictionary(saved.map { ($0.provider, $0) }, uniquingKeysWith: { $1 })
        }
        if let data = defaults?.data(forKey: Self.alertsKey),
           let saved = try? JSONDecoder().decode(UsageAlerts.self, from: data) {
            alerts = saved
        }
    }

    var isLive: Bool { pressing != nil }

    /// The subscription and window nearest their limit, once at 95% or past it.
    var pressing: (provider: UsageProvider, window: UsageWindow)? {
        _ = resetCount
        let now = now()
        return enabled.compactMap { provider in readings[provider]?.fullest(at: now).map { (provider, $0) } }
            .filter { $0.1.used(at: now) >= Self.liveFrom }
            .max { $0.1.used(at: now) < $1.1.used(at: now) }
    }

    /// Whether Claude Code is working now, as far as its status line tells.
    var isClaudeWorking: Bool {
        claudeWorkingAt.map { now().timeIntervalSince($0) < Self.claudeWorkingFor } ?? false
    }

    /// Claude Code's status line also comes on a timer, so only a session's request time growing means it's working.
    func noteClaudeRequestTime(_ milliseconds: Double, session: String) {
        defer { claudeRequestTime[session] = milliseconds }
        guard let before = claudeRequestTime[session], milliseconds > before else { return }
        claudeWorkingAt = now()
    }

    /// The time, for views: they read it after a reset moves `resetCount` on.
    var currentDate: Date {
        _ = resetCount
        return now()
    }

    func record(_ newReading: UsageReading) {
        let reading = Self.keepingHigher(newReading, than: readings[newReading.provider])
        if problems[reading.provider] != nil { problems[reading.provider] = nil }
        // Claude Code updates its status line many times a minute while it works, mostly with the same numbers; those
        // change nothing, so nothing is saved and nothing redraws.
        guard readings[reading.provider]?.windows != reading.windows else { return }
        readings[reading.provider] = reading
        save()
        Logger.activities.notice("""
            usage: \(reading.provider.rawValue, privacy: .public) \
            \(reading.windows.map { "\($0.label) \(Int(($0.used * 100).rounded()))%" }.joined(separator: ", "), privacy: .public)
            """)
        if enabled.contains(reading.provider) {
            if let warning = alerts.warning(for: reading, at: now()) {
                post(warning)
            } else {
                announceBacks()
            }
        }
        scheduleNextReset()
    }

    /// Within one window, usage only grows until it starts over. Each Claude Code session reports the limits it last
    /// heard, so two can disagree by a point and the number would flicker between them; the higher one stands.
    static func keepingHigher(_ reading: UsageReading, than previous: UsageReading?) -> UsageReading {
        guard let previous else { return reading }
        var kept = reading
        kept.windows = reading.windows.map { window in
            // Without a reset time there's no telling one window from the next, so the new number stands.
            guard let old = previous.windows.first(where: { $0.id == window.id }),
                  old.resetsAt != nil, window.resetsAt != nil,
                  UsageAlerts.isSameWindow(old.resetsAt, window.resetsAt), old.used > window.used else { return window }
            var higher = window
            higher.used = old.used
            return higher
        }
        return kept
    }

    func markProblem(_ provider: UsageProvider, _ problem: String) {
        guard problems[provider] != problem else { return }
        problems[provider] = problem
        Logger.activities.notice("usage: \(provider.rawValue, privacy: .public): \(problem, privacy: .public)")
    }

    /// The island started showing a peek: if it carried one of these alerts, the alert has been said.
    func peekWasShown(_ peek: Peek) {
        guard let alert = waitingAlerts.removeValue(forKey: peek.id) else { return }
        alerts.markShown(alert)
        alerts.forgetOld(at: now())
        saveAlerts()
    }

    /// Looks for limits that started over: when the next one is due, and after the Mac wakes.
    func checkResets() {
        resetCount += 1
        announceBacks()
        scheduleNextReset()
    }

    func tabDidAppear() {
        onTabAppear?()
    }

    // MARK: - Peeks

    private func announceBacks() {
        for back in alerts.backAlerts(at: now()) where enabled.contains(back.provider) {
            post(back)
        }
    }

    private func post(_ alert: UsageAlerts.Alert) {
        let peek = Self.peek(for: alert, now: now())
        // A newer alert from the same subscription replaces one still waiting, as its peek replaces the other's.
        waitingAlerts = waitingAlerts.filter { $0.value.provider != alert.provider }
        waitingAlerts[peek.id] = alert
        Logger.activities.notice("""
            usage: \(alert.provider.rawValue, privacy: .public) \(alert.kind.rawValue, privacy: .public)
            """)
        activities?.peek(peek)
    }

    static func peek(for alert: UsageAlerts.Alert, now: Date) -> Peek {
        let name = alert.provider.displayName
        let percent = percentText(alert.used)
        let source = "usage.\(alert.provider.rawValue)"
        let resets = alert.resetsAt.map { resetText($0, now: now) }
        switch alert.kind {
        case .warning80:
            return Peek(symbol: "gauge.with.dots.needle.67percent", tint: .yellow, title: "\(name) \(percent)",
                        detail: resets, duration: warningPeekDuration, source: source,
                        logo: alert.provider.logoAsset, progress: alert.used, emphasis: percent, motion: .spin)
        case .warning95:
            return Peek(symbol: "gauge.with.dots.needle.100percent", tint: .red, title: "\(name) \(percent)",
                        detail: resets, duration: urgentPeekDuration, mustBeSeen: true, source: source,
                        logo: alert.provider.logoAsset, progress: alert.used, emphasis: percent, motion: .pulse)
        case .out:
            let back = alert.resetsAt.map { backText($0, now: now) }
            return Peek(symbol: "gauge.with.dots.needle.100percent", tint: .red,
                        title: String(localized: "\(name) is out"), detail: back, duration: urgentPeekDuration,
                        mustBeSeen: true, source: source, logo: alert.provider.logoAsset, progress: 1, motion: .sleep)
        case .back:
            return Peek(symbol: "gauge.with.dots.needle.0percent", tint: alert.provider.brandColor,
                        title: String(localized: "\(name) is back"), detail: String(localized: "limit reset"),
                        duration: warningPeekDuration, source: source, logo: alert.provider.logoAsset, progress: 0,
                        motion: .bounce)
        }
    }

    /// When a limit starts over: the time today, the weekday within a week, else the date.
    static func resetText(_ date: Date, now: Date) -> String {
        String(localized: "resets \(when(date, now: now).text)")
    }

    /// When a limit that ran out comes back, in the same words.
    static func backText(_ date: Date, now: Date) -> String {
        let when = when(date, now: now)
        return when.isToday ? String(localized: "back at \(when.text)") : String(localized: "back \(when.text)")
    }

    private static func when(_ date: Date, now: Date) -> (text: String, isToday: Bool) {
        if Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: now) {
            return (date.formatted(.dateTime.hour().minute()), true)
        }
        if date.timeIntervalSince(now) < 6 * 24 * 3_600 {
            return (date.formatted(.dateTime.weekday(.abbreviated)), false)
        }
        return (date.formatted(.dateTime.day().month(.abbreviated)), false)
    }

    /// A percentage, rounded down so it never reads 100% before the limit has run out.
    static func percentText(_ used: Double) -> String {
        ((used * 100).rounded(.down) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: - Keeping track

    /// Waits for the next limit to start over; one wait at a time.
    private func scheduleNextReset() {
        resetTask?.cancel()
        let now = now()
        let next = readings.values.filter { enabled.contains($0.provider) }
            .flatMap(\.windows).compactMap(\.resetsAt).filter { $0 > now }.min()
        guard let next else { return }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 1), tolerance: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.checkResets()
        }
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(Array(readings.values)) else { return }
        defaults.set(data, forKey: Self.readingsKey)
    }

    private func saveAlerts() {
        guard let defaults, let data = try? JSONEncoder().encode(alerts) else { return }
        defaults.set(data, forKey: Self.alertsKey)
    }
}

extension UsageProvider {
    /// The provider's own logo, in the app's assets.
    var logoAsset: String {
        switch self {
        case .claude: "ClaudeLogo"
        case .antigravity: "AntigravityLogo"
        case .codex: "OpenAILogo"
        }
    }

    /// Its bars' color while there is room: the color of its logo.
    var brandColor: Color {
        switch self {
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341)
        case .antigravity: Color(red: 0.298, green: 0.545, blue: 0.961)
        case .codex: .white
        }
    }
}
