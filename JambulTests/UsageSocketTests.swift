import Foundation
import Testing
@testable import Jambul

@MainActor
private final class Inbox {
    var inputs: [Data] = []
}

/// Sends through macOS's own `nc`, as the status line does. The socket lives in a folder of its own under the temporary
/// folder, whose short path fits a Unix socket.
@MainActor
struct UsageSocketTests {
    private let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "jt-\(UUID().uuidString.prefix(8))")

    private func send(_ data: Data, to path: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/nc")
        process.arguments = ["-U", "-w", "1", path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(data)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    private func waitFor(_ inbox: Inbox, count: Int) async throws {
        for _ in 0..<200 where inbox.inputs.count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func handsOverEachInput() async throws {
        let inbox = Inbox()
        let path = folder.appending(path: "u.sock").path
        let socket = UsageSocket(path: path) { inbox.inputs.append($0) }
        try socket.start()
        defer {
            socket.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let first = Data(#"{"rate_limits":{"five_hour":{"used_percentage":42}}}"#.utf8)
        let second = Data(repeating: 0x20, count: 40_000) + Data("{}".utf8)
        try send(first, to: path)
        try send(second, to: path)
        try await waitFor(inbox, count: 2)
        #expect(inbox.inputs == [first, second])
    }

    @Test func onlyTheOwnerCanReachIt() throws {
        let path = folder.appending(path: "u.sock").path
        let socket = UsageSocket(path: path) { _ in }
        try socket.start()
        defer {
            socket.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        let socketMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        #expect(socketMode == 0o600)
    }

    @Test func refusesAPathTooLongForASocket() {
        let socket = UsageSocket(path: folder.appending(path: String(repeating: "a", count: 120)).path) { _ in }
        #expect(throws: POSIXError.self) { try socket.start() }
        // Nothing on disk changed.
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
