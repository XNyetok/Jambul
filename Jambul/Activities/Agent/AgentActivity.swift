import AppKit
import os
import SwiftUI

/// A Claude Code session, as its hooks tell it.
struct AgentSession: Equatable, Identifiable {
    enum State: Equatable {
        /// Started, with no turn yet.
        case ready
        case working
        /// Waiting on the owner: for permission to run a tool, or to answer a question.
        case needsYou(isQuestion: Bool)
        case done
        /// The turn ended on an error.
        case failed
        /// The turn was stopped with Esc, or the session waits for a prompt without having said why.
        case stopped
    }

    let id: String
    var project: String
    var terminal: String?
    var transcriptPath: String?
    var state: State = .ready
    /// When it came to its state, like how long it has waited on the owner.
    var stateSince: Date
    var turnStartedAt: Date?
    var turnEndedAt: Date?
    var lastEventAt: Date
    /// What it is doing now, like "Running the tests".
    var step: String?
    /// The first line of its last reply, or what went wrong.
    var reply: String?
    var editedFiles: Set<String> = []
    var commands = 0
    /// What it asked the owner about, while it waits on them.
    var request: AgentRequest?

    /// Working, or waiting on the owner in the middle of a turn.
    var isActive: Bool {
        switch state {
        case .working, .needsYou: true
        default: false
        }
    }

    var needsYou: Bool {
        if case .needsYou = state { return true }
        return false
    }

    /// Lower first: what needs the owner, what works, then how turns ended.
    var urgency: Int {
        switch state {
        case .needsYou: 0
        case .working: 1
        case .failed: 2
        case .done: 3
        case .stopped: 4
        case .ready: 5
        }
    }

    /// "3 files · 5 commands", or nil when the turn changed and ran nothing.
    var workSummary: String? {
        var parts: [String] = []
        if editedFiles.count == 1 { parts.append(String(localized: "1 file")) }
        if editedFiles.count > 1 { parts.append(String(localized: "\(editedFiles.count) files")) }
        if commands == 1 { parts.append(String(localized: "1 command")) }
        if commands > 1 { parts.append(String(localized: "\(commands) commands")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Claude Code's sessions: which work, which wait on the owner, and how their turns ended. Their hooks tell it
/// (`AgentHookInstaller`), so nothing here checks anything while a session is quiet, with one exception: Claude Code
/// runs no hook when a turn is stopped with Esc, so a session that falls quiet mid-turn has its transcript read once a
/// minute later, and then every few minutes for as long as it stays quiet, to see whether it was stopped.
@MainActor
@Observable
final class AgentActivity: IslandActivity {
    /// How long a turn must last for "Done" to show while its terminal is in front: shorter, the owner was watching.
    static let watchedTurn: TimeInterval = 60
    /// A session quiet in its hooks and its transcript this long is no longer working: Claude Code's commands time out
    /// well before.
    static let staleAfter: TimeInterval = 20 * 60
    /// A session waiting on the owner this long, with nothing in its hooks or its transcript, has gone, like a terminal
    /// closed with a question open. Until then it waits as long as the owner is away.
    static let waitingStaleAfter: TimeInterval = 3 * 3_600
    /// A session whose turn ended this long ago, with no hook since, is forgotten: its terminal was closed without
    /// Claude Code saying the session ended.
    static let forgetAfter: TimeInterval = 8 * 3_600

    let id = "agent"
    var title: String { String(localized: "Claude Code") }
    var tint: Color { UsageProvider.claude.brandColor }
    var tabSymbol: String { "chevron.left.forwardslash.chevron.right" }
    /// Its logo.
    var compactLeadingWidth: CGFloat { IslandLayout.compactGlyphHeight }
    /// The session beside the notch, whose circle the tab and the card on Home show: the logo travels to it.
    var compactGlyph: String? { liveSession.map(Self.glyph) }

    static func glyph(of session: AgentSession) -> String { "agent.\(session.id)" }
    var isLive: Bool { sessions.values.contains(where: \.isActive) }
    var priority: ActivityPriority { sessions.values.contains(where: \.needsYou) ? .high : .low }
    var showsHomeCard: Bool { isConnected && !shownSessions.isEmpty }

    private(set) var sessions: [String: AgentSession] = [:]
    /// Whether Jambul listens to Claude Code's hooks; the tab offers to connect them while it doesn't.
    var isConnected = false
    /// Something that went wrong connecting, for the tab.
    var problem: String?

    /// Asks for the hooks to be connected, from the tab.
    @ObservationIgnored var onConnect: (@MainActor () -> Void)?
    /// Called as the last working session finishes, for Keep Awake.
    @ObservationIgnored var onAllFinished: (@MainActor () -> Void)?

    /// Weak, since the center holds its activities.
    @ObservationIgnored private weak var activities: ActivityCenter?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let frontmostApp: @MainActor () -> String?
    @ObservationIgnored private let readTranscript: @Sendable (String) -> AgentTranscript?
    @ObservationIgnored private let quietCheck: Duration
    @ObservationIgnored private let quietRecheck: Duration
    @ObservationIgnored private var quietTasks: [String: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - now: The current time; tests pass their own clock.
    ///   - frontmostApp: The bundle identifier of the app in front.
    ///   - readTranscript: Reads the end of a session's transcript; tests pass their own.
    ///   - quietCheck: How long a session in a turn stays quiet before its transcript is read.
    ///   - quietRecheck: How often it is read again while the session stays quiet.
    init(activities: ActivityCenter, now: @escaping @MainActor () -> Date = { .now },
         frontmostApp: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         readTranscript: @escaping @Sendable (String) -> AgentTranscript? = AgentTranscript.read,
         quietCheck: Duration = .seconds(60), quietRecheck: Duration = .seconds(5 * 60)) {
        self.activities = activities
        self.now = now
        self.frontmostApp = frontmostApp
        self.readTranscript = readTranscript
        self.quietCheck = quietCheck
        self.quietRecheck = quietRecheck
    }

    /// The sessions worth showing, the most pressing first, then the most recent.
    var shownSessions: [AgentSession] {
        sessions.values.filter { $0.state != .ready }.sorted {
            $0.urgency != $1.urgency ? $0.urgency < $1.urgency : $0.lastEventAt > $1.lastEventAt
        }
    }

    /// The session beside the notch: the most pressing of those in a turn.
    var liveSession: AgentSession? {
        shownSessions.first(where: \.isActive)
    }

    /// Takes a hook's input from the socket.
    func receive(_ data: Data) {
        guard let event = AgentEvent.parse(data) else { return }
        receive(event)
    }

    func receive(_ event: AgentEvent) {
        let wasActive = isLive
        let date = now()
        forgetOldSessions(at: date)
        // Named once, by the folder it started in: `cd` in a command doesn't rename it.
        var session = sessions[event.session]
            ?? AgentSession(id: event.session, project: event.project ?? String(localized: "Claude Code"),
                            stateSince: date, lastEventAt: date)
        let before = session.state
        if let terminal = event.terminal { session.terminal = terminal }
        if let path = event.transcriptPath { session.transcriptPath = path }
        session.lastEventAt = date

        switch event.kind {
        case .sessionStart:
            break
        case .prompt:
            session.state = .working
            session.turnStartedAt = date
            session.turnEndedAt = nil
            session.step = nil
            session.reply = nil
            session.editedFiles = []
            session.commands = 0
        case .toolWillRun:
            if event.toolName == "AskUserQuestion" {
                session.state = .needsYou(isQuestion: true)
                session.request = AgentRequest(tool: event.toolName, summary: event.toolSummary, at: date)
            } else if session.needsYou, session.request?.isAbout(event, at: date) == true {
                // The hooks hand over on their own, so the one before a request can arrive after it: this is the call
                // still asking, not a new one.
                break
            } else {
                session.state = .working
            }
            session.step = event.toolSummary ?? session.step
        case .permission:
            session.state = .needsYou(isQuestion: false)
            session.request = AgentRequest(tool: event.toolName, summary: event.toolSummary, at: date)
            session.step = event.toolSummary ?? session.step
        case .notification(let type):
            switch type {
            case "permission_prompt":
                if !session.needsYou { session.state = .needsYou(isQuestion: false) }
            case "elicitation_dialog":
                if !session.needsYou { session.state = .needsYou(isQuestion: true) }
            case "idle_prompt":
                // Waiting for a prompt after a turn that said nothing, like one stopped with Esc. A question or a
                // permission still open keeps waiting.
                if session.state == .working { session.state = .stopped }
            default:
                break
            }
        case .toolRan:
            session.state = .working
            if let file = event.editedFile { session.editedFiles.insert(file) }
            if event.toolName == "Bash" { session.commands += 1 }
        case .stop:
            session.state = .done
            session.turnEndedAt = date
            session.reply = event.reply
        case .stopFailure:
            session.state = .failed
            session.turnEndedAt = date
            session.reply = event.error
        case .sessionEnd:
            end(event.session, wasActive: wasActive)
            return
        }
        // A turn can also start without a prompt, like when a background task the agent waits on ends.
        if session.isActive, !Self.isActive(before), event.kind != .prompt {
            session.turnStartedAt = date
            session.turnEndedAt = nil
            session.reply = nil
            session.editedFiles = []
            session.commands = 0
        }
        if !session.needsYou { session.request = nil }
        if before != session.state { session.stateSince = date }
        sessions[event.session] = session
        // Keep Awake hears first: its peek saying it turned off gives way to the one saying how the turn ended, which
        // matters more, while the eye leaving the notch still shows it.
        finishIfDone(wasActive: wasActive, turnEnded: !session.isActive && Self.isActive(before)
                     || event.kind == .stop || event.kind == .stopFailure)
        if before != session.state {
            Logger.activities.notice("agent: \(Self.logName(before), privacy: .public) → \(Self.logName(session.state), privacy: .public)")
            announce(session, after: before)
        }
        watchQuiet(session)
    }

    /// Forgets every session, for when the hooks are disconnected. Nothing finished, so Keep Awake isn't told so.
    func forgetSessions() {
        for task in quietTasks.values { task.cancel() }
        quietTasks = [:]
        sessions = [:]
        activities?.withdrawPeeks(from: id)
    }

    /// The owner brought an app forward. In the terminal of a session waiting on them they see the request, and
    /// probably answer it, which no hook tells: a peek about it still waiting would only repeat it.
    /// Only with one session waiting in that app: with more, the owner sees only one of them there.
    func appActivated(_ bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        let waiting = sessions.values.filter { $0.needsYou && $0.terminal == bundleIdentifier }
        guard waiting.count == 1, let session = waiting.first else { return }
        activities?.withdrawPeeks(from: id, topic: session.id)
    }

    /// Brings the app a session runs in forward.
    func openTerminal(for session: AgentSession) {
        let bundle = session.terminal ?? "com.apple.Terminal"
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// How long a turn took, like "28s", "1m 28s" or "1h 05m".
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(Int(seconds.rounded()), 0)
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        if minutes < 60 { return "\(minutes)m " + String(format: "%02ds", whole % 60) }
        return "\(minutes / 60)h " + String(format: "%02dm", minutes % 60)
    }

    /// How long a turn has run, in whole minutes rounded up, short enough for beside the notch: "1m", "12m", "1h05".
    static func runningFor(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.up)), 1)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h" + String(format: "%02d", minutes % 60)
    }

    // MARK: - Private

    private func end(_ id: String, wasActive: Bool) {
        if sessions[id]?.needsYou == true { activities?.withdrawPeeks(from: self.id, topic: id) }
        quietTasks.removeValue(forKey: id)?.cancel()
        sessions[id] = nil
        Logger.activities.notice("agent: session ended")
        finishIfDone(wasActive: wasActive, turnEnded: true)
    }

    /// Forgets sessions whose turn ended long ago, checked as hooks arrive rather than on a timer.
    private func forgetOldSessions(at date: Date) {
        for (id, session) in sessions where !session.isActive
            && date.timeIntervalSince(session.lastEventAt) >= Self.forgetAfter {
            sessions[id] = nil
        }
    }

    /// Tells the owner what changed, if it is worth a peek.
    private func announce(_ session: AgentSession, after before: AgentSession.State) {
        if case .needsYou = before, !session.needsYou {
            // Answered in the terminal: a peek still waiting would say something no longer true.
            activities?.withdrawPeeks(from: id, topic: session.id)
        }
        switch session.state {
        case .needsYou(let isQuestion):
            if case .needsYou = before { return }
            let title = isQuestion ? String(localized: "Asks you · \(session.project)")
                : String(localized: "Needs you · \(session.project)")
            activities?.peek(Peek(symbol: isQuestion ? "questionmark.bubble.fill" : "hand.raised.fill", tint: .yellow,
                                  title: title, subtitle: session.step, duration: .seconds(5), mustBeSeen: true,
                                  source: id, topic: session.id, motion: .pulse))
        case .done:
            // Behind another session's request, if one waits: its peek must be seen, so this one follows it.
            let took = session.turnStartedAt.map { now().timeIntervalSince($0) }
            let watched = session.terminal != nil && frontmostApp() == session.terminal
            if watched, let took, took < Self.watchedTurn { return }
            activities?.peek(Peek(symbol: "checkmark.circle.fill", tint: tint,
                                  title: String(localized: "Done · \(session.project)"),
                                  detail: took.map(Self.duration), subtitle: session.reply ?? session.workSummary,
                                  duration: .seconds(4), source: id, topic: session.id, motion: .draw))
        case .failed:
            activities?.peek(Peek(symbol: "exclamationmark.circle.fill", tint: .red,
                                  title: String(localized: "Stopped · \(session.project)"), subtitle: session.reply,
                                  duration: .seconds(4), mustBeSeen: true, source: id, topic: session.id,
                                  motion: .shake))
        default:
            break
        }
    }

    /// Tells Keep Awake once no session works any more: as the last one finishes, and also when a turn ends with none
    /// working that Jambul knew of, as after a relaunch, when it only hears of a session as its turn ends.
    private func finishIfDone(wasActive: Bool, turnEnded: Bool) {
        guard !isLive, wasActive || turnEnded else { return }
        onAllFinished?()
    }

    /// Reads the transcript of a session that fell quiet mid-turn, once it has been quiet for `quietCheck`, and again
    /// every `quietRecheck` while it stays quiet. Any hook starts the wait over.
    private func watchQuiet(_ session: AgentSession) {
        quietTasks.removeValue(forKey: session.id)?.cancel()
        guard session.isActive, let path = session.transcriptPath else { return }
        let id = session.id
        let quietCheck = quietCheck, quietRecheck = quietRecheck, readTranscript = readTranscript
        quietTasks[id] = Task { [weak self] in
            var wait = quietCheck
            while !Task.isCancelled {
                try? await Task.sleep(for: wait, tolerance: .seconds(1))
                guard !Task.isCancelled else { return }
                let transcript = await Task.detached { readTranscript(path) }.value
                guard !Task.isCancelled, let self else { return }
                if self.quietSessionStopped(id, transcript: transcript) { return }
                wait = quietRecheck
            }
        }
    }

    /// Whether a quiet session turned out to have stopped, which it then does.
    private func quietSessionStopped(_ id: String, transcript: AgentTranscript?) -> Bool {
        guard var session = sessions[id], session.isActive else { return true }
        let date = now()
        let limit = session.needsYou ? Self.waitingStaleAfter : Self.staleAfter
        let stale = date.timeIntervalSince(session.lastEventAt) >= limit
            && (transcript.map { date.timeIntervalSince($0.modified) >= limit } ?? true)
        guard transcript?.wasInterrupted == true || stale else { return false }
        let wasActive = isLive
        let before = session.state
        session.state = .stopped
        session.stateSince = date
        session.turnEndedAt = date
        session.request = nil
        sessions[id] = session
        quietTasks[id] = nil
        Logger.activities.notice("agent: \(Self.logName(before), privacy: .public) → stopped, \(stale ? "quiet" : "interrupted", privacy: .public)")
        finishIfDone(wasActive: wasActive, turnEnded: true)
        announce(session, after: before)
        return true
    }

    private static func isActive(_ state: AgentSession.State) -> Bool {
        switch state {
        case .working, .needsYou: true
        default: false
        }
    }

    private static func logName(_ state: AgentSession.State) -> String {
        switch state {
        case .ready: "ready"
        case .working: "working"
        case .needsYou(let isQuestion): isQuestion ? "asks you" : "needs you"
        case .done: "done"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }
}

/// What a session asked the owner, to tell the hook before the request, arriving late, from a new tool call. Claude
/// Code's permission request carries no `tool_use_id` (measured), so the tool and what it does stand in for it.
struct AgentRequest: Equatable {
    /// How long after a request a hook before it can still arrive: about 0.1 s apart as Claude Code sends them.
    static let lateBy: TimeInterval = 2

    var tool: String?
    var summary: String?
    var at: Date

    func isAbout(_ event: AgentEvent, at date: Date) -> Bool {
        event.toolName == tool && event.toolSummary == summary && date.timeIntervalSince(at) < Self.lateBy
    }
}

/// The end of a session's transcript: whether its last turn was stopped with Esc, and when it was last written.
struct AgentTranscript: Equatable, Sendable {
    var wasInterrupted: Bool
    var modified: Date

    /// How much of the end is read: enough for the last few entries.
    static let tailLength = 64 * 1024

    /// Reads the end of the transcript at `path`. Claude Code writes `interruptMarker` as the owner's own message when a
    /// turn is stopped with Esc; anything said after it means the session went on.
    @Sendable static func read(_ path: String) -> AgentTranscript? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(),
              let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        try? handle.seek(toOffset: size > UInt64(tailLength) ? size - UInt64(tailLength) : 0)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return AgentTranscript(wasInterrupted: lastTurnWasInterrupted(tail), modified: modified)
    }

    /// What Claude Code writes as the owner's message when a turn is stopped with Esc.
    static let interruptMarker = "[Request interrupted by user"

    /// Whether the last message from the owner or the agent in a transcript's tail is the one Claude Code writes for
    /// Esc. Only the owner's own text counts: the same words in what the agent wrote, in a tool's input or in what a
    /// tool returned, like this file read back, don't. A line cut off by the tail, or one that isn't a message, is
    /// passed over.
    static func lastTurnWasInterrupted(_ tail: String) -> Bool {
        for line in tail.split(separator: "\n").reversed() {
            guard line.contains(#""type":"user""#) || line.contains(#""type":"assistant""#),
                  let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant" else { continue }
            if type == "assistant" { return false }
            if entry["isMeta"] as? Bool == true { continue }
            let content = (entry["message"] as? [String: Any])?["content"]
            if let text = content as? String { return text.hasPrefix(interruptMarker) }
            guard let blocks = content as? [[String: Any]], let first = blocks.first,
                  first["type"] as? String == "text", let text = first["text"] as? String else { return false }
            return text.hasPrefix(interruptMarker)
        }
        return false
    }
}
