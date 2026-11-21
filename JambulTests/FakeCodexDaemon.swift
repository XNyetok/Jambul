import Darwin
import Foundation
@testable import Jambul

/// Stands in for the Codex app-server daemon: a Unix socket that takes one connection, answers its WebSocket upgrade,
/// and answers each request with what `reply` gives for its method and id, as JSON texts. It speaks WebSocket as
/// the daemon does (measured with Codex 0.171), not the JSON lines a proxy could have translated it to.
final class FakeCodexDaemon: @unchecked Sendable {
    let socketPath: String
    /// Requests the daemon received, by method, in order.
    var methods: [String] { lock.withLock { received } }
    private let listener: Int32
    private let reply: @Sendable (_ method: String, _ id: Int?) -> [String]
    private let answersUpgrade: Bool
    private let lock = NSLock()
    private var received: [String] = []
    private var client: Int32 = -1

    /// - Parameters:
    ///   - home: Codex's home, where the daemon's socket is linked from as Codex links it.
    ///   - answersUpgrade: Whether it switches to WebSocket; a daemon that doesn't hangs up instead.
    init(home: URL, answersUpgrade: Bool = true, reply: @escaping @Sendable (_ method: String, _ id: Int?) -> [String]) throws {
        self.reply = reply
        self.answersUpgrade = answersUpgrade
        // Short, as Codex's own socket in the temporary folder is; Codex's home only links to it.
        socketPath = URL(filePath: NSTemporaryDirectory()).appending(path: "jc-\(UUID().uuidString.prefix(8))").path
        let link = home.appending(path: "app-server-control/app-server-control.sock")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard listener >= 0, bound == 0, listen(listener, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: socketPath)
        Thread.detachNewThread { [self] in serve() }
    }

    /// Closes the connection, as a daemon restarting would.
    func hangUp() {
        lock.withLock {
            if client >= 0 { shutdown(client, SHUT_RDWR) }
        }
    }

    func stop() {
        hangUp()
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(socketPath)
    }

    private func serve() {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        lock.withLock { client = connection }
        defer {
            lock.withLock { client = -1 }
            close(connection)
        }
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return }
            request += buffer[..<count]
        }
        let headers = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        guard answersUpgrade, let keyLine = headers.first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") })
        else { return }
        let key = keyLine.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
        let answer = "HTTP/1.1 101 Switching Protocols\r\nconnection: Upgrade\r\nupgrade: websocket\r\n"
            + "sec-websocket-accept: \(WebSocket.accept(for: key))\r\n\r\n"
        guard CodexControlSocket.write(Data(answer.utf8), to: connection) else { return }
        // Whatever followed the upgrade in the same read is the first frame.
        var reader = WebSocket.Reader(key: key, upgraded: true)
        var pending = request.range(of: Data("\r\n\r\n".utf8)).map { Data(request[$0.upperBound...]) } ?? Data()
        while true {
            guard let events = reader.read(pending) else { return }
            for case .message(let data) in events {
                guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let method = message["method"] as? String else { continue }
                lock.withLock { received.append(method) }
                for text in reply(method, message["id"] as? Int) {
                    guard CodexControlSocket.write(WebSocket.frame(Data(text.utf8), masked: false), to: connection)
                    else { return }
                }
            }
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return }
            pending = Data(buffer[..<count])
        }
    }
}
