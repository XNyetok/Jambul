import Foundation

/// Decides which peeks the usage limits earn: 80% and 95% once per window, "out" once a window is used up, and "back"
/// once a window that reached 95% starts over.
///
/// A window is told apart from the next one by its reset time. A provider can move that time a little between
/// readings, so times within `sameWindowTolerance` of each other count as the same window.
struct UsageAlerts: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Comparable, Sendable {
        case warning80, warning95, out, back

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rank < rhs.rank }

        private var rank: Int {
            switch self {
            case .back: 0
            case .warning80: 1
            case .warning95: 2
            case .out: 3
            }
        }
    }

    struct Alert: Equatable, Sendable {
        var provider: UsageProvider
        var windowID: String
        var label: String
        var used: Double
        var resetsAt: Date?
        var kind: Kind
    }

    /// What one window has shown so far.
    struct WindowRecord: Codable, Equatable, Sendable {
        var resetsAt: Date?
        var shown: Set<Kind>
    }

    /// The warnings, most serious first.
    static let warningLevels: [(fraction: Double, kind: Kind)] = [(1, .out), (0.95, .warning95), (0.8, .warning80)]
    /// Two readings of a window whose reset times are this close describe the same window. Windows of the same kind
    /// are at least five hours apart.
    static let sameWindowTolerance: TimeInterval = 30 * 60
    /// How long a window is remembered after it started over.
    static let memory: TimeInterval = 8 * 24 * 60 * 60

    /// What each window has shown, keyed by "provider.window".
    private(set) var records: [String: WindowRecord] = [:]

    /// The warning a reading earns, if any: the most serious one, since a single peek says it all.
    func warning(for reading: UsageReading, at now: Date) -> Alert? {
        var best: Alert?
        for window in reading.windows where !window.hasReset(at: now) {
            guard let level = Self.warningLevels.first(where: { window.used >= $0.fraction }) else { continue }
            let shown = shown(reading.provider, window)
            // A level shown already, or a higher one, says this one too.
            guard !shown.contains(where: { $0 != .back && $0 >= level.kind }) else { continue }
            let alert = Alert(provider: reading.provider, windowID: window.id, label: window.label, used: window.used,
                              resetsAt: window.resetsAt, kind: level.kind)
            if best.map({ alert.kind > $0.kind }) ?? true { best = alert }
        }
        return best
    }

    /// "Back" for each window that reached 95% and has started over since, once.
    func backAlerts(at now: Date) -> [Alert] {
        records.sorted { $0.key < $1.key }.compactMap { key, record -> Alert? in
            guard let resetsAt = record.resetsAt, resetsAt <= now, !record.shown.contains(.back),
                  record.shown.contains(.warning95) || record.shown.contains(.out),
                  let (provider, windowID) = Self.split(key) else { return nil }
            return Alert(provider: provider, windowID: windowID, label: "", used: 0, resetsAt: resetsAt, kind: .back)
        }
    }

    /// Records an alert once its peek has shown, along with the lower levels it says.
    mutating func markShown(_ alert: Alert) {
        let key = Self.key(alert.provider, alert.windowID)
        var record = records[key].flatMap { Self.isSameWindow($0.resetsAt, alert.resetsAt) ? $0 : nil }
            ?? WindowRecord(resetsAt: alert.resetsAt, shown: [])
        record.shown.insert(alert.kind)
        if alert.kind != .back {
            record.shown.formUnion(Self.warningLevels.map(\.kind).filter { $0 < alert.kind })
        }
        records[key] = record
    }

    /// Forgets windows that started over long ago.
    mutating func forgetOld(at now: Date) {
        records = records.filter { _, record in
            record.resetsAt.map { now.timeIntervalSince($0) < Self.memory } ?? true
        }
    }

    private func shown(_ provider: UsageProvider, _ window: UsageWindow) -> Set<Kind> {
        guard let record = records[Self.key(provider, window.id)],
              Self.isSameWindow(record.resetsAt, window.resetsAt) else { return [] }
        return record.shown
    }

    static func isSameWindow(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): abs(lhs.timeIntervalSince(rhs)) <= sameWindowTolerance
        default: false
        }
    }

    private static func key(_ provider: UsageProvider, _ windowID: String) -> String {
        "\(provider.rawValue).\(windowID)"
    }

    private static func split(_ key: String) -> (UsageProvider, String)? {
        guard let dot = key.firstIndex(of: "."), let provider = UsageProvider(rawValue: String(key[..<dot])) else {
            return nil
        }
        return (provider, String(key[key.index(after: dot)...]))
    }
}
