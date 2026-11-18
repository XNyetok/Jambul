import Foundation

/// Asks Codex for the account's limits and follows local sessions as they write new readings.
@MainActor
final class CodexUsageSource {
    nonisolated static let refreshInterval: Duration = .seconds(60)
    private nonisolated static let tailLength = 256 * 1024
    nonisolated static var sessionsFolder: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { path in
            path.isEmpty ? nil : URL(filePath: path)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        return home.appending(path: "sessions", directoryHint: .isDirectory)
    }

    var onReading: (@MainActor (UsageReading) -> Void)?
    var onProblem: (@MainActor (String) -> Void)?
    private let folder: URL
    private let findCodex: @MainActor () -> URL?
    private let whenOnline: @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void
    private var session: UUID?
    private var watcher: FolderWatcher?
    private var refreshTask: Task<Void, Never>?
    private var lastAttempt: ContinuousClock.Instant?
    private var forgetRetry: (@MainActor () -> Void)?

    init(sessionsFolder: URL = CodexUsageSource.sessionsFolder,
         findCodex: @escaping @MainActor () -> URL? = CodexAccountUsage.findCodex,
         whenOnline: @escaping @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void = OnlineWait.start) {
        folder = sessionsFolder
        self.findCodex = findCodex
        self.whenOnline = whenOnline
    }

    func start() {
        guard session == nil else { return }
        session = UUID()
        refresh()
    }

    func stop() {
        session = nil
        watcher?.stop()
        watcher = nil
        refreshTask?.cancel()
        refreshTask = nil
        lastAttempt = nil
        forgetRetry?()
        forgetRetry = nil
    }

    func refresh(ifOlderThan age: Duration = CodexUsageSource.refreshInterval) {
        refresh(ifOlderThan: age, retrying: false)
    }

    private func refresh(ifOlderThan age: Duration, retrying: Bool) {
        guard let session else { return }
        // Codex may create its sessions folder after Jambul starts.
        if watcher == nil {
            watcher = FolderWatcher(folder: folder, latency: 2) { [weak self] paths in
                self?.readChanges(paths, session: session)
            }
        }
        guard refreshTask == nil, lastAttempt.map({ $0.duration(to: .now) >= age }) ?? true else { return }
        forgetRetry?()
        forgetRetry = nil
        lastAttempt = .now
        let codex = findCodex()
        refreshTask = Task { [weak self, folder] in
            let windows: [UsageWindow]?
            if let codex { windows = await CodexAccountUsage.read(codex) } else { windows = nil }
            guard !Task.isCancelled else { return }
            let fallback = windows == nil ? await Self.readLogs(in: folder) : nil
            guard let self, self.session == session else { return }
            refreshTask = nil
            if let windows {
                onReading?(UsageReading(provider: .codex, windows: windows, measuredAt: .now))
                return
            }
            if let fallback { onReading?(fallback) }
            onProblem?(codex == nil ? String(localized: "Codex CLI not found") : String(localized: "Couldn’t refresh"))
            guard codex != nil, !retrying else { return }
            forgetRetry = whenOnline { [weak self] in
                guard let self, self.session == session else { return }
                self.refresh(ifOlderThan: .zero, retrying: true)
            }
        }
    }

    private func readChanges(_ paths: [String], session: UUID) {
        guard self.session == session else { return }
        let logs = paths.filter { $0.hasSuffix(".jsonl") }.map { URL(filePath: $0) }
        guard !logs.isEmpty else { return }
        Task { [weak self, folder] in
            guard let reading = await Self.readLogs(in: folder, changed: logs),
                  let self, self.session == session else { return }
            onReading?(reading)
        }
    }

    private nonisolated static func readLogs(in folder: URL, changed: [URL]? = nil) async -> UsageReading? {
        await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
            let logs = changed ?? (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))?
                .allObjects as? [URL] ?? [])
            let byModification = logs.compactMap { url -> (url: URL, modified: Date)? in
                guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, let modified = values.contentModificationDate else { return nil }
                return (url, modified)
            }.sorted { $0.modified > $1.modified }
            var latest: UsageReading?
            for (url, modified) in byModification {
                // Codex timestamps each event before appending it to the file.
                if let latest, modified < latest.measuredAt { break }
                if let reading = try? readLog(url, modifiedAt: modified),
                   latest.map({ reading.measuredAt > $0.measuredAt }) ?? true {
                    latest = reading
                }
            }
            return latest
        }.value
    }

    private nonisolated static func readLog(_ url: URL, modifiedAt: Date) throws -> UsageReading? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size - min(size, UInt64(tailLength)))
        guard let data = try handle.read(upToCount: tailLength) else { return nil }
        return UsageParsing.codexReading(fromSessionLog: String(decoding: data, as: UTF8.self), modifiedAt: modifiedAt)
    }
}

/// Codex's JSONL App Server protocol. One usage request per process, using the CLI's existing sign-in.
enum CodexAccountUsage {
    private static let binFolders = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        .map { ($0 as NSString).expandingTildeInPath }
    private static let request = Data(("{\"method\":\"initialized\"}\n"
        + "{\"id\":2,\"method\":\"account/rateLimits/read\"}\n").utf8)

    static func findCodex() -> URL? {
        binFolders.map { URL(filePath: $0).appending(path: "codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func read(_ codex: URL, timeout: Duration = .seconds(10)) async -> [UsageWindow]? {
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = codex
        process.arguments = ["app-server", "-c", "analytics.enabled=false"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        let systemPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (binFolders + [systemPath]).joined(separator: ":")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let writer = input.fileHandleForWriting
        // A CLI that exits during startup can close its end of the pipe before the first write.
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1,
              (try? process.run()) != nil else { return nil }
        let running = RunningProcess(process)
        let reader = output.fileHandleForReading
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { continuation.finish() } else { continuation.yield(data) }
        }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            continuation.finish()
        }
        defer {
            deadline.cancel()
            reader.readabilityHandler = nil
            try? writer.close()
            running.stop()
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let client = ["name": "jambul", "title": "Jambul", "version": version]
        do {
            var initialize = try JSONSerialization.data(withJSONObject: [
                "id": 1, "method": "initialize", "params": ["clientInfo": client],
            ])
            initialize.append(0x0A)
            try writer.write(contentsOf: initialize)
            var buffer = Data()
            for await chunk in chunks {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let id = reply["id"] as? Int else { continue }
                    if id == 1 {
                        guard reply["result"] != nil else { return nil }
                        try writer.write(contentsOf: request)
                    } else if id == 2 {
                        guard let result = reply["result"] as? [String: Any] else { return nil }
                        return UsageParsing.codexWindows(fromAccountReport: result)
                    }
                }
                guard buffer.count <= 1 << 20 else { return nil }
            }
        } catch {
            return nil
        }
        return nil
    }
}
