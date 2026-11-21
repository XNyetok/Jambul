import CryptoKit
import Darwin
import Foundation

/// The Unix socket the Codex app-server daemon listens on. The daemon speaks JSON-RPC in WebSocket text frames, and
/// `codex app-server proxy` only relays raw bytes to it (measured with Codex 0.171), so Jambul speaks WebSocket itself
/// and starts no process of Codex's to reach it.
enum CodexControlSocket {
    /// Connects without blocking, or returns nil. The daemon's socket sits behind a symlink in Codex's home; its own path
    /// stands in when the symlink's is too long for a Unix socket.
    static func connect(to path: String) -> Int32? {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        var bytes = Array(path.utf8)
        if bytes.count >= capacity { bytes = Array(URL(filePath: path).resolvingSymlinksInPath().path.utf8) }
        guard bytes.count < capacity else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
            close(descriptor)
            return nil
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Writes all of `data`, or returns false.
    static func write(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.write(descriptor, start.advanced(by: offset), buffer.count - offset)
                if sent > 0 {
                    offset += sent
                } else if sent < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

/// One connection to the daemon. Everything that touches its descriptor runs on `queue`: reading, joining frames into
/// messages, answering pings, writing and closing, so nothing can write to a descriptor that has closed, or been reused
/// since. Messages come out whole and in order, and one too long to keep is passed over there, so no message, however
/// long, can crowd the others out while the main actor is busy.
final class CodexControlConnection: @unchecked Sendable {
    /// The upgrade, then each message. It finishes once the connection closes.
    let events: AsyncStream<WebSocket.Reader.Event>
    private let continuation: AsyncStream<WebSocket.Reader.Event>.Continuation
    private let descriptor: Int32
    private let queue: DispatchQueue
    /// Touched only on `queue`.
    private var source: DispatchSourceRead?
    private var reader: WebSocket.Reader
    private var isClosed = false

    /// Connects to the daemon's socket at `path` and asks it to switch to WebSocket, or returns nil.
    init?(path: String, queue: DispatchQueue, messageLimit: Int = 256 * 1024) {
        guard let descriptor = CodexControlSocket.connect(to: path) else { return nil }
        let key = WebSocket.makeKey()
        self.descriptor = descriptor
        self.queue = queue
        reader = WebSocket.Reader(key: key, messageLimit: messageLimit)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(256))
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        // Held until the source is cancelled, which `close` and a hang-up both do.
        source.setEventHandler { [self] in readAvailable() }
        source.setCancelHandler { Darwin.close(descriptor) }
        queue.async { [self] in
            self.source = source
            source.resume()
            write(WebSocket.upgradeRequest(key: key))
        }
    }

    /// Sends one text message, unless the connection has closed.
    func send(_ text: Data) {
        queue.async { [self] in
            guard !isClosed else { return }
            write(WebSocket.frame(text))
        }
    }

    /// Closes it, and `events` finishes. Closing again does nothing.
    func close() {
        queue.async { [self] in finish() }
    }

    // MARK: On `queue`

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !isClosed {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard let events = reader.read(Data(buffer[..<count])) else { return finish() }
                for event in events where !isClosed {
                    switch event {
                    case .ping(let payload):
                        write(WebSocket.frame(payload, opcode: .pong))
                    case .closed:
                        finish()
                    case .upgraded, .message:
                        if case .dropped = continuation.yield(event) { finish() }
                    }
                }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                // Hung up, or failed: cancelled, the source stops firing at the end of the stream.
                return finish()
            }
        }
    }

    private func write(_ data: Data) {
        if !CodexControlSocket.write(data, to: descriptor) { finish() }
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        source?.cancel()
        source = nil
        continuation.finish()
    }
}

/// The parts of WebSocket (RFC 6455) Jambul needs as a client: the upgrade, and text frames each way.
enum WebSocket {
    static func makeKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
    }

    static func upgradeRequest(key: String) -> Data {
        Data(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8)
    }

    /// What the server answers to `key`, proving it read the upgrade.
    static func accept(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    enum Opcode: UInt8 {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }

    /// One whole frame. A client masks what it sends; a server, as in tests, doesn't.
    static func frame(_ payload: Data, opcode: Opcode = .text, masked: Bool = true) -> Data {
        var bytes: [UInt8] = [0x80 | opcode.rawValue]
        let maskBit: UInt8 = masked ? 0x80 : 0
        let count = payload.count
        if count < 126 {
            bytes.append(maskBit | UInt8(count))
        } else if count <= 0xFFFF {
            bytes += [maskBit | 126, UInt8(count >> 8), UInt8(count & 0xFF)]
        } else {
            bytes.append(maskBit | 127)
            bytes += stride(from: 56, through: 0, by: -8).map { UInt8((UInt64(count) >> UInt64($0)) & 0xFF) }
        }
        guard masked else { return Data(bytes) + payload }
        var generator = SystemRandomNumberGenerator()
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        bytes += mask
        bytes += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        return Data(bytes)
    }

    /// Reads what a peer sends: the server's answer to the upgrade, unless `upgraded`, then frames joined into
    /// messages. A message longer than `messageLimit` is passed over without being kept.
    struct Reader {
        enum Event: Equatable {
            case upgraded
            case message(Data)
            case ping(Data)
            case closed
        }

        private let key: String
        private let messageLimit: Int
        private(set) var isUpgraded: Bool
        private var buffer: [UInt8] = []
        private var message: [UInt8] = []
        private var inMessage = false
        /// The message being received is too long and is dropped as it arrives.
        private var dropping = false
        /// Payload bytes still to drop, and whether the frame they belong to ends its message.
        private var bytesToDrop = 0
        private var droppedFrameIsFinal = false

        init(key: String, messageLimit: Int = 1 << 20, upgraded: Bool = false) {
            self.key = key
            self.messageLimit = messageLimit
            isUpgraded = upgraded
        }

        /// Takes what arrived; returns what it completes, or nil once the peer has broken the protocol.
        mutating func read(_ data: Data) -> [Event]? {
            buffer += data
            var events: [Event] = []
            var offset = 0
            defer { buffer.removeFirst(min(offset, buffer.count)) }
            if !isUpgraded {
                guard let end = Self.endOfHeaders(in: buffer) else { return buffer.count > 16 * 1024 ? nil : [] }
                guard Self.upgradeSucceeded(String(decoding: buffer[..<end], as: UTF8.self), key: key) else { return nil }
                isUpgraded = true
                offset = end + 4
                events.append(.upgraded)
            }
            while true {
                if bytesToDrop > 0 {
                    let dropped = min(bytesToDrop, buffer.count - offset)
                    offset += dropped
                    bytesToDrop -= dropped
                    guard bytesToDrop == 0 else { return events }
                    if droppedFrameIsFinal { endMessage() }
                }
                guard buffer.count - offset >= 2 else { return events }
                let first = buffer[offset], second = buffer[offset + 1]
                let isFinal = first & 0x80 != 0, isMasked = second & 0x80 != 0
                guard first & 0x70 == 0, let opcode = Opcode(rawValue: first & 0x0F) else { return nil }
                let lengthField = Int(second & 0x7F)
                let lengthBytes = lengthField == 126 ? 2 : lengthField == 127 ? 8 : 0
                let headerLength = 2 + lengthBytes + (isMasked ? 4 : 0)
                guard buffer.count - offset >= headerLength else { return events }
                var length = UInt64(lengthField)
                if lengthBytes > 0 {
                    length = buffer[(offset + 2)..<(offset + 2 + lengthBytes)].reduce(0) { $0 << 8 | UInt64($1) }
                }
                let mask = isMasked ? Array(buffer[(offset + 2 + lengthBytes)..<(offset + headerLength)]) : nil
                let isControl = opcode.rawValue >= 0x8
                if isControl {
                    guard isFinal, length <= 125 else { return nil }
                } else if (opcode == .continuation) != inMessage {
                    // A continuation needs a message to continue, and a new message can't start inside another.
                    return nil
                }
                if !isControl, dropping || length > UInt64(messageLimit - message.count) {
                    // Too long to keep: drop the rest of this message as it arrives.
                    offset += headerLength
                    inMessage = true
                    dropping = true
                    message = []
                    bytesToDrop = Int(clamping: length)
                    droppedFrameIsFinal = isFinal
                    if bytesToDrop == 0, isFinal { endMessage() }
                    continue
                }
                let count = Int(length)
                guard buffer.count - offset >= headerLength + count else { return events }
                var payload = Array(buffer[(offset + headerLength)..<(offset + headerLength + count)])
                if let mask { payload = payload.enumerated().map { $0.element ^ mask[$0.offset % 4] } }
                offset += headerLength + count
                switch opcode {
                case .close:
                    events.append(.closed)
                    return events
                case .ping:
                    events.append(.ping(Data(payload)))
                case .pong:
                    break
                case .continuation, .text, .binary:
                    inMessage = true
                    message += payload
                    if isFinal {
                        events.append(.message(Data(message)))
                        endMessage()
                    }
                }
            }
        }

        private mutating func endMessage() {
            message = []
            inMessage = false
            dropping = false
            droppedFrameIsFinal = false
        }

        private static func endOfHeaders(in bytes: [UInt8]) -> Int? {
            guard bytes.count >= 4 else { return nil }
            return (0...(bytes.count - 4)).first { bytes[$0] == 13 && bytes[$0 + 1] == 10 && bytes[$0 + 2] == 13
                && bytes[$0 + 3] == 10 }
        }

        /// Whether the server switched to WebSocket for this `key`.
        private static func upgradeSucceeded(_ headers: String, key: String) -> Bool {
            let lines = headers.components(separatedBy: "\r\n")
            guard let status = lines.first, status.hasPrefix("HTTP/1.1 101") else { return false }
            let accept = lines.dropFirst().first { $0.lowercased().hasPrefix("sec-websocket-accept:") }
            return accept.map { $0.dropFirst("sec-websocket-accept:".count).trimmingCharacters(in: .whitespaces) }
                == WebSocket.accept(for: key)
        }
    }
}
