import Foundation

extension UsageProvider {
    static let sessionProviders: [Self] = [.claude, .codex, .antigravity]

    var sessionName: String {
        self == .claude ? String(localized: "Claude Code") : displayName
    }
}

/// Only session metadata crosses the socket for Codex and Antigravity. Their hook inputs can also contain prompts,
/// replies, tool arguments and account information, which the relay discards.
struct AgentSessionUpdate: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case opened, prompted, working, approval, question, idle
        case finishing, done, failed, interrupted, closed, unavailable

        var endsTurn: Bool { self == .done || self == .failed || self == .interrupted }
    }

    let provider: UsageProvider
    let session: String
    let kind: Kind
    var turn: String?
    var project: String?
    var terminal: String?
    var transcriptPath: String?
    var isSnapshot = false
    var date = Date.now

    /// Separates the two new wire formats from Claude's raw JSON, including when Claude has no terminal bundle id.
    static let socketHeader = Data("JambulSession/1\n".utf8)

    var socketData: Data? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return Self.socketHeader + data
    }

    static func fromSocket(_ data: Data) -> Self? {
        guard data.starts(with: socketHeader),
              let update = try? JSONDecoder().decode(Self.self, from: data.dropFirst(socketHeader.count)),
              update.provider != .claude, !update.session.isEmpty, update.session.utf8.count <= 128 else { return nil }
        return update
    }

    static func fromCLI(_ data: Data, provider: UsageProvider, event: String,
                        terminal: String?, date: Date) -> Self? {
        guard let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch provider {
        case .claude:
            return nil
        case .codex:
            guard let id = input["session_id"] as? String, !id.isEmpty,
                  input["hook_event_name"] as? String == event else { return nil }
            let kind: Kind
            switch event {
            case "SessionStart": kind = .opened
            case "UserPromptSubmit": kind = .prompted
            case "PreModelRequest": kind = .working
            case "Interrupt": kind = .interrupted
            case "Stop": kind = .finishing
            case "SessionEnd": kind = .closed
            default: return nil
            }
            return Self(provider: provider, session: id, kind: kind, turn: input["turn_id"] as? String,
                        project: project(input["cwd"] as? String), terminal: terminal,
                        transcriptPath: input["transcript_path"] as? String, date: date)
        case .antigravity:
            return fromAntigravity(input, event: event, terminal: terminal, date: date)
        }
    }

    private static func fromAntigravity(_ input: [String: Any], event: String,
                                         terminal: String?, date: Date) -> Self? {
        let id = input[event == "statusLine" ? "conversation_id" : "conversationId"] as? String
        guard let id, !id.isEmpty else { return nil }
        let kind: Kind
        switch event {
        case "SessionStart": kind = .opened
        case "PreInvocation": kind = .working
        case "Stop":
            guard input["fullyIdle"] as? Bool == true else { return nil }
            switch input["terminationReason"] as? String {
            case "model_stop": kind = .done
            case "error", "max_steps_exceeded": kind = .failed
            default: kind = .interrupted
            }
        case "statusLine":
            if input["tool_confirmation_pending"] as? Bool == true {
                kind = .approval
            } else if (input["task_count"] as? Int ?? 0) > 0 {
                kind = .working
            } else {
                switch input["agent_state"] as? String {
                case "working", "tool_use", "reviewing": kind = .working
                case "idle", "error": kind = .idle
                // Reviewing can be the user's diff viewer. It doesn't say an agent is waiting for permission.
                default: return nil
                }
            }
        default: return nil
        }
        let workspace = (input["workspacePaths"] as? [String])?.first ?? input["cwd"] as? String
        return Self(provider: .antigravity, session: id, kind: kind,
                    project: project(workspace), terminal: terminal, isSnapshot: event == "statusLine", date: date)
    }

    private static func project(_ path: String?) -> String? {
        path.flatMap { AgentEvent.firstLine(($0 as NSString).lastPathComponent) }
    }
}
