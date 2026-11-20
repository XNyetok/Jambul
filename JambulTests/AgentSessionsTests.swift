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
        #expect(peeks.first?.motion == .draw)
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

    @Test func codexProxyUsesTheOwningDaemonsStatusAndResult() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rendezvous = folder.appending(path: "app-server-control/app-server-control.sock")
        try FileManager.default.createDirectory(at: rendezvous.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: rendezvous)
        let codex = folder.appending(path: "codex")
        let script = #"""
            #!/bin/sh
            while IFS= read -r line; do
                case "$line" in
                    *'"initialize"'*) printf '%s\n' '{"id":0,"result":{}}' ;;
                    *'"thread/read"'*)
                        printf '%s\n' '{"id":1,"result":{"thread":{"status":{"type":"active","activeFlags":[]}}}}'
                        printf '%s\n' '{"method":"thread/status/changed","params":{"threadId":"same","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}'
                        printf '%s\n' '{"method":"thread/status/changed","params":{"threadId":"same","status":{"type":"active","activeFlags":[]}}}'
                        printf '%s\n' '{"method":"thread/status/changed","params":{"threadId":"same","status":{"type":"active","activeFlags":["waitingOnUserInput"]}}}'
                        printf '%s\n' '{"method":"thread/status/changed","params":{"threadId":"same","status":{"type":"idle"}}}'
                        ;;
                    *'"thread/turns/list"'*) printf '%s\n' '{"id":2,"result":{"data":[{"id":"t1","status":"completed"}]}}' ;;
                    *'"initialized"'*) ;;
                    *) exit 3 ;;
                esac
            done
            """#
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        let source = CodexSessionSource(home: folder, findCodex: { codex })
        defer { source.stop() }
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
    }

    private func update(_ provider: UsageProvider, _ kind: AgentSessionUpdate.Kind, turn: String? = nil,
                        snapshot: Bool = false) -> AgentSessionUpdate {
        AgentSessionUpdate(provider: provider, session: "same", kind: kind, turn: turn, project: "Jambul", isSnapshot: snapshot)
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
