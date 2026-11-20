import Foundation

/// Adds one named hook group and joins the CLI status line. Only the status line reports an open approval dialog.
struct AntigravitySessionInstaller {
    let hooks: JSONSettingsFile
    let settings: JSONSettingsFile
    let savedURL: URL
    let relay: SessionRelay

    static let group = "jambul-sessions"
    static let events = ["SessionStart", "PreInvocation", "Stop"]

    private struct SavedLine: Codable {
        var original: JSONValue?
        var installed: [String: JSONValue]
    }

    func hasAny() -> Bool {
        let group = (try? hooks.read()[Self.group]) as? [String: Any] ?? [:]
        let statusLine = (try? settings.read()["statusLine"]) as? [String: Any] ?? [:]
        return Self.owns(statusLine) || Self.events.contains { event in
            (group[event] as? [[String: Any]])?.contains(where: Self.owns) == true
        }
    }

    func install() throws {
        let before = try hooks.read()
        let after = try hookSettings(before, enabled: true)
        let addedLine = try installStatusLine()
        do {
            if NSDictionary(dictionary: after) != NSDictionary(dictionary: before) {
                try hooks.write(after, replacing: before)
            }
        } catch {
            if addedLine { try? uninstallStatusLine() }
            throw error
        }
    }

    func uninstall() throws {
        // Try both files even if one couldn't be restored.
        let hookResult = Result { () throws in
            let before = try hooks.read()
            let after = try hookSettings(before, enabled: false)
            if NSDictionary(dictionary: after) != NSDictionary(dictionary: before) {
                try hooks.write(after, replacing: before)
            }
        }
        try uninstallStatusLine()
        try hookResult.get()
    }

    private func hookSettings(_ original: [String: Any], enabled: Bool) throws -> [String: Any] {
        let current = original[Self.group]
        if current == nil, !enabled { return original }
        var group = current as? [String: Any] ?? [:]
        let hasOurHook = Self.events.contains { event in
            (group[event] as? [[String: Any]])?.contains(where: Self.owns) == true
        }
        if current != nil, !hasOurHook {
            if enabled { throw JSONSettingsFile.Failure.unreadableSettings }
            return original
        }
        for event in Self.events {
            let entries = group[event] as? [[String: Any]]
            if entries == nil, group[event] != nil {
                if enabled { throw JSONSettingsFile.Failure.unreadableSettings }
                continue
            }
            var commands = (entries ?? []).filter { !Self.owns($0) }
            if enabled {
                commands.append(["type": "command", "command": relay.hook(provider: .antigravity, event: event),
                                 "timeout": 2])
            }
            group[event] = commands.isEmpty ? nil : commands
        }
        var result = original
        result[Self.group] = group.isEmpty ? nil : group
        return result
    }

    private func installStatusLine() throws -> Bool {
        var current = try settings.read()
        let previousSettings = current
        let oldLine = current["statusLine"]
        let original = oldLine.map(JSONValue.init)
        var fields = oldLine as? [String: Any] ?? [:]
        switch original {
        case nil, .bool, .null, .object: break
        default: throw JSONSettingsFile.Failure.unreadableSettings
        }
        if let command = fields["command"], !(command is String) {
            throw JSONSettingsFile.Failure.unreadableSettings
        }
        if Self.owns(fields) { return false }
        let owner = (fields["enabled"] as? Bool == false) ? nil : fields["command"] as? String
        fields["command"] = relay.statusLine(wrapping: owner)
        fields["type"] = "command"
        fields["enabled"] = true
        if owner == nil { fields["stack_with_default"] = true }
        let saved = SavedLine(original: original, installed: fields.mapValues(JSONValue.init))
        try JSONEncoder().encode(saved).write(to: savedURL, options: .atomic)
        current["statusLine"] = fields
        try settings.write(current, replacing: previousSettings)
        return true
    }

    private func uninstallStatusLine() throws {
        var current = try settings.read()
        let previousSettings = current
        guard let installed = current["statusLine"] as? [String: Any], Self.owns(installed) else {
            try? FileManager.default.removeItem(at: savedURL)
            return
        }
        let saved = try JSONDecoder().decode(SavedLine.self, from: Data(contentsOf: savedURL))
        var restored = installed.mapValues(JSONValue.init)
        guard restored["command"] == saved.installed["command"] else {
            throw JSONSettingsFile.Failure.unreadableSettings
        }
        if restored == saved.installed {
            current["statusLine"] = saved.original?.any
        } else {
            // Keep any edits the user made while Jambul was connected.
            let original = saved.original?.any as? [String: Any] ?? [:]
            for key in ["command", "type", "enabled", "stack_with_default"]
                where restored[key] == saved.installed[key] {
                restored[key] = original[key].map(JSONValue.init)
            }
            current["statusLine"] = restored.mapValues(\.any)
        }
        try settings.write(current, replacing: previousSettings)
        try? FileManager.default.removeItem(at: savedURL)
    }

    private static func owns(_ fields: [String: Any]) -> Bool {
        (fields["command"] as? String)?.hasPrefix(SessionRelay.marker) == true
    }
}
