import CoreServices
import Foundation
import Network
import os

/// Watches a folder and everything in it through FSEvents, which macOS batches over `latency`; nothing polls.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.debikurnia.Jambul.folder-watcher")
    private let onChange: @MainActor ([String]) -> Void

    /// Nil when the folder isn't there to watch.
    init?(folder: URL, latency: TimeInterval, onChange: @escaping @MainActor ([String]) -> Void) {
        self.onChange = onChange
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        // The stream holds the watcher for as long as it may call back, so a callback in flight as `stop()` runs never
        // reaches a watcher that is gone.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FolderWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FolderWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            let onChange = watcher.onChange
            Task { @MainActor in onChange(changed) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Asks the Antigravity CLI for its usage report: `agy -p /usage --output-format json`, which sends no prompt to a
/// model (measured: about 6 s, 0.4 s of CPU). It runs in a folder of its own, with updates and browser sign-in turned
/// off, and is stopped if it takes too long.
///
/// It runs when the owner opens the Usage tab and the numbers are older than `staleAfter`, when the Mac wakes, and while
/// agy is in use: agy writes to its log as it works, at most once per `minimumGap`. A run that fails is tried once
/// more as soon as the Mac is online: right after login the network isn't up yet, and agy waits for a sign-in.
@MainActor
final class AntigravityUsageSource {
    nonisolated static let staleAfter: TimeInterval = 5 * 60
    nonisolated static let minimumGap: TimeInterval = 5 * 60
    nonisolated static let timeout: Duration = .seconds(30)
    /// Where agy may be: GUI apps don't get the shell's PATH.
    nonisolated static let candidatePaths = ["~/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
    nonisolated static var logFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gemini/antigravity-cli/log")
    }

    enum RunFailure: Error {
        case launch, timeout, exit(Int32)
    }

    var onReading: (@MainActor (UsageReading) -> Void)?
    var onProblem: (@MainActor (String) -> Void)?
    private(set) var lastRun: Date?
    private var running = false
    private var watcher: FolderWatcher?
    /// Whether Antigravity is turned on. The watcher can't tell: it is nil until agy has made its log folder.
    private var started = false
    private let logFolder: URL
    private let findAgy: @MainActor () -> URL?
    private let report: @Sendable (URL) async -> Result<Data, RunFailure>
    /// Calls back once the Mac is online, and returns a way to call that off.
    private let whenOnline: @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void
    private var forgetRetry: (@MainActor () -> Void)?

    init(logFolder: URL = AntigravityUsageSource.logFolder,
         findAgy: @escaping @MainActor () -> URL? = AntigravityUsageSource.findAgy,
         report: @escaping @Sendable (URL) async -> Result<Data, RunFailure> = AntigravityUsageSource.run,
         whenOnline: @escaping @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void = OnlineWait.start) {
        self.logFolder = logFolder
        self.findAgy = findAgy
        self.report = report
        self.whenOnline = whenOnline
    }

    func start() {
        started = true
        guard watcher == nil else { return }
        watcher = FolderWatcher(folder: logFolder, latency: 10) { [weak self] _ in
            self?.refresh(ifOlderThan: Self.minimumGap)
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        started = false
        forgetRetry?()
        forgetRetry = nil
    }

    /// Runs agy unless it is running already or ran within `age`.
    func refresh(ifOlderThan age: TimeInterval = AntigravityUsageSource.staleAfter) {
        guard !running, lastRun.map({ Date.now.timeIntervalSince($0) >= age }) ?? true else { return }
        run(retrying: false)
    }

    private func run(retrying: Bool) {
        // Whatever starts a run, a retry still waiting has nothing left to do.
        forgetRetry?()
        forgetRetry = nil
        guard let agy = findAgy() else {
            onProblem?(String(localized: "agy not found"))
            return
        }
        running = true
        lastRun = .now
        Task { [weak self, report] in
            let result = await report(agy)
            guard let self else { return }
            running = false
            switch result {
            case .success(let data):
                if let windows = UsageParsing.antigravityWindows(fromReport: data) {
                    onReading?(UsageReading(provider: .antigravity, windows: windows, measuredAt: .now))
                } else {
                    onProblem?(String(localized: "Sign in to agy"))
                }
            case .failure:
                onProblem?(String(localized: "agy didn’t answer"))
                // Once only, so an agy that never answers isn't run over and over.
                guard !retrying, started else { return }
                forgetRetry = whenOnline { [weak self] in
                    guard let self, !self.running else { return }
                    self.run(retrying: true)
                }
            }
        }
    }

    nonisolated static func findAgy() -> URL? {
        candidatePaths.map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs agy off the main thread and returns what it printed.
    nonisolated static func run(_ agy: URL) async -> Result<Data, RunFailure> {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let folder = fileManager.temporaryDirectory.appending(path: "jambul-agy")
            let bin = folder.appending(path: "bin")
            try? fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
            // Launchers that refuse, so a sign-in that has expired can't open a browser behind the owner's back.
            let refuse = Data("#!/bin/sh\nexit 1\n".utf8)
            for name in ["open", "xdg-open"] {
                let launcher = bin.appending(path: name)
                try? refuse.write(to: launcher)
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
            }
            let process = Process()
            process.executableURL = agy
            process.arguments = ["-p", "/usage", "--output-format", "json"]
            process.currentDirectoryURL = folder
            var environment = ProcessInfo.processInfo.environment
            environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
            environment["BROWSER"] = bin.appending(path: "open").path
            environment["PATH"] = [bin.path, agy.deletingLastPathComponent().path, "/usr/bin", "/bin", "/usr/sbin",
                                   "/sbin"].joined(separator: ":")
            process.environment = environment
            // Into a file rather than a pipe: a child agy leaves behind can't hold the reading open.
            let outputURL = folder.appending(path: "usage.json")
            fileManager.createFile(atPath: outputURL.path, contents: nil)
            guard let output = try? FileHandle(forWritingTo: outputURL) else { return .failure(.launch) }
            defer { try? output.close() }
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let running = RunningProcess(process)
            let exited: Void = await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume()
                    return
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    running.stop()
                }
            }
            _ = exited
            guard process.processIdentifier != 0 else { return .failure(.launch) }
            if process.terminationReason == .uncaughtSignal { return .failure(.timeout) }
            guard process.terminationStatus == 0 else { return .failure(.exit(process.terminationStatus)) }
            let data = (try? Data(contentsOf: outputURL)) ?? Data()
            return .success(data.prefix(1 << 20))
        }.value
    }
}

/// Waits for the Mac to have a network path, without polling: the system calls back as the path changes, and right
/// away with the path as it is.
enum OnlineWait {
    /// Calls `action` once, as soon as the Mac is online, and returns a way to call that off.
    @MainActor
    static func start(_ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                // The monitor is cancelled on the main actor only, so a second update can't run the action twice.
                guard monitor.pathUpdateHandler != nil else { return }
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                action()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.debikurnia.Jambul.online-wait"))
        return {
            monitor.pathUpdateHandler = nil
            monitor.cancel()
        }
    }
}

/// A process the timeout may stop from another task: asked to quit first, then killed if it hasn't after a moment.
private final class RunningProcess: @unchecked Sendable {
    static let killAfter: Duration = .seconds(2)
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        Task { [self] in
            try? await Task.sleep(for: Self.killAfter)
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Reads Codex's limits from its session logs, which Codex writes as it works, so nothing runs and nothing is asked
/// over the network. Each change to a log is read from its end.
@MainActor
final class CodexUsageSource {
    /// How much of the end of a log is read: enough for several events.
    nonisolated static let tailLength = 256 * 1024
    nonisolated static var sessionsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
    }

    var onReading: (@MainActor (UsageReading) -> Void)?
    private var watcher: FolderWatcher?

    func start() {
        guard watcher == nil else { return }
        watcher = FolderWatcher(folder: Self.sessionsFolder, latency: 2) { [weak self] paths in
            let logs = paths.filter { $0.hasSuffix(".jsonl") }
            guard !logs.isEmpty else { return }
            self?.read(logs.map { URL(filePath: $0) })
        }
        Task {
            if let newest = await Self.newestLog() { read([newest]) }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    private func read(_ logs: [URL]) {
        Task {
            guard let (windows, written) = await Self.windows(in: logs) else { return }
            // As of when Codex wrote them, so a log days old doesn't pass for fresh numbers.
            onReading?(UsageReading(provider: .codex, windows: windows, measuredAt: written))
        }
    }

    /// The limits in the most recently changed of `logs`, and when that log was written.
    private nonisolated static func windows(in logs: [URL]) async -> ([UsageWindow], Date)? {
        await Task.detached(priority: .utility) {
            let newest = logs.max { modified($0) < modified($1) }
            guard let newest, let handle = try? FileHandle(forReadingFrom: newest) else { return nil }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > UInt64(tailLength) ? size - UInt64(tailLength) : 0)
            guard let data = try? handle.readToEnd(),
                  let windows = UsageParsing.codexWindows(fromSessionLog: String(decoding: data, as: UTF8.self))
            else { return nil }
            return (windows, modified(newest))
        }.value
    }

    private nonisolated static func newestLog() async -> URL? {
        await Task.detached(priority: .utility) {
            let enumerator = FileManager.default.enumerator(at: sessionsFolder,
                                                            includingPropertiesForKeys: [.contentModificationDateKey])
            var newest: (url: URL, date: Date)?
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "jsonl" else { continue }
                let date = modified(url)
                if newest.map({ date > $0.date }) ?? true { newest = (url, date) }
            }
            return newest?.url
        }.value
    }

    private nonisolated static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
