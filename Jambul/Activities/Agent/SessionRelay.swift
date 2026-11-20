import Darwin
import Foundation

/// Hook commands use a stable path, so moving the app doesn't change a trusted Codex hook.
struct SessionRelay {
    let executable: URL
    let socketPath: String

    static let marker = "JAMBUL_SESSION=1;"
    static let flag = "--relay-session"
    static let internalRun = "JAMBUL_USAGE_REPORT"

    func pointToApp(_ app: URL) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: executable.path)) == app.path { return }
        let temporary = executable.deletingLastPathComponent().appending(path: UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: app)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Never replace a regular file or directory at our private relay path.
        if FileManager.default.fileExists(atPath: executable.path),
           (try? FileManager.default.destinationOfSymbolicLink(atPath: executable.path)) == nil {
            throw POSIXError(.EEXIST)
        }
        guard rename(temporary.path, executable.path) == 0 else { throw POSIXError(.EIO) }
    }

    func hook(provider: UsageProvider, event: String) -> String {
        let output = provider == .antigravity && event == "Stop" ? #"{"decision":"stop"}"# : "{}"
        // Duplicate stdin to fd 3 before starting a background command: sh gives background commands /dev/null.
        return Self.marker + " if " + canSend + "; then { " + command(provider: provider, event: event)
            + " <&3 >/dev/null 2>&1 & } 3<&0; fi; printf '%s\n' " + Self.quote(output)
    }

    func statusLine(wrapping owner: String?) -> String {
        // The sentinel keeps all input bytes, including trailing newlines, when capturing the input for both commands.
        let buffer = #" IN=$(/bin/cat; printf '.'); IN=${IN%.}; "#
        let input = #"printf '%s' "$IN" | "#
        let ownerCommand = owner.map { "/bin/sh -c " + Self.quote($0) }
        let forward = input + command(provider: .antigravity, event: "statusLine") + " >/dev/null 2>&1 & "
        let render = ownerCommand.map { input + $0 } ?? ":"
        return Self.marker + " if " + canSend + "; then" + buffer + forward + render
            + "; else " + (ownerCommand.map { "exec " + $0 } ?? ":") + "; fi"
    }

    private var canSend: String {
        #"[ "${JAMBUL_USAGE_REPORT:-}" != 1 ] && [ -S "#
            + Self.quote(socketPath) + " ] && [ -x " + Self.quote(executable.path) + " ]"
    }

    private func command(provider: UsageProvider, event: String) -> String {
        [executable.path, Self.flag, provider.rawValue, event, socketPath].map(Self.quote).joined(separator: " ")
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Runs before AppKit starts when the same executable is invoked by a hook.
    static func send(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard arguments.count == 3, environment[internalRun] != "1",
              let provider = UsageProvider(rawValue: arguments[0]) else { return }
        let date = Date.now
        let inputLimit = 2 * 1024 * 1024
        var data = Data()
        do {
            while data.count <= inputLimit,
                  let chunk = try FileHandle.standardInput.read(upToCount: min(16 * 1024, inputLimit + 1 - data.count)),
                  !chunk.isEmpty {
                data.append(chunk)
            }
        } catch { return }
        guard data.count <= inputLimit, let update = AgentSessionUpdate.fromCLI(data, provider: provider, event: arguments[1],
                  terminal: environment["__CFBundleIdentifier"].flatMap { $0.isEmpty ? nil : $0 }, date: date),
              let payload = update.socketData else { return }
        send(payload, to: arguments[2])
    }

    private static func send(_ data: Data, to path: String) {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let sent = write(descriptor, start.advanced(by: offset), buffer.count - offset)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }
}
