import Foundation

/// Observes the daemon that owns the user's sessions. The CLI proxy translates the local Unix WebSocket to JSONL.
/// All requests are reads. Embedded CLI sessions can report their turn outcome through their own rollout instead.
@MainActor
final class CodexSessionSource {
    private struct Watched {
        var hook: AgentSessionUpdate
        var generation = UUID()
        var runtime: AgentSessionUpdate.Kind?
    }

    private enum Read {
        case status(String, UUID)
        case outcome(String, UUID)
    }

    static var home: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], path.hasPrefix("/") {
            return URL(filePath: path)
        }
        return home.appending(path: ".codex")
    }

    var onUpdate: (@MainActor (AgentSessionUpdate) -> Void)?
    var onConnectionChange: (@MainActor (Bool) -> Void)?

    private let home: URL
    private let findCodex: () -> URL?
    private var watcher: FolderWatcher?
    private var watched: [String: Watched] = [:]
    private var logReads: Set<UUID> = []
    private var enabled = false
    private var proxyTask: Task<Void, Never>?
    private var proxy: UUID?
    private var writer: FileHandle?
    private var ready = false
    private var lastAttempt: ContinuousClock.Instant?
    private var nextRequest = 1
    private var reads: [Int: Read] = [:]

    init(home: URL = CodexSessionSource.home, findCodex: @escaping () -> URL? = CodexAccountUsage.findCodex) {
        self.home = home
        self.findCodex = findCodex
    }

    func start() {
        enabled = true
        refresh()
    }

    func stop() {
        enabled = false
        watcher?.stop()
        watcher = nil
        watched.removeAll()
        logReads.removeAll()
        lastAttempt = nil
        closeProxy()
    }

    func receiveHook(_ hook: AgentSessionUpdate) {
        guard enabled, hook.provider == .codex else { return }
        let id = hook.session
        let previous = watched[id]
        guard previous.map({ hook.date >= $0.hook.date }) ?? true else { return }
        if hook.kind == .closed || hook.kind == .interrupted {
            if let turn = hook.turn, let current = previous?.hook.turn, turn != current { return }
            watched.removeValue(forKey: id)
            onUpdate?(hook)
            closeIdleProxy()
            return
        }
        if hook.kind == .opened, previous != nil { return }
        if previous == nil {
            let oldest = hook.date.addingTimeInterval(-AgentActivity.forgetAfter)
            watched = watched.filter { $0.value.hook.date >= oldest }
        }
        if hook.kind == .finishing {
            guard previous?.hook.turn == nil || hook.turn == previous?.hook.turn else { return }
        }
        var current = previous ?? Watched(hook: hook)
        if hook.turn != nil, hook.turn != current.hook.turn {
            current = Watched(hook: hook)
        }
        if current.runtime == .idle, hook.kind != .finishing { current.runtime = nil }
        var update = hook
        update.turn = hook.turn ?? current.hook.turn
        update.transcriptPath = hook.transcriptPath ?? current.hook.transcriptPath
        current.hook = update
        watched[id] = current
        if hook.kind == .finishing {
            if previous == nil {
                onUpdate?(AgentSessionUpdate(provider: .codex, session: id, kind: .working, turn: update.turn,
                                             project: update.project, terminal: update.terminal, date: update.date))
            }
            checkLog(id)
        } else if current.runtime != .approval, current.runtime != .question {
            onUpdate?(update)
        }
        refresh()
        if ready, previous?.generation != current.generation || hook.kind == .finishing && current.runtime == nil {
            request(.status(id, current.generation))
        }
    }

    func refresh() {
        guard enabled else { return }
        if watcher == nil {
            watcher = FolderWatcher(folder: home, latency: 0.6) { [weak self] paths in
                self?.filesChanged(paths)
            }
        }
        guard proxy == nil, hasWorkToWatch, lastAttempt.map({ $0.duration(to: .now) >= .seconds(3) }) ?? true else { return }
        let path = home.appending(path: "app-server-control/app-server-control.sock").path
        guard FileManager.default.fileExists(atPath: path), let codex = findCodex() else { return }
        lastAttempt = .now
        startProxy(executable: codex, socket: path)
    }

    private func filesChanged(_ paths: [String]) {
        guard enabled else { return }
        refresh()
        let changed = Set(paths.lazy.filter { $0.hasSuffix(".jsonl") }
            .map { URL(filePath: $0).standardizedFileURL.path })
        let ids = watched.values.compactMap { session in
            guard let path = session.hook.transcriptPath, changed.contains(URL(filePath: path).standardizedFileURL.path)
            else { return nil as String? }
            return session.hook.session
        }
        for id in ids { checkLog(id) }
    }

    private func startProxy(executable: URL, socket: String) {
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "proxy", "--sock", socket]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let writer = input.fileHandleForWriting
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1,
              fcntl(writer.fileDescriptor, F_SETFL, O_NONBLOCK) != -1,
              (try? process.run()) != nil else { return }
        let token = UUID()
        proxy = token
        self.writer = writer
        let reader = output.fileHandleForReading
        let running = RunningProcess(process)
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(32))
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { continuation.finish() }
            else if case .dropped = continuation.yield(data) { continuation.finish() }
        }
        proxyTask = Task { [weak self] in
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, proxy == token, !ready else { return }
                continuation.finish()
            }
            defer {
                deadline.cancel()
                reader.readabilityHandler = nil
                try? writer.close()
                running.stop()
                if self?.proxy == token { self?.closeProxy() }
            }
            var buffer = Data()
            for await chunk in chunks {
                guard !Task.isCancelled, let self, proxy == token else { return }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        receive(message)
                    }
                }
                guard buffer.count <= 1 << 20 else { return }
            }
        }
        send(["id": 0, "method": "initialize",
              "params": ["clientInfo": ["name": "jambul_sessions", "title": "Jambul", "version": "1"],
                         "capabilities": ["optOutNotificationMethods": ["item/agentMessage/delta",
                             "item/commandExecution/outputDelta", "item/fileChange/outputDelta",
                             "item/reasoning/textDelta", "item/reasoning/summaryTextDelta", "turn/diff/updated"]]]])
    }

    private func closeProxy() {
        proxy = nil
        writer = nil
        proxyTask?.cancel()
        proxyTask = nil
        reads.removeAll()
        let wasReady = ready
        ready = false
        if wasReady { onConnectionChange?(false) }
        for (id, session) in watched where session.runtime != nil && session.runtime != .idle {
            watched[id]?.runtime = nil
            update(.unavailable, from: session)
        }
    }

    private var hasWorkToWatch: Bool {
        watched.values.contains { $0.hook.kind != .opened && $0.runtime != .idle }
    }

    private func closeIdleProxy() {
        if proxy != nil, !hasWorkToWatch {
            closeProxy()
            // The next turn can connect immediately.
            lastAttempt = nil
        }
    }

    private func send(_ message: [String: Any]) {
        guard let writer, var data = try? JSONSerialization.data(withJSONObject: message,
                                                               options: .withoutEscapingSlashes) else { return }
        data.append(0x0A)
        do { try writer.write(contentsOf: data) } catch { closeProxy() }
    }

    private func request(_ read: Read) {
        guard ready, reads.count < 32 else { return }
        let id = nextRequest
        nextRequest += 1
        reads[id] = read
        switch read {
        case .status(let thread, _):
            send(["id": id, "method": "thread/read", "params": ["threadId": thread, "includeTurns": false]])
        case .outcome(let thread, _):
            send(["id": id, "method": "thread/turns/list", "params": ["threadId": thread, "limit": 1,
                  "sortDirection": "desc", "itemsView": "notLoaded"]])
        }
    }

    private func receive(_ message: [String: Any]) {
        if let id = message["id"] as? Int {
            // Server requests also have ids. Only read replies carry a result or error.
            guard message["result"] != nil || message["error"] != nil else { return }
            let result = message["result"] as? [String: Any]
            if id == 0, !ready, result != nil {
                ready = true
                send(["method": "initialized"])
                guard ready else { return }
                onConnectionChange?(true)
                for (thread, session) in watched { request(.status(thread, session.generation)) }
            } else if let read = reads.removeValue(forKey: id) {
                receiveRead(read, result: result)
            }
            return
        }
        guard let params = message["params"] as? [String: Any], let id = params["threadId"] as? String,
              let session = watched[id] else { return }
        switch message["method"] as? String {
        case "thread/status/changed":
            if let status = params["status"] as? [String: Any] { receiveStatus(status, id: id, session: session) }
        case "turn/completed":
            if let turn = params["turn"] as? [String: Any] { receiveOutcome(turn, id: id, session: session) }
        default: break
        }
    }

    private func receiveRead(_ read: Read, result: [String: Any]?) {
        switch read {
        case .status(let id, let generation):
            guard let session = watched[id], session.generation == generation, session.runtime == nil,
                  let thread = result?["thread"] as? [String: Any],
                  let status = thread["status"] as? [String: Any] else { return }
            receiveStatus(status, id: id, session: session)
        case .outcome(let id, let generation):
            guard let session = watched[id], session.generation == generation, session.runtime == .idle else { return }
            if let turn = (result?["data"] as? [[String: Any]])?.first {
                receiveOutcome(turn, id: id, session: session)
            }
            if watched[id]?.generation == generation {
                update(.idle, from: session)
                checkLog(id)
                closeIdleProxy()
            }
        }
    }

    private func receiveStatus(_ status: [String: Any], id: String, session: Watched) {
        switch status["type"] as? String {
        case "active":
            let flags = (status["activeFlags"] as? [String]) ?? []
            let kind: AgentSessionUpdate.Kind = flags.contains("waitingOnUserInput") ? .question
                : flags.contains("waitingOnApproval") ? .approval : .working
            watched[id]?.runtime = kind
            update(kind, from: session)
        case "idle", "systemError":
            // An initial idle read can race a prompt. Wait for the daemon to have seen this turn active or the
            // hook to have reached Stop, then use the persisted outcome for this exact turn.
            guard session.runtime != .idle, session.runtime != nil || session.hook.kind == .finishing else { return }
            watched[id]?.runtime = .idle
            if session.runtime == .approval || session.runtime == .question { update(.idle, from: session) }
            request(.outcome(id, session.generation))
        case "notLoaded":
            if session.runtime != nil, session.runtime != .idle {
                watched[id]?.runtime = .idle
                update(.unavailable, from: session)
                checkLog(id)
                closeIdleProxy()
            }
        default: break
        }
    }

    private func receiveOutcome(_ turn: [String: Any], id: String, session: Watched) {
        guard let current = session.hook.turn, turn["id"] as? String == current,
              let status = turn["status"] as? String else { return }
        let kind: AgentSessionUpdate.Kind
        switch status {
        case "completed": kind = .done
        case "failed": kind = .failed
        case "interrupted": kind = .interrupted
        default: return
        }
        watched.removeValue(forKey: id)
        update(kind, from: session)
        closeIdleProxy()
    }

    private func checkLog(_ id: String) {
        guard let session = watched[id], let turn = session.hook.turn,
              let path = session.hook.transcriptPath, path.hasPrefix("/"),
              logReads.insert(session.generation).inserted else { return }
        let root = home.appending(path: "sessions")
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                Self.outcome(at: URL(filePath: path), within: root, turn: turn)
            }.value
            guard let self else { return }
            logReads.remove(session.generation)
            guard watched[id]?.generation == session.generation, let outcome else { return }
            watched.removeValue(forKey: id)
            update(outcome, from: session)
            closeIdleProxy()
        }
    }

    private func update(_ kind: AgentSessionUpdate.Kind, from session: Watched) {
        let hook = session.hook
        onUpdate?(AgentSessionUpdate(provider: .codex, session: hook.session, kind: kind, turn: hook.turn,
                                     project: hook.project, terminal: hook.terminal))
    }

    nonisolated static func outcome(at transcript: URL, within sessions: URL, turn: String) -> AgentSessionUpdate.Kind? {
        let file = transcript.resolvingSymlinksInPath()
        let root = sessions.resolvingSymlinksInPath().path
        guard file.path.hasPrefix(root + "/"), file.pathExtension == "jsonl",
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let limit = 128 * 1024
        let offset = size - min(size, UInt64(limit))
        guard (try? handle.seek(toOffset: offset)) != nil,
              let tail = try? handle.read(upToCount: limit) else { return nil }
        let lines = tail.split(separator: 0x0A)
        for line in lines.dropFirst(offset == 0 ? 0 : 1).reversed() {
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  event["type"] as? String == "event_msg", let payload = event["payload"] as? [String: Any],
                  payload["turn_id"] as? String == turn || payload["root_turn_id"] as? String == turn,
                  let type = payload["type"] as? String else { continue }
            let failed = payload["error"].map { !($0 is NSNull) } ?? false
            if type == "task_complete" || type == "turn_complete" { return failed ? .failed : .done }
            if type == "turn_aborted" { return failed ? .failed : .interrupted }
        }
        return nil
    }
}
