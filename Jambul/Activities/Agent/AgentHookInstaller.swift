import Foundation
import os

/// Adds Jambul's hooks to Claude Code's settings, and takes them out again.
///
/// Each hook is a short shell line: it reads the hook's input, hands it to Jambul's socket with macOS's own `nc` in the
/// background, after the app Claude Code runs in, and returns at once, so Claude Code never waits on Jambul (about 10 ms
/// per hook, measured). Nothing in it names where Jambul is, so moving or deleting Jambul breaks nothing: `nc` then
/// fails without a word. Jambul knows its own hooks by `marker`, and leaves every other hook as it is.
struct AgentHookInstaller {
    let settingsURL: URL
    let socketPath: String

    /// Starts every hook Jambul writes, so it knows its own.
    static let marker = "JAMBUL_AGENT=1"

    /// The hooks Jambul listens to.
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                         "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd"]

    /// Seconds Claude Code gives a hook. Jambul's return at once; this only bounds a shell that hangs.
    static let timeout = 5

    private var settingsFile: ClaudeSettingsFile { ClaudeSettingsFile(url: settingsURL) }

    /// Whether every hook of Jambul's is in place as it should be.
    func isInstalled() -> Bool {
        guard let settings = try? settingsFile.read() else { return false }
        return Self.hooks(settings) == Self.withJambuls(Self.withoutJambuls(Self.hooks(settings)), socketPath: socketPath)
    }

    /// Whether any hook of Jambul's is there, current or not.
    func hasAny() -> Bool {
        guard let settings = try? settingsFile.read() else { return false }
        return Self.withoutJambuls(Self.hooks(settings)) != Self.hooks(settings)
    }

    /// Puts Jambul's hooks in place, replacing older ones of Jambul's. Writes nothing when they're already right.
    func install() throws {
        var settings = try settingsFile.read()
        let before = Self.hooks(settings)
        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else {
            throw ClaudeSettingsFile.Failure.unreadableSettings
        }
        let after = Self.withJambuls(Self.withoutJambuls(before), socketPath: socketPath)
        guard after != before else { return }
        settings["hooks"] = after.any
        try settingsFile.write(settings)
        Logger.activities.notice("agent: connected Claude Code's hooks")
    }

    /// Takes Jambul's hooks out, and nothing else.
    func uninstall() throws {
        var settings = try settingsFile.read()
        let before = Self.hooks(settings)
        let after = Self.withoutJambuls(before)
        guard after != before else { return }
        if case .object(let events) = after, events.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = after.any
        }
        try settingsFile.write(settings)
        Logger.activities.notice("agent: disconnected Claude Code's hooks")
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
    private static func withoutJambuls(_ hooks: JSONValue) -> JSONValue {
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
    private static func withJambuls(_ hooks: JSONValue, socketPath: String) -> JSONValue {
        guard case .object(var events) = hooks else { return hooks }
        let entry = JSONValue.object(["type": .string("command"), "command": .string(command(socketPath: socketPath)),
                                      "timeout": .number(Double(timeout))])
        let group = JSONValue.object(["hooks": .array([entry])])
        for event in Self.events {
            switch events[event] {
            case .array(let groups)?: events[event] = .array(groups + [group])
            case nil: events[event] = .array([group])
            // Not a list, which Claude Code wouldn't read either: the owner's to fix, so it stays as it is.
            default: break
            }
        }
        return .object(events)
    }

    private static func isJambuls(_ entry: JSONValue) -> Bool {
        guard case .object(let fields) = entry, case .string(let command)? = fields["command"] else { return false }
        return command.hasPrefix(marker)
    }
}
