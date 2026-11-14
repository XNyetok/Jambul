import Foundation
import Testing
@testable import Jambul

@MainActor
private final class AgentClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var frontmost: String?
}

@MainActor
private final class AgentInbox {
    var peeks: [Peek] = []
    var withdrawn = 0
    var withdrawnTopics: [String?] = []
    var finished = 0
}

/// A transcript the tests write as they like.
private final class FakeTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentTranscript?
    private var readCount = 0

    var current: AgentTranscript? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    var reads: Int { lock.withLock { readCount } }

    func read(_ path: String) -> AgentTranscript? {
        lock.withLock {
            readCount += 1
            return value
        }
    }
}

@MainActor
struct AgentActivityTests {
    private let activities = ActivityCenter()
    private let clock = AgentClock()
    private let inbox = AgentInbox()
    private let transcript = FakeTranscript()

    private func makeAgent(quietCheck: Duration = .seconds(60), quietRecheck: Duration = .seconds(300)) -> AgentActivity {
        activities.onPeek = { [inbox] in inbox.peeks.append($0) }
        activities.onWithdrawPeeks = { [inbox] _, topic in
            inbox.withdrawn += 1
            inbox.withdrawnTopics.append(topic)
        }
        let agent = AgentActivity(activities: activities, now: { [clock] in clock.now },
                                  frontmostApp: { [clock] in clock.frontmost },
                                  readTranscript: { [transcript] in transcript.read($0) },
                                  quietCheck: quietCheck, quietRecheck: quietRecheck)
        agent.onAllFinished = { [inbox] in inbox.finished += 1 }
        return agent
    }

    private func event(_ kind: AgentEvent.Kind, session: String = "s1", tool: String? = nil, call: String? = nil,
                       summary: String? = nil, file: String? = nil, reply: String? = nil,
                       cwd: String? = nil) -> AgentEvent {
        AgentEvent(kind: kind, session: session, cwd: cwd ?? "/tmp/work/\(session == "s1" ? "Jambul" : "Other")",
                   terminal: "com.apple.Terminal", transcriptPath: "/tmp/work/\(session).jsonl", toolName: tool,
                   toolUseID: call, toolSummary: summary, editedFile: file, reply: reply)
    }

    // MARK: States

    @Test func aPromptStartsATurnBesideTheNotch() {
        let agent = makeAgent()
        agent.receive(event(.sessionStart))
        #expect(!agent.isLive)
        #expect(agent.shownSessions.isEmpty)

        agent.receive(event(.prompt))
        #expect(agent.isLive)
        #expect(agent.priority == .low)
        #expect(agent.liveSession?.project == "Jambul")
        #expect(agent.liveSession?.turnStartedAt == clock.now)
    }

    @Test func askingForPermissionNeedsTheOwnerAndPeeksUntilSeen() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.toolWillRun, tool: "Bash", summary: "Run the unit tests"))
        agent.receive(event(.permission, tool: "Bash", summary: "Run the unit tests"))
        #expect(agent.liveSession?.state == .needsYou(isQuestion: false))
        #expect(agent.priority == .high)
        let peek = inbox.peeks.last
        #expect(peek?.title == "Needs you · Jambul")
        #expect(peek?.subtitle == "Run the unit tests")
        #expect(peek?.mustBeSeen == true)
        #expect(peek?.source == agent.id)

        // Claude Code also notifies about the same request: one peek is enough.
        agent.receive(event(.notification("permission_prompt")))
        #expect(inbox.peeks.count == 1)
    }

    /// Answered in the terminal, the request no longer needs the owner, so a peek about it still waiting is taken back.
    @Test func permissionGivenInTheTerminalTakesThePeekBack() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.permission, tool: "Bash"))
        #expect(inbox.withdrawn == 0)
        agent.receive(event(.toolRan(failed: false), tool: "Bash"))
        #expect(agent.liveSession?.state == .working)
        #expect(inbox.withdrawn == 1)
    }

    @Test func aQuestionAsksTheOwner() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.toolWillRun, tool: "AskUserQuestion", summary: "Asking you"))
        #expect(agent.liveSession?.state == .needsYou(isQuestion: true))
        #expect(inbox.peeks.last?.title == "Asks you · Jambul")
        agent.receive(event(.toolRan(failed: false), tool: "AskUserQuestion"))
        #expect(agent.liveSession?.state == .working)
    }

    @Test func aTurnCountsTheFilesItChangedAndTheCommandsItRan() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.toolRan(failed: false), tool: "Edit", file: "/tmp/work/Jambul/a.swift"))
        agent.receive(event(.toolRan(failed: false), tool: "Edit", file: "/tmp/work/Jambul/a.swift"))
        agent.receive(event(.toolRan(failed: false), tool: "Write", file: "/tmp/work/Jambul/b.swift"))
        agent.receive(event(.toolRan(failed: false), tool: "Bash"))
        agent.receive(event(.toolRan(failed: true), tool: "Bash"))
        agent.receive(event(.toolRan(failed: false), tool: "Read"))
        #expect(agent.liveSession?.workSummary == "2 files · 2 commands")
        agent.receive(event(.stop))
        agent.receive(event(.prompt))
        agent.receive(event(.toolRan(failed: false), tool: "Edit", file: "/tmp/work/Jambul/a.swift"))
        agent.receive(event(.toolRan(failed: false), tool: "Bash"))
        #expect(agent.liveSession?.workSummary == "1 file · 1 command")

        // The next turn counts from nothing.
        agent.receive(event(.stop))
        agent.receive(event(.prompt))
        #expect(agent.liveSession?.workSummary == nil)
    }

    @Test func doneSaysHowLongTheTurnTookAndWhatTheAgentSaid() throws {
        let agent = makeAgent()
        clock.frontmost = "com.apple.Safari"
        agent.receive(event(.prompt))
        clock.now.addTimeInterval(88)
        agent.receive(event(.stop, reply: "Tests pass"))
        #expect(!agent.isLive)
        #expect(agent.shownSessions.first?.state == .done)
        let peek = try #require(inbox.peeks.last)
        #expect(peek.title == "Done · Jambul")
        #expect(peek.detail == "1m 28s")
        #expect(peek.subtitle == "Tests pass")
        // A check, as in the session's circle, popping in and drawing itself.
        #expect(peek.symbol == "checkmark.circle.fill")
        #expect(peek.motion == .draw)
        #expect(!peek.mustBeSeen)
    }

    /// The owner watching the terminal saw a short turn end; a long one they may have looked away from.
    @Test func doneStaysQuietForAShortTurnWatchedInItsTerminal() {
        let agent = makeAgent()
        clock.frontmost = "com.apple.Terminal"
        agent.receive(event(.prompt))
        clock.now.addTimeInterval(20)
        agent.receive(event(.stop))
        #expect(inbox.peeks.isEmpty)

        agent.receive(event(.prompt))
        clock.now.addTimeInterval(AgentActivity.watchedTurn + 1)
        agent.receive(event(.stop))
        #expect(inbox.peeks.count == 1)
    }

    /// Another session waiting on the owner doesn't keep a turn's end quiet: each session's peek is its own, and the
    /// island lines news up behind a request the owner must see.
    @Test func doneStillPeeksWhileAnotherSessionNeedsTheOwner() {
        let agent = makeAgent()
        clock.frontmost = "com.apple.Safari"
        agent.receive(event(.prompt, session: "s2"))
        agent.receive(event(.permission, session: "s2", tool: "Bash"))
        agent.receive(event(.prompt))
        agent.receive(event(.stop))
        #expect(inbox.peeks.map(\.title) == ["Needs you · Other", "Done · Jambul"])
    }

    @Test func aFailedTurnPeeksAndShakesItsHead() throws {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        var failure = event(.stopFailure)
        failure.error = "rate_limit"
        agent.receive(failure)
        #expect(agent.shownSessions.first?.state == .failed)
        let peek = try #require(inbox.peeks.last)
        #expect(peek.title == "Stopped · Jambul")
        #expect(peek.subtitle == "rate_limit")
        #expect(peek.symbol == "exclamationmark.circle.fill")
        #expect(peek.motion == .shake)
        #expect(peek.mustBeSeen)
    }

    @Test func waitingForAPromptStopsATurnThatSaidNothing() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.notification("idle_prompt")))
        #expect(agent.shownSessions.first?.state == .stopped)
        #expect(!agent.isLive)
    }

    /// A background task the agent waited on can start a turn without a prompt; it counts from then.
    @Test func aTurnWithoutAPromptCountsFromItsFirstHook() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.stop))
        clock.now.addTimeInterval(600)
        agent.receive(event(.toolWillRun, tool: "Bash"))
        #expect(agent.liveSession?.turnStartedAt == clock.now)
    }

    @Test func anEndedSessionIsForgotten() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.sessionEnd))
        #expect(agent.sessions.isEmpty)
        #expect(!agent.isLive)
    }

    @Test func sessionsShowTheMostPressingFirst() {
        let agent = makeAgent()
        agent.receive(event(.prompt, session: "done"))
        agent.receive(event(.stop, session: "done"))
        clock.now.addTimeInterval(1)
        agent.receive(event(.prompt, session: "working"))
        clock.now.addTimeInterval(1)
        agent.receive(event(.prompt, session: "waiting"))
        agent.receive(event(.permission, session: "waiting", tool: "Bash"))
        agent.receive(event(.sessionStart, session: "fresh"))
        #expect(agent.shownSessions.map(\.id) == ["waiting", "working", "done"])
        #expect(agent.liveSession?.id == "waiting")
    }

    /// Each session's news is its own: answering one session's request takes back only its peek.
    @Test func eachSessionsPeeksAreItsOwn() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.permission, tool: "Bash"))
        agent.receive(event(.prompt, session: "s2"))
        agent.receive(event(.permission, session: "s2", tool: "Bash"))
        #expect(inbox.peeks.map(\.topic) == ["s1", "s2"])
        agent.receive(event(.toolRan(failed: false), session: "s2", tool: "Bash"))
        #expect(inbox.withdrawnTopics == ["s2"])
        #expect(agent.liveSession?.id == "s1")
    }

    /// Each hook hands over on its own, so the one before a request can arrive after it; the request still waits.
    /// Claude Code's permission request has no tool call id (measured), so the tool and what it does tell them apart.
    @Test func aLateHandoverOfTheSameCallLeavesTheRequestWaiting() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.permission, tool: "Bash", summary: "Touch a file"))
        clock.now.addTimeInterval(0.2)
        agent.receive(event(.toolWillRun, tool: "Bash", call: "t1", summary: "Touch a file"))
        #expect(agent.liveSession?.needsYou == true)
        agent.receive(event(.toolRan(failed: false), tool: "Bash", call: "t1", summary: "Touch a file"))
        #expect(agent.liveSession?.state == .working)
    }

    /// A different call after a request, as when it was refused and the agent moved on, means it works again.
    @Test func aNewCallAfterARequestMeansItWorksAgain() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.permission, tool: "Bash", summary: "Touch a file"))
        agent.receive(event(.toolWillRun, tool: "Read", call: "t2", summary: "Reading a.swift"))
        #expect(agent.liveSession?.state == .working)
        agent.receive(event(.permission, tool: "Bash", summary: "Touch a file"))
        clock.now.addTimeInterval(AgentRequest.lateBy + 1)
        agent.receive(event(.toolWillRun, tool: "Bash", call: "t3", summary: "Touch a file"))
        #expect(agent.liveSession?.state == .working)
    }

    @Test func waitingForAPromptLeavesAnOpenQuestionWaiting() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.toolWillRun, tool: "AskUserQuestion", call: "q1"))
        agent.receive(event(.notification("idle_prompt")))
        #expect(agent.liveSession?.state == .needsYou(isQuestion: true))
    }

    /// The project is the folder the session started in, whatever folder a later hook reports.
    @Test func aSessionKeepsItsProjectName() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.toolRan(failed: false), tool: "Bash", cwd: "/tmp/work/Jambul/scripts"))
        #expect(agent.liveSession?.project == "Jambul")
    }

    /// In a session's terminal the owner sees its request, which they then answer without any hook saying so.
    @Test func bringingTheTerminalForwardTakesTheRequestsPeekBack() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.permission, tool: "Bash"))
        agent.appActivated("com.apple.Safari")
        #expect(inbox.withdrawn == 0)
        agent.appActivated("com.apple.Terminal")
        #expect(inbox.withdrawnTopics == ["s1"])
        // It still waits until a hook says otherwise.
        #expect(agent.liveSession?.needsYou == true)
    }

    /// With several sessions waiting in one terminal app, the owner sees only one of them there: none is taken back.
    @Test func bringingForwardATerminalWithSeveralRequestsTakesNoneBack() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.permission, tool: "Bash"))
        agent.receive(event(.prompt, session: "s2"))
        agent.receive(event(.permission, session: "s2", tool: "Bash"))
        agent.appActivated("com.apple.Terminal")
        #expect(inbox.withdrawn == 0)
    }

    @Test func sessionsWhoseTurnEndedLongAgoAreForgotten() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.stop))
        clock.now.addTimeInterval(AgentActivity.forgetAfter + 1)
        agent.receive(event(.prompt, session: "s2"))
        #expect(agent.sessions.keys.sorted() == ["s2"])
    }

    // MARK: Finishing, for Keep Awake

    /// After a relaunch Jambul may first hear of a session as its turn ends; with nothing else working, that finishes
    /// too.
    @Test func aTurnEndingWithNothingWorkingFinishesEvenUnheardOf() {
        let agent = makeAgent()
        // Just relaunched: the first Jambul hears of this session is its turn ending.
        agent.receive(event(.stop))
        #expect(inbox.finished == 1)
        // With another session still working, nothing has finished.
        agent.receive(event(.prompt, session: "s2"))
        agent.receive(event(.stop, session: "s3"))
        #expect(inbox.finished == 1)
    }

    /// Keep Awake hears first, so the peek about how the turn ended comes after its own and takes its place.
    @Test func keepAwakeHearsBeforeTheTurnIsAnnounced() {
        let agent = makeAgent()
        clock.frontmost = "com.apple.Safari"
        agent.onAllFinished = { [inbox, activities] in
            inbox.finished += 1
            activities.peek(Peek(symbol: "eye.slash.fill", tint: .cyan, title: "Keep Awake off", source: "keepAwake"))
        }
        agent.receive(event(.prompt))
        agent.receive(event(.stop))
        #expect(inbox.peeks.map(\.title) == ["Keep Awake off", "Done · Jambul"])
    }

    @Test func turningSessionsOffFinishesNothing() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.forgetSessions()
        #expect(inbox.finished == 0)
        #expect(!agent.isLive)
    }

    @Test func theLastSessionToFinishSaysSoOnce() {
        let agent = makeAgent()
        agent.receive(event(.prompt))
        agent.receive(event(.prompt, session: "s2"))
        agent.receive(event(.stop))
        #expect(inbox.finished == 0)
        agent.receive(event(.permission, session: "s2", tool: "Bash"))
        #expect(inbox.finished == 0)
        agent.receive(event(.sessionEnd, session: "s2"))
        #expect(inbox.finished == 1)
        agent.receive(event(.sessionStart, session: "s3"))
        #expect(inbox.finished == 1)
    }

    // MARK: Esc

    /// Claude Code runs no hook when a turn is stopped with Esc; the transcript says so.
    @Test func aTurnStoppedWithEscIsFoundInTheTranscript() async throws {
        let agent = makeAgent(quietCheck: .milliseconds(20), quietRecheck: .milliseconds(20))
        transcript.current = AgentTranscript(wasInterrupted: false, modified: clock.now)
        agent.receive(event(.prompt))
        try await waitUntil { transcript.reads >= 2 }
        #expect(agent.isLive)

        transcript.current = AgentTranscript(wasInterrupted: true, modified: clock.now)
        try await waitUntil { !agent.isLive }
        #expect(agent.shownSessions.first?.state == .stopped)
        #expect(inbox.finished == 1)
        // Then nothing more is read.
        let reads = transcript.reads
        try await Task.sleep(for: .milliseconds(100))
        #expect(transcript.reads == reads)
    }

    @Test func aSessionQuietForLongStopsWorking() async throws {
        let agent = makeAgent(quietCheck: .milliseconds(20), quietRecheck: .milliseconds(20))
        transcript.current = AgentTranscript(wasInterrupted: false, modified: clock.now)
        agent.receive(event(.prompt))
        clock.now.addTimeInterval(AgentActivity.staleAfter + 1)
        try await waitUntil { !agent.isLive }
        #expect(agent.shownSessions.first?.state == .stopped)
    }

    /// Waiting on the owner can take as long as they're away; only Esc ends it.
    @Test func aSessionWaitingOnTheOwnerNeverGoesStale() async throws {
        let agent = makeAgent(quietCheck: .milliseconds(20), quietRecheck: .milliseconds(20))
        transcript.current = AgentTranscript(wasInterrupted: false, modified: clock.now)
        agent.receive(event(.prompt))
        agent.receive(event(.permission, tool: "Bash"))
        clock.now.addTimeInterval(AgentActivity.staleAfter * 3)
        try await waitUntil { transcript.reads >= 3 }
        #expect(agent.liveSession?.needsYou == true)
    }

    /// A session waiting on the owner whose terminal went away, with nothing in its hooks or transcript for hours, stops
    /// waiting, and its transcript is read no more.
    @Test func aRequestNobodyCanAnswerAnyMoreEndsAfterHours() async throws {
        let agent = makeAgent(quietCheck: .milliseconds(20), quietRecheck: .milliseconds(20))
        transcript.current = AgentTranscript(wasInterrupted: false, modified: clock.now)
        agent.receive(event(.prompt))
        agent.receive(event(.permission, tool: "Bash"))
        clock.now.addTimeInterval(AgentActivity.waitingStaleAfter + 1)
        try await waitUntil { !agent.isLive }
        #expect(agent.shownSessions.first?.state == .stopped)
    }

    @Test func eachHookStartsTheQuietWaitOver() async throws {
        let agent = makeAgent(quietCheck: .milliseconds(300))
        agent.receive(event(.prompt))
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(100))
            agent.receive(event(.toolRan(failed: false), tool: "Read"))
        }
        #expect(transcript.reads == 0)
    }

    // MARK: Text

    @Test func durationsReadShort() {
        #expect(AgentActivity.duration(28) == "28s")
        #expect(AgentActivity.duration(88) == "1m 28s")
        #expect(AgentActivity.duration(3_900) == "1h 05m")
        #expect(AgentActivity.runningFor(5) == "1m")
        #expect(AgentActivity.runningFor(12 * 60) == "12m")
        #expect(AgentActivity.runningFor(65 * 60 + 1) == "1h06")
    }

    /// The same words in what the agent wrote, in a tool's input or in what a tool returned, aren't Esc.
    @Test func onlyTheOwnersOwnInterruptCounts() {
        let marker = AgentTranscript.interruptMarker + "]"
        let toolUse = #"{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"new_string":"\#(marker)"}}]}}"#
        let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"\#(marker)"}]}}"#
        let said = #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(marker)"}]}}"#
        let asText = #"{"type":"user","message":{"role":"user","content":"\#(marker)"}}"#
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"<system-reminder>"}}"#
        #expect(!AgentTranscript.lastTurnWasInterrupted(toolUse))
        #expect(!AgentTranscript.lastTurnWasInterrupted(toolResult))
        #expect(!AgentTranscript.lastTurnWasInterrupted(said))
        #expect(AgentTranscript.lastTurnWasInterrupted(asText))
        #expect(AgentTranscript.lastTurnWasInterrupted([asText, meta].joined(separator: "\n")))
        // A line the tail cut in half is passed over.
        #expect(!AgentTranscript.lastTurnWasInterrupted(String(asText.dropFirst(10))))
    }

    @Test func theTranscriptSaysWhetherTheLastTurnWasStopped() {
        let interrupted = #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        let reply = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Sure"}]}}"#
        let other = #"{"type":"api-request-blob","message":{}}"#
        #expect(AgentTranscript.lastTurnWasInterrupted([reply, interrupted, other].joined(separator: "\n")))
        #expect(!AgentTranscript.lastTurnWasInterrupted([interrupted, reply].joined(separator: "\n")))
        #expect(!AgentTranscript.lastTurnWasInterrupted(other))
    }
}
