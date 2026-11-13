import Foundation
import Testing
@testable import Jambul

@MainActor
private final class HookInbox {
    var inputs: [Data] = []
}

/// Each test works in a folder of its own, never in the real ~/.claude. The folder's path is short, for the socket.
@MainActor
struct AgentHookInstallerTests {
    private let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "jh-\(UUID().uuidString.prefix(8))")
    private var installer: AgentHookInstaller {
        AgentHookInstaller(settingsURL: folder.appending(path: ".claude/settings.json"),
                           socketPath: folder.appending(path: "a.sock").path)
    }

    /// Someone else's hooks, like another app's on every event and a guard on Bash only.
    private let othersHooks = #"""
    {"model":"opus","hooks":{
      "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard.py"}]},
                    {"hooks":[{"type":"command","command":"other report"}]}],
      "Stop":[{"hooks":[{"type":"command","command":"other report"}]}],
      "SubagentStop":[{"hooks":[{"type":"command","command":"other report"}]}]
    }}
    """#

    private func writeSettings(_ text: String) throws {
        let url = installer.settingsURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func settings() throws -> [String: Any] {
        let data = try Data(contentsOf: installer.settingsURL)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func commands(for event: String) throws -> [String] {
        let groups = try settings()["hooks"].flatMap { ($0 as? [String: Any])?[event] as? [[String: Any]] } ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    @Test func connectsOnEveryEventAfterTheOwnersHooksAndLeavesThemAlone() throws {
        try writeSettings(othersHooks)
        let before = try settings()
        try installer.install()
        #expect(installer.isInstalled())
        let jambuls = AgentHookInstaller.command(socketPath: installer.socketPath)
        for event in AgentHookInstaller.events {
            #expect(try commands(for: event).last == jambuls, "\(event)")
        }
        #expect(try commands(for: "PreToolUse") == ["guard.py", "other report", jambuls])
        #expect(try commands(for: "SubagentStop") == ["other report"])
        #expect(try settings()["model"] as? String == "opus")

        try installer.uninstall()
        #expect(!installer.isInstalled())
        #expect(!installer.hasAny())
        #expect(NSDictionary(dictionary: try settings()) == NSDictionary(dictionary: before))
    }

    @Test func connectingTwiceChangesNothing() throws {
        try writeSettings(othersHooks)
        try installer.install()
        let once = try Data(contentsOf: installer.settingsURL)
        try installer.install()
        #expect(try Data(contentsOf: installer.settingsURL) == once)
    }

    @Test func withoutSettingsItCreatesThemAndRemovesThemAgain() throws {
        try installer.install()
        #expect(installer.isInstalled())
        try installer.uninstall()
        #expect(!FileManager.default.fileExists(atPath: installer.settingsURL.path))
    }

    @Test func anOlderHookOfJambulsIsReplacedNotDoubled() throws {
        let older = AgentHookInstaller(settingsURL: installer.settingsURL, socketPath: "/tmp/old.sock")
        try writeSettings(othersHooks)
        try older.install()
        #expect(!installer.isInstalled())
        #expect(installer.hasAny())
        try installer.install()
        #expect(try commands(for: "Stop") == ["other report", AgentHookInstaller.command(socketPath: installer.socketPath)])
    }

    @Test func theFirstVersionJambulChangedIsKept() throws {
        try writeSettings(othersHooks)
        try installer.install()
        try installer.uninstall()
        try installer.install()
        let backup = installer.settingsURL.appendingPathExtension("jambul-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == othersHooks)
    }

    /// An event that isn't a list of hooks is the owner's to fix; Jambul leaves it as it is.
    @Test func anEventThatIsntAListStaysAsItIs() throws {
        try writeSettings(#"{"hooks":{"Stop":"oops"}}"#)
        try installer.install()
        let hooks = try #require(try settings()["hooks"] as? [String: Any])
        #expect(hooks["Stop"] as? String == "oops")
        try installer.uninstall()
        #expect(try settings()["hooks"] as? [String: String] == ["Stop": "oops"])
    }

    @Test func settingsItCantReadAreLeftAlone() throws {
        try writeSettings("{not json")
        #expect(throws: ClaudeSettingsFile.Failure.unreadableSettings) { try installer.install() }
        try writeSettings(#"{"hooks":[]}"#)
        #expect(throws: ClaudeSettingsFile.Failure.unreadableSettings) { try installer.install() }
        #expect(try String(contentsOf: installer.settingsURL, encoding: .utf8) == #"{"hooks":[]}"#)
    }

    /// The hook as Claude Code runs it: through the shell, with the hook's input on its standard input. It returns at
    /// once, and Jambul hears the app it runs in, then the input.
    @Test func theHookHandsItsInputToJambul() async throws {
        let inbox = HookInbox()
        let socket = InputSocket(path: installer.socketPath) { inbox.inputs.append($0) }
        try socket.start()
        defer { socket.stop() }

        let input = #"{"session_id":"s1","hook_event_name":"Stop"}"#
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", AgentHookInstaller.command(socketPath: installer.socketPath)]
        process.environment = ["__CFBundleIdentifier": "com.apple.Terminal", "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        try await waitUntil { !inbox.inputs.isEmpty }
        #expect(String(decoding: inbox.inputs[0], as: UTF8.self) == "com.apple.Terminal\n" + input)
        #expect(AgentEvent.parse(inbox.inputs[0])?.kind == .stop)
    }

    /// With Jambul gone, the hook still returns at once and says nothing, so Claude Code carries on.
    @Test func withoutJambulTheHookReturnsQuietly() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", AgentHookInstaller.command(socketPath: installer.socketPath)]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
