import Foundation
import os

/// Connects Claude Code's status line to Jambul, and disconnects it.
///
/// Connected, the status line is a short shell line: it reads Claude Code's input once, hands a copy to Jambul's socket
/// with macOS's own `nc` in the background, and runs the owner's status line with the same input, newline and all. The
/// status line looks as it did, and nothing in it names where Jambul is, so moving or deleting Jambul breaks nothing:
/// `nc` then fails without a word.
///
/// Disconnecting puts the owner's status line back exactly as it was. If it changed in the meantime, or the copy Jambul
/// kept is gone, the owner's line is taken back out of Jambul's; a line Jambul can't read back stays, since it does no
/// harm.
struct ClaudeStatusLineInstaller {
    /// Claude Code's settings, ~/.claude/settings.json. A symbolic link is followed, so a dotfiles setup keeps working.
    let settingsURL: URL
    /// Where the owner's own status line waits while Jambul's is in place.
    let savedURL: URL
    let socketPath: String

    /// Starts every status line Jambul writes, so it knows its own.
    static let marker = "JAMBUL_USAGE=1"
    /// What runs the owner's status line inside Jambul's; the older form, without the newline, came first.
    private static let openers = [#"printf '%s\n' "$IN" | ( "#, #"printf '%s' "$IN" | ( "#]

    enum Failure: Error, Equatable {
        /// The settings aren't JSON Jambul can read, so it leaves them alone.
        case unreadableSettings
    }

    /// The owner's status line as it was before Jambul's: whether there was one, and its value.
    private struct Saved: Codable {
        var had: Bool
        var value: JSONValue?
    }

    /// The file to read and write: the settings, or what their link points to.
    private var file: URL { settingsURL.resolvingSymlinksInPath() }

    /// Whether Jambul's status line is in place.
    func isInstalled() -> Bool {
        guard let settings = try? readSettings() else { return false }
        return Self.isJambuls(settings["statusLine"])
    }

    /// Puts Jambul's status line in place, or brings an older one of Jambul's up to date. Writes nothing when it's
    /// already right.
    func install() throws {
        var settings = try readSettings()
        let current = settings["statusLine"] as? [String: Any]
        let owners: [String: Any]?
        if let current, Self.isJambuls(current) {
            // The owner's line is the one inside, which reflects any change made since.
            guard let inside = Self.original(in: current["command"] as? String ?? "") else { return }
            owners = inside.map { current.merging(["command": $0]) { $1 } }
            if (try? loadSaved()) == nil {
                try save(Saved(had: owners != nil, value: owners.map(JSONValue.init)))
            }
        } else {
            owners = current
            try save(Saved(had: settings["statusLine"] != nil, value: settings["statusLine"].map(JSONValue.init)))
        }
        var statusLine = owners ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = Self.command(socketPath: socketPath, wrapping: owners?["command"] as? String)
        if let current, NSDictionary(dictionary: current) == NSDictionary(dictionary: statusLine) { return }
        settings["statusLine"] = statusLine
        try write(settings)
        Logger.activities.notice("usage: connected Claude Code's status line")
    }

    func uninstall() throws {
        var settings = try readSettings()
        defer { try? FileManager.default.removeItem(at: savedURL) }
        guard let current = settings["statusLine"] as? [String: Any], Self.isJambuls(current) else { return }
        let command = current["command"] as? String ?? ""
        let saved = try? loadSaved()
        let savedCommand = (saved?.value?.any as? [String: Any])?["command"] as? String
        if let saved, command == Self.command(socketPath: socketPath, wrapping: savedCommand) {
            // Untouched since: back exactly as it was.
            if saved.had, let value = saved.value {
                settings["statusLine"] = value.any
            } else {
                settings.removeValue(forKey: "statusLine")
            }
        } else if let inside = Self.original(in: command) {
            if let inside {
                settings["statusLine"] = current.merging(["command": inside]) { $1 }
            } else {
                settings.removeValue(forKey: "statusLine")
            }
        } else {
            Logger.activities.notice("usage: left a status line Jambul can't read back")
            return
        }
        try write(settings)
        Logger.activities.notice("usage: disconnected Claude Code's status line")
    }

    /// The status line that hands Claude Code's input to Jambul and then runs `original`, in a subshell so all of it
    /// reads the same input. The newline goes back on, since `$(cat)` drops it and a script reading a line needs it.
    static func command(socketPath: String, wrapping original: String?) -> String {
        let quotedSocket = "'" + socketPath.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        let handOver = #"{ printf '%s' "$IN" | /usr/bin/nc -U -w 1 \#(quotedSocket) >/dev/null 2>&1 & }"#
        var command = #"\#(marker); IN=$(cat); \#(handOver)"#
        if let original, !original.isEmpty {
            command += "; " + openers[0] + original + "\n)"
        }
        return command
    }

    /// The owner's status line inside one of Jambul's: `.some(nil)` when Jambul's ran nothing after handing over, and
    /// nil when the line isn't one Jambul can read back.
    static func original(in command: String) -> String?? {
        guard command.hasPrefix(marker), command.contains("IN=$(cat)") else { return nil }
        for opener in openers {
            if let range = command.range(of: opener) {
                let rest = command[range.upperBound...]
                guard rest.hasSuffix("\n)") else { return nil }
                return .some(String(rest.dropLast(2)))
            }
        }
        return .some(nil)
    }

    private static func isJambuls(_ statusLine: Any?) -> Bool {
        ((statusLine as? [String: Any])?["command"] as? String)?.hasPrefix(marker) ?? false
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.unreadableSettings
        }
        return settings
    }

    /// Writes the settings in one step, after keeping the first version Jambul ever changed. Settings Jambul created
    /// and emptied again are removed rather than left behind as `{}`.
    private func write(_ settings: [String: Any]) throws {
        let fileManager = FileManager.default
        let backup = settingsURL.appendingPathExtension("jambul-backup")
        let existed = fileManager.fileExists(atPath: file.path)
        if settings.isEmpty, !fileManager.fileExists(atPath: backup.path) {
            if existed { try fileManager.removeItem(at: file) }
            return
        }
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if existed, !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: file, to: backup)
        }
        var data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: file, options: .atomic)
    }

    private func save(_ saved: Saved) throws {
        try FileManager.default.createDirectory(at: savedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: savedURL, options: .atomic)
    }

    private func loadSaved() throws -> Saved {
        try JSONDecoder().decode(Saved.self, from: Data(contentsOf: savedURL))
    }
}

/// Any JSON value, so the owner's status line can be kept and put back as it was.
enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(_ any: Any) {
        switch any {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init))
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
        case .string(let value): value
        case .array(let values): values.map(\.any)
        case .object(let values): values.mapValues(\.any)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
}
