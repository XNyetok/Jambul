import Foundation

/// TUI status and lifecycle hooks arrive independently. Only the TUI can say its confirmation dialog is open.
@MainActor
final class AntigravitySessionSource {
    private struct Observation {
        var hook: AgentSessionUpdate?
        var snapshot: AgentSessionUpdate?
        var outcome: AgentSessionUpdate?
    }

    var onUpdate: (@MainActor (AgentSessionUpdate) -> Void)?
    private let settle: Duration
    private var observations: [String: Observation] = [:]
    private var settling: [String: Task<Void, Never>] = [:]

    init(settle: Duration = .milliseconds(400)) {
        self.settle = settle
    }

    func receive(_ update: AgentSessionUpdate) {
        let id = update.session
        let previous = observations[id]
        var current = previous ?? Observation()
        if update.isSnapshot {
            guard current.snapshot.map({ $0.date <= update.date }) ?? true else { return }
            current.snapshot = update
        } else {
            guard current.hook.map({ $0.date <= update.date }) ?? true else { return }
            current.hook = update
            if update.kind.endsTurn { current.outcome = update }
            else if update.kind == .working { current.outcome = nil }
        }
        observations[id] = current
        if update.isSnapshot, previous?.snapshot?.kind == update.kind, settling[id] != nil { return }
        settling.removeValue(forKey: id)?.cancel()
        if let outcome = current.outcome {
            // A user hook can continue the loop. In the TUI, confirm that it actually went idle first.
            if current.snapshot == nil || current.snapshot?.kind == .idle {
                schedule(id, outcome: outcome)
            } else if update.isSnapshot {
                onUpdate?(update)
            }
        } else if update.isSnapshot && update.kind == .idle {
            if previous?.snapshot?.kind != .idle { schedule(id, outcome: update) }
        } else if update.isSnapshot || current.snapshot?.kind != .approval {
            onUpdate?(update)
        }
        if previous == nil {
            let oldest = update.date.addingTimeInterval(-AgentActivity.forgetAfter)
            observations = observations.filter { max($0.value.hook?.date ?? .distantPast,
                                                      $0.value.snapshot?.date ?? .distantPast) >= oldest }
        }
    }

    private func schedule(_ id: String, outcome: AgentSessionUpdate) {
        settling[id] = Task { [weak self, settle] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled, let self, var observation = observations[id] else { return }
            settling[id] = nil
            var settled = outcome
            settled.date = max(outcome.date, observation.snapshot?.date ?? .distantPast)
            onUpdate?(settled)
            observation.outcome = nil
            // Keep the last snapshot and hook for ordering, but don't replay the terminal result.
            observations[id] = observation
        }
    }

    func stop() {
        for task in settling.values { task.cancel() }
        settling.removeAll()
        observations.removeAll()
    }
}
