import Foundation
import os

/// Observes the daemon that owns the user's sessions, over its local socket (`CodexControlSocket`). All requests are
/// reads. Embedded CLI sessions can report their turn outcome through their own rollout instead.
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

    /// Everything the daemon announces that Jambul doesn't read. It only needs status changes and finished turns, and
    /// the busiest announcements carry whole outputs.
    static let ignoredNotifications = [
        "item/started", "item/completed", "item/agentMessage/delta", "item/plan/delta",
        "item/commandExecution/outputDelta", "item/commandExecution/terminalInteraction", "item/fileChange/outputDelta",
        "item/fileChange/patchUpdated", "item/mcpToolCall/progress", "item/reasoning/textDelta",
        "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded", "item/autoApprovalReview/started",
        "item/autoApprovalReview/completed", "command/exec/outputDelta", "process/outputDelta", "fs/changed",
        "turn/started", "turn/diff/updated", "turn/plan/updated", "thread/tokenUsage/updated", "thread/search/partial",
        "hook/started", "hook/completed", "account/rateLimits/updated", "mcpServer/event/stream/notification",
        "thread/realtime/transcript/delta", "thread/realtime/item/transcript/delta", "thread/realtime/outputAudio/delta",
    ]

    private let home: URL
    private let queue = DispatchQueue(label: "com.debikurnia.Jambul.codex-daemon")
    private var watcher: FolderWatcher?
    private var watched: [String: Watched] = [:]
    private var logReads: Set<UUID> = []
    private var enabled = false
    private var connectionTask: Task<Void, Never>?
    /// Tells the connection open now from one closed before it.
    private var connectionID: UUID?
    private var connection: CodexControlConnection?
    private var ready = false
    private var lastAttempt: ContinuousClock.Instant?
    private var nextRequest = 1
    private var reads: [Int: Read] = [:]

    init(home: URL = CodexSessionSource.home) {
        self.home = home
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
        disconnect()
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
            disconnectIfIdle()
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
        // Work going on past a request asks the daemon again, in case it didn't announce the answer.
        let waited = current.runtime == .approval || current.runtime == .question
        if ready, previous?.generation != current.generation || hook.kind == .finishing && current.runtime == nil
            || waited && hook.kind == .working {
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
        guard connectionID == nil, hasWorkToWatch, lastAttempt.map({ $0.duration(to: .now) >= .seconds(3) }) ?? true
        else { return }
        let path = home.appending(path: "app-server-control/app-server-control.sock").path
        guard FileManager.default.fileExists(atPath: path) else { return }
        lastAttempt = .now
        connect(to: path)
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

    private func connect(to path: String) {
        guard let connection = CodexControlConnection(path: path, queue: queue) else { return }
        let id = UUID()
        connectionID = id
        self.connection = connection
        connectionTask = Task { [weak self] in
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, connectionID == id, !ready else { return }
                connection.close()
            }
            defer {
                deadline.cancel()
                connection.close()
                if self?.connectionID == id { self?.disconnect() }
            }
            for await event in connection.events {
                guard !Task.isCancelled, let self, connectionID == id else { return }
                switch event {
                case .upgraded:
                    send(["id": 0, "method": "initialize",
                          "params": ["clientInfo": ["name": "jambul_sessions", "title": "Jambul", "version": "1"],
                                     "capabilities": ["optOutNotificationMethods": Self.ignoredNotifications]]])
                case .message(let data):
                    if let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        receive(message)
                    }
                case .ping, .closed:
                    // Answered and handled where the connection reads.
                    break
                }
                // What it received can have closed the connection.
                guard connectionID == id else { return }
            }
        }
    }

    private func disconnect() {
        connectionID = nil
        connection?.close()
        connection = nil
        connectionTask?.cancel()
        connectionTask = nil
        reads.removeAll()
        let wasReady = ready
        ready = false
        if wasReady {
            Logger.activities.notice("agent: codex daemon disconnected")
            onConnectionChange?(false)
        }
        for (id, session) in watched where session.runtime != nil && session.runtime != .idle {
            watched[id]?.runtime = nil
            update(.unavailable, from: session)
        }
    }

    private var hasWorkToWatch: Bool {
        watched.values.contains { $0.hook.kind != .opened && $0.runtime != .idle }
    }

    /// A session gone idle waits for how its turn ended, which only a read can say.
    private var awaitsOutcome: Bool {
        reads.values.contains {
            guard case .outcome(let id, let generation) = $0 else { return false }
            return watched[id]?.generation == generation
        }
    }

    private func disconnectIfIdle() {
        if connectionID != nil, !hasWorkToWatch, !awaitsOutcome {
            disconnect()
            // The next turn can connect immediately.
            lastAttempt = nil
        }
    }

    private func send(_ message: [String: Any]) {
        guard let connection, let data = try? JSONSerialization.data(withJSONObject: message,
                                                                    options: .withoutEscapingSlashes) else { return }
        connection.send(data)
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
                Logger.activities.notice("agent: codex daemon connected")
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
            guard let session = watched[id], session.generation == generation,
                  session.runtime == nil || session.runtime == .approval || session.runtime == .question,
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
                disconnectIfIdle()
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
                disconnectIfIdle()
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
        disconnectIfIdle()
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
            disconnectIfIdle()
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
