import Foundation

/// A subscription whose usage limits the island can show.
enum UsageProvider: String, CaseIterable, Codable, Sendable {
    case claude, antigravity, codex

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        case .codex: "Codex"
        }
    }

    /// Codex waits until the owner turns it on.
    var isOnByDefault: Bool { self != .codex }
}

/// One limit of a subscription, such as Claude's five-hour window.
struct UsageWindow: Equatable, Codable, Sendable {
    /// Stable within its provider, like "five_hour" or "gemini-weekly".
    var id: String
    /// How long the window runs, written beside its bar: "5h", "7d", "wk".
    var label: String
    /// How much of it is used, from 0 to 1.
    var used: Double
    /// When it starts over; nil when the provider didn't say.
    var resetsAt: Date?

    /// Whether it has started over since it was read, which empties it.
    func hasReset(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    /// How much is used as of `now`: nothing once it has reset.
    func used(at now: Date) -> Double {
        hasReset(at: now) ? 0 : used
    }
}

/// What a provider last reported.
struct UsageReading: Equatable, Codable, Sendable {
    var provider: UsageProvider
    var windows: [UsageWindow]
    var measuredAt: Date

    /// The window closest to its limit as of `now`: the one that matters.
    func fullest(at now: Date) -> UsageWindow? {
        windows.max { $0.used(at: now) < $1.used(at: now) }
    }
}

/// Reads each provider's own report of its limits. Every reader returns nil for input that carries no limits, so a
/// format change shows as "unavailable" rather than as wrong numbers.
enum UsageParsing {
    /// Claude Code's status line input: `rate_limits.five_hour` and `rate_limits.seven_day`, each with
    /// `used_percentage` (0–100) and `resets_at`. Only subscriptions carry them, and only after a session's first reply.
    static func claudeWindows(fromStatusLine data: Data) -> [UsageWindow]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        let windows = [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, label -> UsageWindow? in
            guard let window = limits[key] as? [String: Any], let percent = number(window["used_percentage"]) else {
                return nil
            }
            return UsageWindow(id: key, label: label, used: clamped(percent / 100), resetsAt: date(window["resets_at"]))
        }
        return windows.isEmpty ? nil : windows
    }

    /// The session and the time its requests have taken so far, from Claude Code's status line input: that time grows
    /// only while Claude Code works, though the status line also comes on a timer.
    static func claudeRequestTime(fromStatusLine data: Data) -> (session: String, milliseconds: Double)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = root["session_id"] as? String,
              let cost = root["cost"] as? [String: Any],
              let milliseconds = number(cost["total_api_duration_ms"]) else { return nil }
        return (session, milliseconds)
    }

    /// The report of `agy -p /usage --output-format json`: `command.data.groups[].buckets[]`, each with `id`, `window`
    /// ("5h" or "weekly"), `remaining_fraction` (0–1) and `reset_time` (ISO 8601).
    static func antigravityWindows(fromReport data: Data) -> [UsageWindow]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "SUCCESS",
              let command = root["command"] as? [String: Any],
              let report = command["data"] as? [String: Any],
              let groups = report["groups"] as? [[String: Any]] else { return nil }
        let windows = groups.flatMap { group in
            (group["buckets"] as? [[String: Any]] ?? []).compactMap { bucket -> UsageWindow? in
                guard let id = bucket["id"] as? String, let remaining = number(bucket["remaining_fraction"]) else {
                    return nil
                }
                let window = bucket["window"] as? String
                return UsageWindow(id: id, label: window == "weekly" ? "wk" : window ?? "", used: clamped(1 - remaining),
                                   resetsAt: date(bucket["reset_time"]))
            }
        }
        return windows.isEmpty ? nil : windows
    }

    /// The last limits a Codex session log recorded: `rate_limits.primary` and `secondary`, each with `used_percent`,
    /// `window_minutes` and `resets_at`. `log` is the end of a log, one JSON event per line. Logs also carry other
    /// limits, like "premium"; only the one named "codex", or one without a name, counts.
    static func codexWindows(fromSessionLog log: String) -> [UsageWindow]? {
        for line in log.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let limits = value(forKey: "rate_limits", in: event) as? [String: Any] else { continue }
            if let name = limits["limit_id"] as? String, name != "codex" { continue }
            let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
                guard let window = limits[key] as? [String: Any], let percent = number(window["used_percent"]) else {
                    return nil
                }
                let label = number(window["window_minutes"]).map { label(forMinutes: Int($0)) } ?? ""
                return UsageWindow(id: key, label: label, used: clamped(percent / 100), resetsAt: date(window["resets_at"]))
            }
            if !windows.isEmpty { return windows }
        }
        return nil
    }

    /// A window's length as written beside its bar: "5h", "wk", "30d".
    static func label(forMinutes minutes: Int) -> String {
        if minutes == 7 * 24 * 60 { return "wk" }
        if minutes > 0, minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
        if minutes > 0, minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// A number from JSON; never a Boolean, which JSONSerialization also hands back as an NSNumber.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// Unix seconds, or an ISO 8601 date with or without fractions of a second.
    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) { return Date(timeIntervalSince1970: seconds) }
        guard let text = value as? String else { return nil }
        return (try? Date(text, strategy: .iso8601))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
    }

    private static func clamped(_ fraction: Double) -> Double {
        min(max(fraction, 0), 1)
    }

    /// The first value under `key`, however deep: Codex nests its limits inside the event's payload.
    private static func value(forKey key: String, in object: Any) -> Any? {
        if let dictionary = object as? [String: Any] {
            if let found = dictionary[key] { return found }
            for child in dictionary.values {
                if let found = value(forKey: key, in: child) { return found }
            }
        } else if let array = object as? [Any] {
            for child in array {
                if let found = value(forKey: key, in: child) { return found }
            }
        }
        return nil
    }
}
