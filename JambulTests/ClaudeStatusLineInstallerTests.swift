import Foundation
import Testing
@testable import Jambul

/// Each test works in a folder of its own, never in the real ~/.claude.
struct ClaudeStatusLineInstallerTests {
    private let folder: URL
    private let installer: ClaudeStatusLineInstaller

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "JambulTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        installer = ClaudeStatusLineInstaller(settingsURL: folder.appending(path: ".claude/settings.json"),
                                              savedURL: folder.appending(path: "Jambul/claude-statusline.json"),
                                              socketPath: folder.appending(path: "it's usage.sock").path)
    }

    private func writeSettings(_ text: String, to url: URL? = nil) throws {
        let url = url ?? installer.settingsURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func settings(at url: URL? = nil) throws -> [String: Any] {
        let data = try Data(contentsOf: url ?? installer.settingsURL)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func statusLine() throws -> [String: Any]? {
        try settings()["statusLine"] as? [String: Any]
    }

    @Test func connectsWithoutAStatusLineAndDisconnectsCleanly() throws {
        try writeSettings(#"{"model":"opus","hooks":{}}"#)
        try installer.install()
        #expect(installer.isInstalled())
        let command = try #require(try statusLine()?["command"] as? String)
        #expect(command.hasPrefix(ClaudeStatusLineInstaller.marker))
        #expect(try statusLine()?["type"] as? String == "command")
        #expect(try settings()["model"] as? String == "opus")

        try installer.uninstall()
        #expect(!installer.isInstalled())
        #expect(try statusLine() == nil)
        #expect(try settings()["model"] as? String == "opus")
        #expect(!FileManager.default.fileExists(atPath: installer.savedURL.path))
    }

    @Test func wrapsTheOwnersStatusLineAndPutsItBackExactly() throws {
        try writeSettings(#"{"statusLine":{"type":"command","command":"~/.claude/statusline.py","padding":0}}"#)
        let before = try statusLine()
        try installer.install()
        let command = try #require(try statusLine()?["command"] as? String)
        #expect(command.contains("( ~/.claude/statusline.py\n)"))
        #expect(try statusLine()?["padding"] as? Int == 0)

        try installer.uninstall()
        #expect(NSDictionary(dictionary: try #require(try statusLine())) == NSDictionary(dictionary: try #require(before)))
    }

    @Test func connectingTwiceStillPutsBackTheOwnersStatusLine() throws {
        try writeSettings(#"{"statusLine":{"type":"command","command":"echo mine"}}"#)
        try installer.install()
        try installer.install()
        try installer.uninstall()
        #expect(try statusLine()?["command"] as? String == "echo mine")
    }

    @Test func leavesAStatusLineTheOwnerReplacedSince() throws {
        try writeSettings(#"{"statusLine":{"type":"command","command":"echo mine"}}"#)
        try installer.install()
        try writeSettings(#"{"statusLine":{"type":"command","command":"echo newer"}}"#)
        try installer.uninstall()
        #expect(try statusLine()?["command"] as? String == "echo newer")
    }

    /// An app cleaner can remove Jambul's folder, and the copy with it.
    @Test func putsTheOwnersLineBackWithoutItsCopy() throws {
        try writeSettings(#"{"statusLine":{"type":"command","command":"echo mine","padding":2}}"#)
        try installer.install()
        try FileManager.default.removeItem(at: installer.savedURL)
        try installer.uninstall()
        #expect(try statusLine()?["command"] as? String == "echo mine")
        #expect(try statusLine()?["padding"] as? Int == 2)
    }

    @Test func keepsAChangeMadeInsideJambulsLine() throws {
        try writeSettings(#"{"statusLine":{"type":"command","command":"echo mine"}}"#)
        try installer.install()
        let command = try #require(try statusLine()?["command"] as? String)
        let edited = command.replacingOccurrences(of: "echo mine", with: "echo edited")
        try writeSettings(String(decoding: try JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": edited],
        ]), as: UTF8.self))
        try installer.uninstall()
        #expect(try statusLine()?["command"] as? String == "echo edited")
    }

    @Test func leavesALineItCannotReadBack() throws {
        let odd = "\(ClaudeStatusLineInstaller.marker); something else entirely"
        try writeSettings(String(decoding: try JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": odd],
        ]), as: UTF8.self))
        try installer.uninstall()
        #expect(try statusLine()?["command"] as? String == odd)
    }

    /// The first build wrote its line without the newline the owner's status line needs; connecting brings it up to date.
    @Test func bringsAnOlderLineUpToDate() throws {
        let socket = "'" + installer.socketPath.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        let older = #"\#(ClaudeStatusLineInstaller.marker); IN=$(cat); { printf '%s' "$IN" | /usr/bin/nc -U -w 1 \#(socket) >/dev/null 2>&1 & }; printf '%s' "$IN" | ( echo mine"# + "\n)"
        try writeSettings(String(decoding: try JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": older],
        ]), as: UTF8.self))
        try installer.install()
        let expected = ClaudeStatusLineInstaller.command(socketPath: installer.socketPath, wrapping: "echo mine")
        #expect(try statusLine()?["command"] as? String == expected)
        try installer.uninstall()
        #expect(try statusLine()?["command"] as? String == "echo mine")
    }

    @Test func followsALinkedSettingsFile() throws {
        let target = folder.appending(path: "dotfiles/claude-settings.json")
        try writeSettings(#"{"statusLine":{"type":"command","command":"echo mine"}}"#, to: target)
        try FileManager.default.createDirectory(at: installer.settingsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: installer.settingsURL, withDestinationURL: target)
        try installer.install()
        let type = try FileManager.default.attributesOfItem(atPath: installer.settingsURL.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        #expect(installer.isInstalled())
        try installer.uninstall()
        #expect((try settings(at: target)["statusLine"] as? [String: Any])?["command"] as? String == "echo mine")
    }

    @Test func leavesSettingsItCannotReadAlone() throws {
        try writeSettings("{ not json")
        #expect(throws: ClaudeStatusLineInstaller.Failure.unreadableSettings) { try installer.install() }
        #expect(try String(contentsOf: installer.settingsURL, encoding: .utf8) == "{ not json")
    }

    @Test func keepsTheFirstVersionItChanged() throws {
        try writeSettings(#"{"model":"opus"}"#)
        try installer.install()
        let backup = installer.settingsURL.appendingPathExtension("jambul-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == #"{"model":"opus"}"#)
    }

    @Test func removesSettingsItCreatedOnceEmptyAgain() throws {
        try installer.install()
        #expect(installer.isInstalled())
        try installer.uninstall()
        #expect(!FileManager.default.fileExists(atPath: installer.settingsURL.path))
    }

    /// The status line itself, run as Claude Code runs it, with the input ending in a newline: a line that reads its
    /// input with `read` sees it whole, and its output comes through unchanged, though nothing listens on the socket.
    @Test func theStatusLineStillShowsTheOwnersOutput() throws {
        let original = #"set -eu; read -r input; printf '%s' "$input" | tr a-z A-Z"#
        let command = ClaudeStatusLineInstaller.command(socketPath: installer.socketPath, wrapping: original)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = ["-c", command]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("{\"model\":\"opus\"}\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text == #"{"MODEL":"OPUS"}"#)
        #expect(process.terminationStatus == 0)
    }

    @Test(arguments: [nil, "echo mine", "printf '%s' \"$IN\" | ( tricky\n)"])
    func readsTheOwnersLineBackOutOfJambuls(original: String?) {
        let command = ClaudeStatusLineInstaller.command(socketPath: "/tmp/s.sock", wrapping: original)
        #expect(ClaudeStatusLineInstaller.original(in: command) == .some(original))
    }
}
