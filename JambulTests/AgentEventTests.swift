import Foundation
import Testing
@testable import Jambul

/// Inputs shaped like the ones Claude Code's hooks hand over: the app it runs in on the first line, then the JSON.
struct AgentEventTests {
    private func input(_ fields: [String: Any], app: String = "com.apple.Terminal") throws -> Data {
        var base: [String: Any] = ["session_id": "s1", "transcript_path": "/tmp/work/s1.jsonl", "cwd": "/tmp/work/Jambul"]
        base.merge(fields) { $1 }
        // In order, so `cwd`, `hook_event_name` and `session_id` come before what a tool returned, as from Claude Code.
        return Data((app + "\n").utf8) + (try JSONSerialization.data(withJSONObject: base, options: .sortedKeys))
    }

    @Test func readsTheSessionItsProjectAndTheAppItRunsIn() throws {
        let event = try #require(AgentEvent.parse(try input(["hook_event_name": "UserPromptSubmit", "prompt": "hi"])))
        #expect(event.kind == .prompt)
        #expect(event.session == "s1")
        #expect(event.project == "Jambul")
        #expect(event.terminal == "com.apple.Terminal")
        #expect(event.transcriptPath == "/tmp/work/s1.jsonl")
    }

    @Test func anEmptyFirstLineMeansNoKnownApp() throws {
        let event = try #require(AgentEvent.parse(try input(["hook_event_name": "Stop"], app: "")))
        #expect(event.terminal == nil)
    }

    @Test(arguments: [
        ("SessionStart", AgentEvent.Kind.sessionStart), ("PreToolUse", .toolWillRun), ("PermissionRequest", .permission),
        ("PostToolUse", .toolRan(failed: false)), ("PostToolUseFailure", .toolRan(failed: true)), ("Stop", .stop),
        ("StopFailure", .stopFailure), ("SessionEnd", .sessionEnd),
    ])
    func readsEachHook(name: String, kind: AgentEvent.Kind) throws {
        #expect(AgentEvent.parse(try input(["hook_event_name": name]))?.kind == kind)
    }

    @Test func aNotificationKeepsItsType() throws {
        let event = AgentEvent.parse(try input(["hook_event_name": "Notification", "notification_type": "permission_prompt"]))
        #expect(event?.kind == .notification("permission_prompt"))
    }

    @Test func anUnknownHookOrAMissingSessionIsNoEvent() throws {
        #expect(AgentEvent.parse(try input(["hook_event_name": "SubagentStop"])) == nil)
        #expect(AgentEvent.parse(try input(["hook_event_name": "Stop", "session_id": ""])) == nil)
        #expect(AgentEvent.parse(Data("com.apple.Terminal\nnot json".utf8)) == nil)
    }

    @Test func aCommandReadsAsItsDescription() throws {
        let event = AgentEvent.parse(try input([
            "hook_event_name": "PreToolUse", "tool_name": "Bash",
            "tool_input": ["command": "./scripts/test.sh", "description": "Run the unit tests"],
        ]))
        #expect(event?.toolSummary == "Run the unit tests")
    }

    @Test func aCommandWithoutADescriptionReadsAsItsFirstLine() throws {
        let event = AgentEvent.parse(try input([
            "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "make test\nmake run"],
        ]))
        #expect(event?.toolSummary == "make test")
    }

    @Test func anEditNamesItsFile() throws {
        let event = AgentEvent.parse(try input([
            "hook_event_name": "PostToolUse", "tool_name": "Edit",
            "tool_input": ["file_path": "/tmp/work/Jambul/Island/IslandView.swift", "old_string": "a", "new_string": "b"],
        ]))
        #expect(event?.toolSummary == "Editing IslandView.swift")
        #expect(event?.editedFile == "/tmp/work/Jambul/Island/IslandView.swift")
    }

    @Test func anMCPToolReadsAsItsServer() throws {
        let event = AgentEvent.parse(try input(["hook_event_name": "PreToolUse", "tool_name": "mcp__github__create_issue"]))
        #expect(event?.toolSummary == "Using github")
    }

    @Test func aTurnThatEndedKeepsTheFirstLineOfItsReply() throws {
        let event = AgentEvent.parse(try input([
            "hook_event_name": "Stop", "last_assistant_message": "\n## **Done**: tests pass\n\nMore below.",
        ]))
        #expect(event?.reply == "Done: tests pass")
    }

    /// Text from an agent can hide or turn itself around with characters nobody sees; none of them reach the island.
    @Test func invisibleAndReversingCharactersAreDropped() {
        let text = "safe\u{202E}txt.exe\u{200B} ok\u{2028}\u{0007}"
        #expect(AgentEvent.firstLine(text) == "safetxt.exe ok")
    }

    @Test func aLongLineIsCut() throws {
        let line = try #require(AgentEvent.firstLine(String(repeating: "word ", count: 100)))
        #expect(line.count == 160)
        #expect(line.hasSuffix("…"))
    }

    /// An input past the socket's limit arrives cut short; what comes first still says which session did what.
    @Test func anInputCutShortStillNamesItsSessionAndHook() throws {
        let full = try input([
            "hook_event_name": "PostToolUse", "tool_name": "Read",
            "tool_response": String(repeating: "x", count: 10_000),
        ])
        let event = try #require(AgentEvent.parse(full.prefix(2_000)))
        #expect(event.kind == .toolRan(failed: false))
        #expect(event.session == "s1")
        #expect(event.project == "Jambul")
        #expect(event.terminal == "com.apple.Terminal")
    }
}
