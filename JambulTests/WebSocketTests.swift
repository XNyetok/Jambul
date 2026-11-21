import Foundation
import Testing
@testable import Jambul

/// What Jambul reads from the Codex daemon's socket: the answer to its upgrade, then frames joined into messages.
struct WebSocketTests {
    /// RFC 6455's sample key: its nonce, in base64.
    private let key = Data("the sample nonce".utf8).base64EncodedString()

    private func answer(accept: String? = nil) -> Data {
        Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              + "Sec-WebSocket-Accept: \(accept ?? WebSocket.accept(for: key))\r\n\r\n").utf8)
    }

    private func text(_ string: String) -> Data {
        WebSocket.frame(Data(string.utf8), masked: false)
    }

    /// RFC 6455's own example.
    @Test func theAcceptAnswersTheKey() {
        #expect(WebSocket.accept(for: key) == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func aMessageCanArriveWithTheUpgrade() {
        var reader = WebSocket.Reader(key: key)
        #expect(reader.read(answer() + text(#"{"id":0}"#)) == [.upgraded, .message(Data(#"{"id":0}"#.utf8))])
    }

    @Test func anUpgradeForAnotherKeyIsRefused() {
        var reader = WebSocket.Reader(key: key)
        #expect(reader.read(answer(accept: "something else")) == nil)
        var refused = WebSocket.Reader(key: key)
        #expect(refused.read(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)) == nil)
    }

    /// Frames split anywhere, even byte by byte, still make whole messages, and a message split into frames is one.
    @Test func messagesSurviveAnySplit() {
        let long = String(repeating: "x", count: 70_000)
        var stream = answer() + text("first") + WebSocket.frame(Data(long.utf8), masked: false)
        stream += Data([0x01, 3]) + Data("par".utf8) + Data([0x80, 2]) + Data("ts".utf8)
        var reader = WebSocket.Reader(key: key)
        var events: [WebSocket.Reader.Event] = []
        for byte in stream {
            events += reader.read(Data([byte])) ?? [.closed]
        }
        #expect(events == [.upgraded, .message(Data("first".utf8)), .message(Data(long.utf8)),
                           .message(Data("parts".utf8))])
    }

    /// Masked as a client sends it, a frame reads back as it was.
    @Test func aMaskedFrameReadsBack() {
        var reader = WebSocket.Reader(key: key, upgraded: true)
        let payload = Data(#"{"method":"initialized"}"#.utf8)
        #expect(reader.read(WebSocket.frame(payload)) == [.message(payload)])
    }

    @Test func pingsAreAnsweredAndAPeerThatClosesIsDone() {
        var reader = WebSocket.Reader(key: key, upgraded: true)
        let ping = WebSocket.frame(Data("hi".utf8), opcode: .ping, masked: false)
        let pong = WebSocket.frame(Data(), opcode: .pong, masked: false)
        let close = WebSocket.frame(Data(), opcode: .close, masked: false)
        #expect(reader.read(ping + pong + text("after") + close + text("ignored")) == [
            .ping(Data("hi".utf8)), .message(Data("after".utf8)), .closed,
        ])
    }

    /// A message longer than the limit, like a turn with all its output, is passed over without being kept, and the
    /// next one still arrives.
    @Test func aMessageTooLongIsPassedOver() {
        var reader = WebSocket.Reader(key: key, messageLimit: 100, upgraded: true)
        let long = Data(repeating: 0x61, count: 150)
        var events = reader.read(Data([0x01, 60]) + long.prefix(60)) ?? []
        events += reader.read(Data([0x80, 90]) + long.prefix(50)) ?? []
        events += reader.read(long.prefix(40) + text("next")) ?? []
        #expect(events == [.message(Data("next".utf8))])
    }

    @Test func aBrokenProtocolEndsTheConnection() {
        var reserved = WebSocket.Reader(key: key, upgraded: true)
        #expect(reserved.read(Data([0xC1, 0])) == nil)
        var orphan = WebSocket.Reader(key: key, upgraded: true)
        #expect(orphan.read(Data([0x80, 0])) == nil)
        var interrupted = WebSocket.Reader(key: key, upgraded: true)
        #expect(interrupted.read(Data([0x01, 1, 0x61, 0x81, 1, 0x62])) == nil)
    }
}

/// The connection to the Codex daemon reads on its own queue. A message too long to keep is passed over there, so it
/// can't crowd out the others or drop the connection while the main actor is busy, and a daemon that hangs up ends it.
struct CodexControlConnectionTests {
    private func connect(_ home: URL) throws -> CodexControlConnection {
        try #require(CodexControlConnection(path: home.appending(path: "app-server-control/app-server-control.sock").path,
                                            queue: DispatchQueue(label: "test.codex-daemon")))
    }

    private func temporaryHome() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "JC-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Like a finished turn with all its output, far longer than the socket's buffer, arriving while the reader is busy.
    @Test func aLongMessageWhileTheReaderIsBusyKeepsTheConnection() async throws {
        let home = try temporaryHome()
        let long = #"{"method":"turn/completed","params":{"output":""# + String(repeating: "x", count: 900_000) + #""}}"#
        let daemon = try FakeCodexDaemon(home: home) { method, _ in method == "go" ? [long, #"{"id":7}"#] : [] }
        defer {
            daemon.stop()
            try? FileManager.default.removeItem(at: home)
        }
        let connection = try connect(home)
        defer { connection.close() }
        var events = connection.events.makeAsyncIterator()
        #expect(await events.next() == .upgraded)
        connection.send(Data(#"{"method":"go"}"#.utf8))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await events.next() == .message(Data(#"{"id":7}"#.utf8)))
    }

    /// Without a Close frame, Codex's daemon logs every connection Jambul ends as a reset.
    @Test @MainActor func closingSendsTheDaemonACloseFrame() async throws {
        let home = try temporaryHome()
        let daemon = try FakeCodexDaemon(home: home) { _, _ in [] }
        defer {
            daemon.stop()
            try? FileManager.default.removeItem(at: home)
        }
        let connection = try connect(home)
        var events = connection.events.makeAsyncIterator()
        #expect(await events.next() == .upgraded)
        connection.close()
        #expect(await events.next() == nil)
        try await waitUntil { daemon.ending != nil }
        #expect(daemon.ending == .closeFrame)
    }

    @Test func aDaemonThatHangsUpEndsTheConnection() async throws {
        let home = try temporaryHome()
        let daemon = try FakeCodexDaemon(home: home) { _, _ in [] }
        defer {
            daemon.stop()
            try? FileManager.default.removeItem(at: home)
        }
        let connection = try connect(home)
        var events = connection.events.makeAsyncIterator()
        #expect(await events.next() == .upgraded)
        daemon.hangUp()
        #expect(await events.next() == nil)
        // Closing after the daemon did, or sending, does nothing.
        connection.send(Data("{}".utf8))
        connection.close()
    }
}
