import Foundation
import Testing
@testable import Jambul

@MainActor
struct SessionInstallerTests {
    @Test func codexHooksCanBeRemovedWithoutChangingTheOwnersHooks() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = JSONSettingsFile(url: folder.appending(path: "hooks.json"))
        let relay = SessionRelay(executable: folder.appending(path: "session-relay"),
                                 socketPath: folder.appending(path: "agent.sock").path)
        let original = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "echo owned"]]]]]]
        try file.write(original)
        let installer = AgentHookInstaller(settingsURL: file.url, socketPath: relay.socketPath, codexRelay: relay)
        try installer.install()
        let installed = try Data(contentsOf: file.url)
        #expect(installer.isInstalled())
        try installer.install()
        #expect(try Data(contentsOf: file.url) == installed)
        try installer.uninstall()
        #expect(!installer.hasAny())
        #expect(try NSDictionary(dictionary: file.read()) == NSDictionary(dictionary: original))
    }

    @Test func agyUninstallRestoresTheStatusLineAndPreservesLaterEdits() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let hooks = JSONSettingsFile(url: folder.appending(path: "hooks.json"))
        let settings = JSONSettingsFile(url: folder.appending(path: "settings.json"))
        let relay = SessionRelay(executable: folder.appending(path: "session-relay"),
                                 socketPath: folder.appending(path: "agent.sock").path)
        let original = ["statusLine": ["command": "cat", "padding": 1]]
        try settings.write(original)
        try hooks.write(["owner": ["enabled": false]])
        let installer = AntigravitySessionInstaller(hooks: hooks, settings: settings,
                                                    savedURL: folder.appending(path: "saved.json"), relay: relay)
        try installer.install()
        #expect(installer.hasAny())
        var edited = try settings.read()
        var line = try #require(edited["statusLine"] as? [String: Any])
        #expect(line["command"] as? String == relay.statusLine(wrapping: "cat"))
        line["padding"] = 2
        edited["statusLine"] = line
        try settings.write(edited)
        try installer.uninstall()
        #expect(!installer.hasAny())
        #expect(try NSDictionary(dictionary: settings.read()) == ["statusLine": ["command": "cat", "padding": 2]])
        #expect(try NSDictionary(dictionary: hooks.read()) == ["owner": ["enabled": false]])
    }

    @Test func theRealRelayPreservesStatusLineOutputAndStripsAccountData() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = try #require(Bundle.main.executableURL)
        let relay = SessionRelay(executable: folder.appending(path: "session-relay"),
                                 socketPath: folder.appending(path: "agent.sock").path)
        try relay.pointToApp(executable)
        let center = ActivityCenter()
        let agent = AgentActivity(activities: center)
        center.register(agent)
        let island = IslandModel(notch: NotchMetrics(size: CGSize(width: 179, height: 32), compactHeight: 33),
                                 activities: center)
        let agy = AntigravitySessionSource()
        agy.onUpdate = { agent.receive($0) }
        var received: [Data] = []
        let socket = InputSocket(path: relay.socketPath) { data in
            received.append(data)
            if let update = AgentSessionUpdate.fromSocket(data), update.provider == .antigravity {
                agy.receive(update)
            }
        }
        try socket.start()
        defer { socket.stop() }
        let statusLine = relay.statusLine(wrapping: "/bin/cat")
        let working = #"{"conversation_id":"a","cwd":"/tmp/Jambul","agent_state":"tool_use","tool_confirmation_pending":false}"#
        #expect(try run(statusLine, input: working) == working)
        try await waitUntil { received.count == 1 }
        #expect(agent.liveSession?.state == .working)
        #expect(island.presentation != .peek)

        let payload = """
            {"conversation_id":"a","cwd":"/tmp/Jambul","tool_confirmation_pending":true,"email":"omit-this"}

            """
        let output = try run(statusLine, input: payload)
        #expect(output == payload)
        try await waitUntil { received.count == 2 }
        let status = try #require(received.last)
        #expect(AgentSessionUpdate.fromSocket(status)?.kind == .approval)
        #expect(!String(decoding: status, as: UTF8.self).contains("omit-this"))
        #expect(agent.liveSession?.state == .needsYou(isQuestion: false))
        #expect(island.presentation == .peek)
        #expect(island.peek?.title == "Needs you · Antigravity · Jambul")

        #expect(try run(statusLine, input: working) == working)
        try await waitUntil { received.count == 3 }
        #expect(agent.liveSession?.state == .working)
        #expect(island.presentation != .peek)

        let codex = #"{"session_id":"codex","turn_id":"t1","hook_event_name":"UserPromptSubmit","prompt":"omit-this"}"#
        let hook = relay.hook(provider: .codex, event: "UserPromptSubmit")
        #expect(try run(hook, input: codex) == "{}\n")
        try await waitUntil { received.count == 4 }
        let event = try #require(received.last)
        #expect(AgentSessionUpdate.fromSocket(event)?.kind == .prompted)
        #expect(!String(decoding: event, as: UTF8.self).contains("omit-this"))
        #expect(try run(hook, input: codex, isUsageReport: true) == "{}\n")
        try await Task.sleep(for: .milliseconds(40))
        #expect(received.count == 4)
    }

    private func run(_ command: String, input: String, isUsageReport: Bool = false) throws -> String {
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        if isUsageReport { environment[SessionRelay.internalRun] = "1" }
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }

    private func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "JI-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
