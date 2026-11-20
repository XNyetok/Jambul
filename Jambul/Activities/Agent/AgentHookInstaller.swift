import Foundation
import os

/// Manages Jambul's hooks in Claude Code and Codex, whose settings use the same event and matcher groups.
///
/// Each hook is a short shell line: it reads the hook's input, hands it to Jambul's socket with macOS's own `nc` in the
/// background, after the app Claude Code runs in, and returns at once, so Claude Code never waits on Jambul (about 10 ms
/// per hook, measured). Nothing in it names where Jambul is, so moving or deleting Jambul breaks nothing: `nc` then
/// fails without a word. Jambul knows its own hooks by `marker`, and leaves every other hook as it is.
struct AgentHookInstaller {
    let settingsURL: URL
    let socketPath: String
    var codexRelay: SessionRelay?

    /// Starts every hook Jambul writes, so it knows its own.
    static let marker = "JAMBUL_AGENT=1"

    /// The hooks Jambul listens to.
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                         "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd"]
    static let codexEvents = ["SessionStart", "UserPromptSubmit", "PreModelRequest", "Stop", "Interrupt", "SessionEnd"]

    /// Seconds Claude Code gives a hook. Jambul's return at once; this only bounds a shell that hangs.
    static let timeout = 5

    private var settingsFile: JSONSettingsFile { JSONSettingsFile(url: settingsURL) }
    private var marker: String { codexRelay == nil ? Self.marker : SessionRelay.marker }

    /// Whether every hook of Jambul's is in place as it should be.
    func isInstalled() -> Bool {
        guard let settings = try? settingsFile.read() else { return false }
        return Self.hooks(settings) == withJambuls(withoutJambuls(Self.hooks(settings)))
    }

    /// Whether any hook of Jambul's is there, current or not.
    func hasAny() -> Bool {
        guard let settings = try? settingsFile.read() else { return false }
        return withoutJambuls(Self.hooks(settings)) != Self.hooks(settings)
    }

    /// Puts Jambul's hooks in place, replacing older ones of Jambul's. Writes nothing when they're already right.
    func install() throws {
        var settings = try settingsFile.read()
        let original = settings
        let before = Self.hooks(settings)
        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else {
            throw JSONSettingsFile.Failure.unreadableSettings
        }
        if codexRelay != nil, case .object(let events) = before {
            for event in Self.codexEvents {
                guard let value = events[event] else { continue }
                guard case .array = value else { throw JSONSettingsFile.Failure.unreadableSettings }
            }
        }
        let after = withJambuls(withoutJambuls(before))
        guard after != before else { return }
        settings["hooks"] = after.any
        try settingsFile.write(settings, replacing: original)
        Logger.activities.notice("agent: connected \(codexRelay == nil ? "Claude Code" : "Codex", privacy: .public) hooks")
    }

    /// Takes Jambul's hooks out, and nothing else.
    func uninstall() throws {
        var settings = try settingsFile.read()
        let original = settings
        let before = Self.hooks(settings)
        let after = withoutJambuls(before)
        guard after != before else { return }
        if case .object(let events) = after, events.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = after.any
        }
        try settingsFile.write(settings, replacing: original)
        Logger.activities.notice("agent: disconnected \(codexRelay == nil ? "Claude Code" : "Codex", privacy: .public) hooks")
    }

    /// The hook that hands its input to Jambul: the app Claude Code runs in on the first line, which macOS passes on to
    /// what runs inside it, then the input.
    static func command(socketPath: String) -> String {
        let quotedSocket = "'" + socketPath.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return #"\#(marker); IN=$(cat); { printf '%s\n%s' "${__CFBundleIdentifier:-}" "$IN" | "#
            + #"/usr/bin/nc -U -w 1 \#(quotedSocket) >/dev/null 2>&1 & }"#
    }

    // MARK: - Private

    private static func hooks(_ settings: [String: Any]) -> JSONValue {
        settings["hooks"].map(JSONValue.init) ?? .object([:])
    }

    /// The hooks without any of Jambul's: its entries go, then any group or event they leave empty.
    private func withoutJambuls(_ hooks: JSONValue) -> JSONValue {
        guard case .object(let events) = hooks else { return hooks }
        var kept: [String: JSONValue] = [:]
        for (event, groups) in events {
            guard case .array(let groupList) = groups else {
                kept[event] = groups
                continue
            }
            let remaining = groupList.compactMap { group -> JSONValue? in
                guard case .object(var fields) = group, case .array(let entries)? = fields["hooks"] else { return group }
                let others = entries.filter { !isJambuls($0) }
                guard others.count != entries.count else { return group }
                if others.isEmpty { return nil }
                fields["hooks"] = .array(others)
                return .object(fields)
            }
            if !remaining.isEmpty || groupList.isEmpty { kept[event] = .array(remaining) }
        }
        return .object(kept)
    }

    /// The hooks with one group of Jambul's added to each event it listens to, after the owner's.
    private func withJambuls(_ hooks: JSONValue) -> JSONValue {
        guard case .object(var events) = hooks else { return hooks }
        for event in codexRelay == nil ? Self.events : Self.codexEvents {
            let command = codexRelay?.hook(provider: .codex, event: event) ?? Self.command(socketPath: socketPath)
            let entry = JSONValue.object(["type": .string("command"), "command": .string(command),
                                          "timeout": .number(codexRelay == nil ? Double(Self.timeout) : 2)])
            let group = JSONValue.object(["hooks": .array([entry])])
            switch events[event] {
            case .array(let groups)?: events[event] = .array(groups + [group])
            case nil: events[event] = .array([group])
            // Not a list, which Claude Code wouldn't read either: the owner's to fix, so it stays as it is.
            default: break
            }
        }
        return .object(events)
    }

    private func isJambuls(_ entry: JSONValue) -> Bool {
        guard case .object(let fields) = entry, case .string(let command)? = fields["command"] else { return false }
        return command.hasPrefix(marker)
    }
}
