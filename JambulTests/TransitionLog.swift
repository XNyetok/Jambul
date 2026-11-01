@testable import Jambul

/// Every presentation change an island makes, as "from → to".
@MainActor
final class TransitionLog {
    private(set) var steps: [String] = []

    init(_ island: IslandModel) {
        island.onPresentationChange = { [weak self] from, to in
            self?.steps.append("\(from) → \(to)")
        }
    }
}
