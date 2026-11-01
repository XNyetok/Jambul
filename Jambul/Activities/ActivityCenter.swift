import Observation

/// Keeps track of every activity and decides which ones own the island.
@MainActor
@Observable
final class ActivityCenter {
    private(set) var activities: [any IslandActivity] = []

    /// Called on the main actor after the live activities change.
    @ObservationIgnored var onLiveActivityChange: (@MainActor () -> Void)?
    /// Called when an activity asks the island to show a peek.
    @ObservationIgnored var onPeek: (@MainActor (Peek) -> Void)?

    init() {
        trackLiveActivities()
    }

    /// Every live activity, the most important first; on a tie, the one registered first.
    var liveActivities: [any IslandActivity] {
        activities.enumerated()
            .filter { $0.element.isLive }
            .sorted { lhs, rhs in
                lhs.element.priority != rhs.element.priority
                    ? lhs.element.priority > rhs.element.priority
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The most important live activity.
    var liveActivity: (any IslandActivity)? {
        liveActivities.first
    }

    func register(_ activity: any IslandActivity) {
        activities.append(activity)
    }

    /// Peeks reach the island at once, while a change of live activities arrives a turn later. Post a peek in the same
    /// turn as the change it announces, so the island goes straight from the activity to its peek.
    func peek(_ peek: Peek) {
        onPeek?(peek)
    }

    private func trackLiveActivities() {
        withObservationTracking {
            _ = liveActivities.map(\.id)
        } onChange: { [weak self] in
            guard let self else { return }
            // onChange runs before the new value is stored, so read it on the next turn.
            Task { @MainActor in
                self.onLiveActivityChange?()
                self.trackLiveActivities()
            }
        }
    }
}
