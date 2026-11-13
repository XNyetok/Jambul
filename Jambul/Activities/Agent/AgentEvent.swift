import Foundation

/// One thing that happened in a Claude Code session, as its hooks hand it over: the app it runs in on the first line,
/// then the hook's JSON input. Claude Code puts `session_id`, `cwd` and `hook_event_name` before the rest, which can be
/// large after a tool ran, so an input cut short still tells which session did what.
struct AgentEvent: Equatable {
    enum Kind: Equatable {
        case sessionStart
        /// The owner sent a prompt: a turn begins.
        case prompt
        /// A tool is about to run.
        case toolWillRun
        /// Claude Code asks the owner for permission to run a tool.
        case permission
        /// A tool ran, or failed to.
        case toolRan(failed: Bool)
        /// Claude Code notified the owner, like `permission_prompt` or `idle_prompt`.
        case notification(String)
        /// The turn ended.
        case stop
        /// The turn ended on an error, like an API error.
        case stopFailure
        case sessionEnd
    }

    var kind: Kind
    var session: String
    /// The session's folder; its last part names the project.
    var cwd: String?
    /// The bundle identifier of the app Claude Code runs in, like com.apple.Terminal.
    var terminal: String?
    var transcriptPath: String?
    var toolName: String?
    /// Which call of a tool this is about, the same before it runs, as it asks for permission and after it ran.
    var toolUseID: String?
    /// What the tool is doing, as a short line, like "Running the tests" or "Editing IslandView.swift".
    var toolSummary: String?
    /// The file a tool edits or writes.
    var editedFile: String?
    /// The first line of the agent's last reply, for a turn that ended.
    var reply: String?
    /// What went wrong, for a turn that ended on an error.
    var error: String?

    /// The project: the last part of the session's folder.
    var project: String? {
        cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Reads a hook's input: the app on the first line, then the JSON.
    static func parse(_ data: Data) -> AgentEvent? {
        let newline = data.firstIndex(of: 0x0A)
        let terminal = newline.map { String(decoding: data[data.startIndex..<$0], as: UTF8.self) }
        let json = newline.map { data[data.index(after: $0)...] } ?? data[...]
        let app = terminal.flatMap { $0.isEmpty ? nil : $0 }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json))) as? [String: Any] else {
            return parseCutShort(String(decoding: json, as: UTF8.self), terminal: app)
        }
        guard let session = root["session_id"] as? String, !session.isEmpty,
              let name = root["hook_event_name"] as? String,
              let kind = kind(named: name, root: root) else { return nil }
        let toolName = root["tool_name"] as? String
        let input = root["tool_input"] as? [String: Any] ?? [:]
        var event = AgentEvent(kind: kind, session: session, cwd: root["cwd"] as? String, terminal: app,
                               transcriptPath: root["transcript_path"] as? String, toolName: toolName,
                               toolUseID: root["tool_use_id"] as? String)
        if let toolName {
            event.toolSummary = summary(of: toolName, input: input)
            if editingTools.contains(toolName) {
                event.editedFile = (input["file_path"] ?? input["notebook_path"]) as? String
            }
        }
        if kind == .stop { event.reply = (root["last_assistant_message"] as? String).flatMap(firstLine) }
        if kind == .stopFailure { event.error = (root["error"] as? String).flatMap(firstLine) }
        return event
    }

    /// Tools that change a file.
    static let editingTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// The first line with something to say, cleaned for the island: no characters that can't be seen or that turn text
    /// around, no Markdown marks, and no longer than a line can show.
    static func firstLine(_ text: String) -> String? {
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.filter(isShown)))
        for line in visible.split(whereSeparator: \.isNewline) {
            var cleaned = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            cleaned = String(cleaned.drop { "#>*-• \t".contains($0) })
            cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !cleaned.isEmpty else { continue }
            return cleaned.count > 160 ? String(cleaned.prefix(159)) + "…" : cleaned
        }
        return nil
    }

    // MARK: - Private

    private static func kind(named name: String, root: [String: Any]) -> Kind? {
        switch name {
        case "SessionStart": .sessionStart
        case "UserPromptSubmit": .prompt
        case "PreToolUse": .toolWillRun
        case "PermissionRequest": .permission
        case "PostToolUse": .toolRan(failed: false)
        case "PostToolUseFailure": .toolRan(failed: true)
        case "Notification": .notification(root["notification_type"] as? String ?? "")
        case "Stop": .stop
        case "StopFailure": .stopFailure
        case "SessionEnd": .sessionEnd
        default: nil
        }
    }

    /// An input cut short: only what comes first is there.
    private static func parseCutShort(_ text: String, terminal: String?) -> AgentEvent? {
        guard let session = field("session_id", in: text), let name = field("hook_event_name", in: text),
              let kind = kind(named: name, root: [:]) else { return nil }
        return AgentEvent(kind: kind, session: session, cwd: field("cwd", in: text), terminal: terminal,
                          transcriptPath: field("transcript_path", in: text), toolName: field("tool_name", in: text))
    }

    /// A string field near the start of a JSON text, read without parsing it, for an input cut short.
    private static func field(_ name: String, in text: String) -> String? {
        guard let key = text.range(of: "\"\(name)\":\"") else { return nil }
        var value = ""
        var escaped = false
        for character in text[key.upperBound...] {
            if escaped {
                value.append(character == "n" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
        }
        return nil
    }

    /// What a tool is doing, in a few words.
    private static func summary(of tool: String, input: [String: Any]) -> String? {
        let file = (input["file_path"] ?? input["notebook_path"]) as? String
        let fileName = file.map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Bash":
            return ((input["description"] as? String) ?? (input["command"] as? String)).flatMap(firstLine)
        case "Edit", "MultiEdit", "NotebookEdit":
            return fileName.map { String(localized: "Editing \($0)") }
        case "Write":
            return fileName.map { String(localized: "Writing \($0)") }
        case "Read":
            return fileName.map { String(localized: "Reading \($0)") }
        case "Grep", "Glob":
            return String(localized: "Searching")
        case "WebSearch", "WebFetch":
            return String(localized: "Searching the web")
        case "Agent", "Task":
            return (input["description"] as? String).flatMap(firstLine) ?? String(localized: "Running an agent")
        case "AskUserQuestion":
            return String(localized: "Asking you")
        default:
            // An MCP tool, mcp__<server>__<tool>, reads as its server.
            let parts = tool.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" { return String(localized: "Using \(parts[1])") }
            return tool
        }
    }

    /// Whether a character shows: not a control or format character, a line or paragraph separator, or one meant to be
    /// ignored, which can hide or turn text around.
    private static func isShown(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return false
        default: return !scalar.properties.isDefaultIgnorableCodePoint
        }
    }
}
