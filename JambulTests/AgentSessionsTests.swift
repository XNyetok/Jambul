import Foundation
import Testing
@testable import Jambul

@MainActor
struct AgentSessionsTests {
    @Test func providersWithTheSameSessionIDKeepTheirOwnRequestsAndWork() {
        let center = ActivityCenter()
        let agent = AgentActivity(activities: center)
        var finished = 0
        var withdrawn: [String?] = []
        agent.onAllFinished = { finished += 1 }
        center.onWithdrawPeeks = { _, topic in withdrawn.append(topic) }
        agent.receive(AgentEvent(kind: .prompt, session: "same"))
        agent.receive(update(.codex, .approval, turn: "c1"))
        agent.receive(update(.antigravity, .approval))
        #expect(agent.activeCount == 3)
        #expect(agent.shownSessions.map(\.provider).contains(.claude))
        agent.receive(update(.antigravity, .working))
        #expect(withdrawn == ["antigravity:same"])
        #expect(agent.liveSession?.provider == .codex)
        agent.forgetSessions(from: .codex)
        #expect(agent.activeCount == 2)
        agent.receive(AgentEvent(kind: .sessionEnd, session: "same"))
        #expect(finished == 0)
        agent.receive(update(.antigravity, .interrupted))
        #expect(finished == 1)
    }

    @Test func anOldTurnCannotResolveTheCurrentRequest() {
        let agent = AgentActivity(activities: ActivityCenter())
        agent.receive(update(.codex, .prompted, turn: "old"))
        agent.receive(update(.codex, .prompted, turn: "new"))
        agent.receive(update(.codex, .approval, turn: "new"))
        agent.receive(update(.codex, .done, turn: "old"))
        #expect(agent.liveSession?.needsYou == true)
        #expect(agent.liveSession?.turn == "new")
    }

    @Test func nearlySimultaneousCompletionsShareOnePeek() async throws {
        let center = ActivityCenter()
        let agent = AgentActivity(activities: center, completionWindow: .milliseconds(30))
        var peeks: [Peek] = []
        center.onPeek = { peeks.append($0) }
        agent.receive(update(.codex, .prompted, turn: "c1"))
        agent.receive(update(.antigravity, .working))
        agent.receive(update(.codex, .done, turn: "c1"))
        agent.receive(update(.antigravity, .done))
        try await waitUntil { !peeks.isEmpty }
        #expect(peeks.map(\.title) == ["2 sessions finished"])
        #expect(peeks.first?.motion == .complete)
        // Both logos, in the order the sessions finished, and their project once.
        #expect(peeks.first?.logos.map(\.provider) == [.codex, .antigravity])
        #expect(peeks.first?.subtitle == "Jambul")
    }

    @Test func requestPeeksAwaitSystemNoticesAndDisappearWhenAnswered() async throws {
        let center = ActivityCenter()
        let agent = AgentActivity(activities: center)
        center.register(agent)
        let model = IslandModel(notch: NotchMetrics(size: CGSize(width: 179, height: 32), compactHeight: 33),
                                activities: center)
        let screen = SessionTestScreen()
        model.canBeSeen = { screen.isVisible }
        agent.receive(update(.codex, .approval))
        center.peek(Peek(symbol: "bell.fill", tint: .orange, title: "Timer done",
                         duration: .milliseconds(35), mustBeSeen: true, source: "timer", priority: .system))
        screen.isVisible = true
        model.visibilityMayHaveChanged()
        #expect(model.peek?.source == "timer")
        try await waitUntil { model.presentation == .peek && model.peek?.source == agent.id }
        agent.receive(update(.codex, .working))
        #expect(model.presentation != .peek)
    }

    @Test func openingKeepsTheOriginalSessionGlyphWhenAnotherAgentNeedsYou() throws {
        let center = ActivityCenter()
        let agent = AgentActivity(activities: center)
        center.register(agent)
        agent.receive(update(.codex, .working))
        let model = IslandModel(notch: NotchMetrics(size: CGSize(width: 179, height: 32), compactHeight: 33),
                                activities: center)
        model.clicked()
        let openingGlyph = try #require(model.sessionGlyphFlight?.glyph)
        agent.receive(update(.antigravity, .approval))
        #expect(agent.compactGlyph != openingGlyph)
        #expect(model.sessionGlyphFlight?.glyph == openingGlyph)
    }

    @Test func agyWaitsForIdleAndDoesNotTreatAContinuedStopAsDone() async throws {
        let source = AntigravitySessionSource(settle: .milliseconds(30))
        var states: [AgentSessionUpdate.Kind] = []
        source.onUpdate = { states.append($0.kind) }
        source.receive(update(.antigravity, .working, snapshot: true))
        source.receive(update(.antigravity, .done))
        source.receive(update(.antigravity, .working))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!states.contains(.done))
        source.receive(update(.antigravity, .done))
        source.receive(update(.antigravity, .idle, snapshot: true))
        source.receive(update(.antigravity, .idle, snapshot: true))
        try await waitUntil { states.contains(.done) }
        #expect(states.filter { $0 == .done }.count == 1)
    }

    @Test func agySignalsUseActualConfirmationAndBackgroundTaskState() throws {
        let date = Date.now
        let status = Data(#"{"conversation_id":"a","agent_state":"tool_use","tool_confirmation_pending":true,"email":"discard-this","cwd":"/tmp/Jambul"}"#.utf8)
        let update = try #require(AgentSessionUpdate.fromCLI(status, provider: .antigravity, event: "statusLine",
                                                            terminal: nil, date: date))
        #expect(update.kind == .approval)
        #expect(update.project == "Jambul")
        #expect(update.isSnapshot)
        let encoded = try #require(update.socketData)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("discard-this"))
        #expect(AgentSessionUpdate.fromSocket(encoded) == update)
        let working = Data(#"{"conversation_id":"a","agent_state":"idle","task_count":1}"#.utf8)
        #expect(AgentSessionUpdate.fromCLI(working, provider: .antigravity, event: "statusLine",
                                           terminal: nil, date: date)?.kind == .working)
        let ending = Data(#"{"conversationId":"a","terminationReason":"model_stop","fullyIdle":false}"#.utf8)
        #expect(AgentSessionUpdate.fromCLI(ending, provider: .antigravity, event: "Stop",
                                           terminal: nil, date: date) == nil)
    }

    @Test func codexRolloutUsesTheTurnMarkerAndIgnoresOtherTurnsAndPaths() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sessions = folder.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let log = sessions.appending(path: "rollout.jsonl")
        let contents = """
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"older"}}
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"current","error":{"message":"failure"}}}
            """
        try Data(contents.utf8).write(to: log)
        #expect(CodexSessionSource.outcome(at: log, within: sessions, turn: "older") == .done)
        #expect(CodexSessionSource.outcome(at: log, within: sessions, turn: "current") == .failed)
        #expect(CodexSessionSource.outcome(at: log, within: sessions, turn: "unrelated") == nil)
        #expect(CodexSessionSource.outcome(at: log, within: folder.appending(path: "other"), turn: "older") == nil)
    }

    /// The daemon speaks WebSocket over its socket. Jambul read it through `codex app-server proxy` in JSON lines
    /// before, which the daemon hung up on, so no status ever came from it.
    @Test func codexDaemonStatusAndResultArriveOverItsWebSocket() async throws {
        let folder = try temporaryFolder()
        let daemon = try FakeCodexDaemon(home: folder) { method, id in
            switch method {
            case "initialize": [#"{"id":0,"result":{}}"#]
            case "thread/read": [
                #"{"id":\#(id ?? -1),"result":{"thread":{"status":{"type":"active","activeFlags":[]}}}}"#,
                #"{"method":"thread/status/changed","params":{"threadId":"same","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}"#,
                #"{"method":"thread/status/changed","params":{"threadId":"same","status":{"type":"active","activeFlags":[]}}}"#,
                #"{"method":"thread/status/changed","params":{"threadId":"same","status":{"type":"active","activeFlags":["waitingOnUserInput"]}}}"#,
                #"{"method":"thread/status/changed","params":{"threadId":"same","status":{"type":"idle"}}}"#,
            ]
            case "thread/turns/list": [#"{"id":\#(id ?? -1),"result":{"data":[{"id":"t1","status":"completed"}]}}"#]
            default: []
            }
        }
        defer {
            daemon.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let source = CodexSessionSource(home: folder)
        defer { source.stop() }
        var connected: [Bool] = []
        source.onConnectionChange = { connected.append($0) }
        let center = ActivityCenter()
        let agent = AgentActivity(activities: center)
        center.register(agent)
        let island = IslandModel(notch: NotchMetrics(size: CGSize(width: 179, height: 32), compactHeight: 33),
                                 activities: center)
        var states: [AgentSessionUpdate.Kind] = []
        source.onUpdate = { update in
            agent.receive(update)
            switch update.kind {
            case .approval:
                #expect(agent.liveSession?.state == .needsYou(isQuestion: false))
                #expect(island.presentation == .peek)
                #expect(island.peek?.title == "Needs you · Codex · Jambul")
                #expect(island.peek?.symbol == "hand.raised.fill")
            case .question:
                #expect(agent.liveSession?.state == .needsYou(isQuestion: true))
                #expect(island.presentation == .peek)
                #expect(island.peek?.title == "Asks you · Codex · Jambul")
            case .working, .idle:
                #expect(island.presentation != .peek)
                #expect(agent.liveSession?.needsYou != true)
            default:
                break
            }
            states.append(update.kind)
        }
        source.start()
        source.receiveHook(update(.codex, .prompted, turn: "t1"))
        try await waitUntil { states.contains(.done) }
        #expect(states == [.prompted, .working, .approval, .working, .question, .idle, .done])
        #expect(daemon.methods == ["initialize", "initialized", "thread/read", "thread/turns/list"])
        #expect(connected == [true, false])
    }

    /// A daemon that doesn't switch to WebSocket leaves the hooks in charge: the turn works on, and nothing says its
    /// status went missing.
    @Test func codexHooksCarryOnWhenTheDaemonWontTalk() async throws {
        let folder = try temporaryFolder()
        let daemon = try FakeCodexDaemon(home: folder, answersUpgrade: false) { _, _ in [] }
        defer {
            daemon.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let source = CodexSessionSource(home: folder)
        defer { source.stop() }
        var states: [AgentSessionUpdate.Kind] = []
        source.onUpdate = { states.append($0.kind) }
        source.start()
        source.receiveHook(update(.codex, .prompted, turn: "t1"))
        source.receiveHook(update(.codex, .working, turn: "t1"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(states == [.prompted, .working])
        #expect(daemon.methods.isEmpty)
    }

    /// A daemon that doesn't announce an answered request to Jambul: work going on asks it again, rather than leaving
    /// "Needs you" up for the rest of the turn.
    @Test func codexAsksAgainWhenWorkGoesOnPastARequest() async throws {
        let folder = try temporaryFolder()
        let reads = ReadCount()
        let daemon = try FakeCodexDaemon(home: folder) { method, id in
            switch method {
            case "initialize": [#"{"id":0,"result":{}}"#]
            case "thread/read":
                [reads.next() == 1
                    ? #"{"id":\#(id ?? -1),"result":{"thread":{"status":{"type":"active","activeFlags":["waitingOnApproval"]}}}}"#
                    : #"{"id":\#(id ?? -1),"result":{"thread":{"status":{"type":"active","activeFlags":[]}}}}"#]
            default: []
            }
        }
        defer {
            daemon.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let source = CodexSessionSource(home: folder)
        defer { source.stop() }
        let agent = AgentActivity(activities: ActivityCenter())
        var states: [AgentSessionUpdate.Kind] = []
        source.onUpdate = {
            agent.receive($0)
            states.append($0.kind)
        }
        source.start()
        source.receiveHook(update(.codex, .prompted, turn: "t1"))
        try await waitUntil { agent.liveSession?.needsYou == true }
        // The model is called again: whatever was asked has been answered.
        source.receiveHook(update(.codex, .working, turn: "t1", at: .now.addingTimeInterval(1)))
        try await waitUntil { agent.liveSession?.state == .working }
        #expect(states == [.prompted, .approval, .working])
        #expect(daemon.methods == ["initialize", "initialized", "thread/read", "thread/read"])
    }

    /// A session gone idle keeps the connection until the daemon says how its turn ended, even when another session
    /// closes meanwhile and leaves nothing else to watch.
    @Test func codexWaitsForAnOutcomeOnItsWay() async throws {
        let folder = try temporaryFolder()
        let daemon = try FakeCodexDaemon(home: folder) { method, id in
            switch method {
            case "initialize": return [#"{"id":0,"result":{}}"#]
            case "thread/read": return [
                #"{"id":\#(id ?? -1),"result":{"thread":{"status":{"type":"active","activeFlags":[]}}}}"#,
                #"{"method":"thread/status/changed","params":{"threadId":"same","status":{"type":"idle"}}}"#,
            ]
            case "thread/turns/list":
                // Answered late, after the other session has closed.
                Thread.sleep(forTimeInterval: 0.3)
                return [#"{"id":\#(id ?? -1),"result":{"data":[{"id":"t1","status":"completed"}]}}"#]
            default: return []
            }
        }
        defer {
            daemon.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let source = CodexSessionSource(home: folder)
        defer { source.stop() }
        var updates: [AgentSessionUpdate] = []
        source.onUpdate = { updates.append($0) }
        source.start()
        source.receiveHook(update(.codex, .prompted, turn: "t1"))
        try await waitUntil { daemon.methods.contains("thread/turns/list") }
        // Another session starts and closes before the daemon has said how the first one's turn ended.
        source.receiveHook(AgentSessionUpdate(provider: .codex, session: "other", kind: .prompted, turn: "o1"))
        source.receiveHook(AgentSessionUpdate(provider: .codex, session: "other", kind: .closed, turn: "o1",
                                              date: .now.addingTimeInterval(1)))
        try await waitUntil { updates.contains { $0.session == "same" && $0.kind == .done } }
    }

    /// agy 1.5 names how its loop ended by its own reasons, like "NO_TOOL_CALL" for a turn the model finished. Read as
    /// the "model_stop" of older versions, every finished turn looked stopped, and "Done" never came.
    @Test func agyStopReasonsSayHowATurnEnded() throws {
        func ending(_ fields: String) -> AgentSessionUpdate.Kind? {
            let input = #"{"conversationId":"a","workspacePaths":["/tmp/Jambul"],"hookEventName":"Stop","fullyIdle":true,"#
                + fields + "}"
            return AgentSessionUpdate.fromCLI(Data(input.utf8), provider: .antigravity, event: "Stop", terminal: nil,
                                              date: .now)?.kind
        }
        #expect(ending(#""terminationReason":"NO_TOOL_CALL","error":"""#) == .done)
        #expect(ending(#""terminationReason":"TERMINAL_STEP_TYPE""#) == .done)
        #expect(ending(#""terminationReason":"model_stop""#) == .done)
        #expect(ending(#""terminationReason":"USER_CANCELED""#) == .interrupted)
        // Esc can come with the error of whatever it cut short: still stopped on purpose, not failed.
        #expect(ending(#""terminationReason":"USER_CANCELED","error":"context canceled""#) == .interrupted)
        #expect(ending(#""terminationReason":"ERROR","error":"quota exhausted""#) == .failed)
        #expect(ending(#""terminationReason":"MAX_INVOCATIONS""#) == .failed)
        #expect(ending(#""terminationReason":"NO_TOOL_CALL","error":"boom""#) == .failed)
        #expect(ending(#""continuationActive":false"#) == .interrupted)
    }

    /// From agy's own Stop hook to the peek: a finished turn says "Done".
    @Test func aFinishedAgyTurnPeeksDone() async throws {
        let center = ActivityCenter()
        let agent = AgentActivity(activities: center, frontmostApp: { nil }, completionWindow: .zero)
        var peeks: [Peek] = []
        center.onPeek = { peeks.append($0) }
        let source = AntigravitySessionSource(settle: .milliseconds(10))
        source.onUpdate = { agent.receive($0) }
        let started = Date.now
        func hook(_ event: String, _ fields: String) throws -> AgentSessionUpdate {
            let input = #"{"conversationId":"a","workspacePaths":["/tmp/Jambul"],"hookEventName":"\#(event)""#
                + fields + "}"
            return try #require(AgentSessionUpdate.fromCLI(Data(input.utf8), provider: .antigravity, event: event,
                                                           terminal: nil, date: started))
        }
        source.receive(try hook("PreInvocation", #","invocationNum":1"#))
        #expect(agent.liveSession?.state == .working)
        var stop = try hook("Stop", #","terminationReason":"NO_TOOL_CALL","fullyIdle":true"#)
        stop.date = started.addingTimeInterval(1)
        source.receive(stop)
        try await waitUntil { !peeks.isEmpty }
        #expect(agent.shownSessions.first?.state == .done)
        #expect(peeks.map(\.title) == ["Done · Jambul"])
        // agy hands over no reply, so the second line names the client, as the logo shows it.
        #expect(peeks.first?.subtitle == "Antigravity")
        #expect(peeks.first?.logos.map(\.provider) == [.antigravity])
    }

    private func update(_ provider: UsageProvider, _ kind: AgentSessionUpdate.Kind, turn: String? = nil,
                        snapshot: Bool = false, at date: Date = .now) -> AgentSessionUpdate {
        AgentSessionUpdate(provider: provider, session: "same", kind: kind, turn: turn, project: "Jambul",
                           isSnapshot: snapshot, date: date)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "JS-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

@MainActor
private final class SessionTestScreen {
    var isVisible = false
}

/// Counts reads on the fake daemon's own thread.
private final class ReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
