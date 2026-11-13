import SwiftUI

extension AgentActivity {
    /// Claude's logo, still.
    var compactLeading: some View {
        UsageLogo(provider: .claude, size: IslandLayout.compactGlyphHeight)
    }

    /// How long the turn has run, or a raised hand while it waits on the owner.
    var compactTrailing: some View {
        AgentCompactValue(activity: self)
    }

    var tab: some View { AgentTab(activity: self) }
    var homeCard: some View { AgentHomeCard(activity: self) }
}

private struct AgentCompactValue: View {
    let activity: AgentActivity
    @Environment(\.islandIsVisible) private var isVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var raised = 0

    var body: some View {
        if let session = activity.liveSession {
            if session.needsYou {
                // The hand bounces once as it comes up, and then holds still.
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .symbolEffect(.bounce, options: .nonRepeating, value: raised)
                    .onAppear { if !reduceMotion { raised += 1 } }
            } else if let started = session.turnStartedAt {
                // Once a minute, and only while someone can see it. A second past each whole minute, so the minute
                // rounded up has turned over.
                TimelineView(.periodic(from: started + 1, by: isVisible ? 60 : 3_600)) { context in
                    Text(AgentActivity.runningFor(context.date.timeIntervalSince(started)))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(activity.tint)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }
}

/// A session's state at a glance, in a circle: a check when done, a third of a ring while working, a raised hand while it
/// waits on the owner, an exclamation mark when it failed. The working ring turns a step on each beat while someone can
/// see it, so it reads as busy rather than as a level; one state gives way to the next in a blur.
struct AgentStatusCircle: View {
    let state: AgentSession.State
    let tint: Color
    var size: CGFloat = 24
    @Environment(\.islandIsVisible) private var isVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var steps = 0

    private var turns: Bool { state == .working && isVisible && !reduceMotion }

    var body: some View {
        face
            .id(kind)
            .transition(Motion.glyphSwap)
            .animation(Motion.valueChange, value: kind)
            .task(id: turns) {
                guard turns else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: Motion.Usage.untilNextBeat())
                    guard !Task.isCancelled else { return }
                    withAnimation(Motion.Usage.workingStep) { steps += 1 }
                }
            }
    }

    /// What is drawn, by state: asking and needing permission differ only in the symbol.
    private var kind: Int {
        switch state {
        case .working: 0
        case .needsYou(let isQuestion): isQuestion ? 1 : 2
        case .done: 3
        case .failed: 4
        case .stopped, .ready: 5
        }
    }

    private var face: some View {
        ZStack {
            switch state {
            case .working:
                Circle().stroke(.white.opacity(0.16), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90 + Double(steps) * Motion.Agent.workingStepAngle))
            case .needsYou(let isQuestion):
                Circle().fill(.yellow)
                symbol(isQuestion ? "questionmark" : "hand.raised.fill")
            case .done:
                Circle().fill(.white)
                symbol("checkmark")
            case .failed:
                Circle().fill(.red)
                symbol("exclamationmark")
            case .stopped, .ready:
                Circle().stroke(.white.opacity(0.3), lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
        .padding(1.25)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.black)
    }
}

/// What a session's state reads as: "working · 4m", "needs you", "done · 2m ago".
struct AgentStatusLine: View {
    let session: AgentSession
    @Environment(\.islandIsVisible) private var isVisible

    var body: some View {
        TimelineView(.periodic(from: .now, by: isVisible ? 60 : 3_600)) { context in
            Text(line(at: context.date))
        }
    }

    private func line(at date: Date) -> String {
        switch session.state {
        case .working:
            let since = session.turnStartedAt ?? session.lastEventAt
            return String(localized: "working · \(AgentActivity.runningFor(date.timeIntervalSince(since)))")
        case .needsYou(let isQuestion):
            return isQuestion ? String(localized: "asks you") : String(localized: "needs you")
        case .done, .failed, .stopped, .ready:
            let word = switch session.state {
            case .done: String(localized: "done")
            case .failed: String(localized: "failed")
            default: String(localized: "stopped")
            }
            let ended = session.turnEndedAt ?? session.lastEventAt
            guard date.timeIntervalSince(ended) >= 60 else { return String(localized: "\(word) · just now") }
            return String(localized: "\(word) · \(AgentActivity.runningFor(date.timeIntervalSince(ended))) ago")
        }
    }
}

/// One row per session, the most pressing on top, as many as fit below the notch: its state, its project and what it
/// is doing or said last, when that changed, and a button bringing its terminal forward.
struct AgentTab: View {
    let activity: AgentActivity
    /// Below the MacBook Air's notch, two rows fit with room for a line saying how many more there are.
    static let rowsShown = 2

    var body: some View {
        let sessions = activity.shownSessions
        Group {
            if !activity.isConnected {
                HStack(spacing: 12) {
                    Text(activity.problem ?? String(localized: "See your Claude Code sessions here"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("Connect") { activity.onConnect?() }
                        .buttonStyle(.island(tint: activity.tint))
                }
            } else if sessions.isEmpty {
                Text(activity.problem ?? String(localized: "No Claude Code sessions yet"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sessions.prefix(Self.rowsShown)) { session in
                        AgentRow(session: session, tint: activity.tint) { activity.openTerminal(for: session) }
                    }
                    if sessions.count > Self.rowsShown {
                        Text("+\(sessions.count - Self.rowsShown) more")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 38)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.tabStateChange, value: sessions)
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let tint: Color
    let openTerminal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AgentStatusCircle(state: session.state, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.project)
                        .font(.system(size: 13, weight: .semibold))
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    AgentStatusLine(session: session)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(session.needsYou ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let summary = session.workSummary {
                        Text(summary)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            .lineLimit(1)
            Button(action: openTerminal) {
                Image(systemName: "terminal.fill")
            }
            .buttonStyle(.islandIcon())
            .accessibilityLabel(Text("Open Terminal"))
        }
    }

    /// What it is doing, or what it said or what went wrong once the turn ended.
    private var detail: String {
        switch session.state {
        case .working, .needsYou: session.step ?? String(localized: "Thinking")
        default: session.reply ?? session.step ?? ""
        }
    }
}

/// The sessions' card on Home: the most pressing one's state, large, over its project.
private struct AgentHomeCard: View {
    let activity: AgentActivity
    @Environment(\.islandIsVisible) private var isVisible

    var body: some View {
        if let session = activity.shownSessions.first {
            HomeCardContent(Text(session.project)) {
                AgentStatusCircle(state: session.state, tint: activity.tint, size: 15)
            } value: {
                value(session)
            }
        }
    }

    @ViewBuilder private func value(_ session: AgentSession) -> some View {
        switch session.state {
        case .working:
            let since = session.turnStartedAt ?? session.lastEventAt
            TimelineView(.periodic(from: since + 1, by: isVisible ? 60 : 3_600)) { context in
                Text(AgentActivity.runningFor(context.date.timeIntervalSince(since)))
                    .foregroundStyle(activity.tint)
            }
        case .needsYou:
            // How long it has waited: "Needs you" doesn't fit one of five cards, and the raised hand says why.
            TimelineView(.periodic(from: session.stateSince + 1, by: isVisible ? 60 : 3_600)) { context in
                Text(AgentActivity.runningFor(context.date.timeIntervalSince(session.stateSince)))
                    .foregroundStyle(.yellow)
            }
        case .done:
            Text("Done")
        case .failed:
            Text("Failed")
                .foregroundStyle(.red)
        case .stopped, .ready:
            Text("Stopped")
                .foregroundStyle(.secondary)
        }
    }
}
