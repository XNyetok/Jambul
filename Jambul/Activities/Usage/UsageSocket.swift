import Darwin
import Foundation
import os

/// Listens on a Unix socket for what Claude Code's status line hands over: one JSON input per connection, then the
/// connection closes. It waits on the socket, so nothing runs between inputs.
///
/// The socket sits in a folder only the owner can open, so no other account on the Mac can reach it, and only files
/// macOS keeps for the owner name it. A Unix socket's path is limited to 103 bytes.
final class UsageSocket: @unchecked Sendable {
    /// The most an input may hold. Claude Code's status line input is a few kilobytes.
    static let maxInput = 256 * 1024

    let path: String
    private let onInput: @MainActor (Data) -> Void
    /// Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "com.debikurnia.Jambul.usage-socket")
    private var listener: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, data: Data)] = [:]

    init(path: String, onInput: @escaping @MainActor (Data) -> Void) {
        self.path = path
        self.onInput = onInput
    }

    deinit {
        listener?.cancel()
    }

    /// Opens the socket, replacing one a previous run left behind.
    func start() throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // Checked before anything on disk changes.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }

        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            let error = errno
            close(descriptor)
            throw POSIXError(.init(rawValue: error) ?? .EIO)
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients(on: descriptor) }
        source.setCancelHandler { close(descriptor) }
        queue.sync { listener = source }
        source.resume()
        Logger.activities.notice("usage: listening for Claude Code's status line")
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for (_, client) in clients { client.source.cancel() }
            clients = [:]
        }
        unlink(path)
    }

    private func acceptClients(on listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            source.setEventHandler { [weak self] in self?.read(client) }
            source.setCancelHandler { close(client) }
            clients[client] = (source, Data())
            source.resume()
        }
    }

    private func read(_ client: Int32) {
        guard var entry = clients[client] else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count > 0 {
                entry.data.append(contentsOf: buffer[..<count])
                if entry.data.count > Self.maxInput {
                    finish(client, delivering: nil)
                    return
                }
            } else if count == 0 {
                finish(client, delivering: entry.data)
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                clients[client] = entry
                return
            } else {
                finish(client, delivering: nil)
                return
            }
        }
    }

    private func finish(_ client: Int32, delivering data: Data?) {
        clients.removeValue(forKey: client)?.source.cancel()
        guard let data, !data.isEmpty else { return }
        let onInput = onInput
        Task { @MainActor in onInput(data) }
    }
}
