import SwiftUI

/// What Keep Awake's eyes do on a beat: blink, or glance to one side and back.
enum BeatMove: Equatable {
    case blink
    case glance(toRight: Bool)

    /// Mostly a blink, now and then a glance, so the eyes read as alive rather than ticking.
    @MainActor static func random() -> Self {
        Double.random(in: 0..<1) < Motion.eyeGlanceShare ? .glance(toRight: .random()) : .blink
    }
}

/// Something that moves on Keep Awake's beat: a pair of its eyes.
@MainActor
protocol BeatFollower: AnyObject {
    func onBeat(_ move: BeatMove)
}

/// The beat Keep Awake's eyes move on: one wait at a time, a little different each, and every pair on screen makes the
/// same move as it ends. The eyes beside the notch, on Home and on the tab then move as one, and Jambul wakes once per
/// beat however many show. Nothing runs while none moves.
@MainActor
final class KeepAwakeBeat {
    static let shared = KeepAwakeBeat()

    private struct Member {
        weak var follower: (any BeatFollower)?
    }

    private var members: [ObjectIdentifier: Member] = [:]
    private var beat: Task<Void, Never>?
    private let gap: @MainActor () -> TimeInterval
    private let move: @MainActor () -> BeatMove

    /// - Parameters:
    ///   - gap: The wait before each beat; tests pass their own.
    ///   - move: What the eyes do on each beat; tests pass their own.
    init(gap: @escaping @MainActor () -> TimeInterval = { .random(in: Motion.eyeBlinkGap) },
         move: @escaping @MainActor () -> BeatMove = { BeatMove.random() }) {
        self.gap = gap
        self.move = move
    }

    /// Whether it is counting down to a beat.
    var isRunning: Bool { beat != nil }

    func add(_ follower: any BeatFollower) {
        members[ObjectIdentifier(follower)] = Member(follower: follower)
        guard beat == nil else { return }
        beat = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.gap() else { return }
                try? await Task.sleep(for: .seconds(wait), tolerance: Motion.eyeBlinkTolerance)
                guard !Task.isCancelled, let self else { return }
                tick()
            }
        }
    }

    func remove(_ follower: any BeatFollower) {
        members[ObjectIdentifier(follower)] = nil
        if members.isEmpty { stop() }
    }

    /// Every pair of eyes makes the same move at once.
    func tick() {
        members = members.filter { $0.value.follower != nil }
        guard !members.isEmpty else { return stop() }
        let move = move()
        for member in members.values { member.follower?.onBeat(move) }
    }

    private func stop() {
        beat?.cancel()
        beat = nil
    }
}
