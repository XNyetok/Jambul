import AppKit
import os
import SwiftUI

/// A countdown started from its tab.
///
/// The display ticks once a second, and the only other timer is a single wake-up when the time is up. The wall clock
/// is the source of truth, for the display and the end alike: the countdown stays right across sleep, and a changed
/// clock moves both together. An end that passes while the Mac sleeps is announced once it is fully awake.
@MainActor
@Observable
final class TimerActivity: NSObject, IslandActivity {
    enum State: Equatable {
        case idle
        /// Counting down to the interval's end. The interval spans the whole countdown, added minutes included, so it
        /// is also what the ring measures against.
        case running(ClosedRange<Date>)
        /// Stopped at `at`, keeping the interval it ran with.
        case paused(ClosedRange<Date>, at: Date)

        /// Time left at `date`; zero when idle.
        func remaining(at date: Date) -> TimeInterval {
            switch self {
            case .idle: 0
            case .running(let interval): max(interval.upperBound.timeIntervalSince(date), 0)
            case .paused(let interval, let pausedAt): max(interval.upperBound.timeIntervalSince(pausedAt), 0)
            }
        }

        /// How much of the countdown is left at `date`, from 1 down to 0.
        func fraction(at date: Date) -> Double {
            total > 0 ? min(remaining(at: date) / total, 1) : 0
        }

        /// The whole countdown, added minutes included.
        var total: TimeInterval {
            switch self {
            case .idle: 0
            case .running(let interval), .paused(let interval, _): interval.upperBound.timeIntervalSince(interval.lowerBound)
            }
        }

        var isPaused: Bool {
            if case .paused = self { true } else { false }
        }
    }

    /// The quick starts on its tab.
    static let presets: [Duration] = [.seconds(5 * 60), .seconds(15 * 60), .seconds(25 * 60)]
    static let addedTime: Duration = .seconds(60)
    /// Twice as long as other peeks, since the owner may be looking elsewhere when the time is up.
    static let donePeekDuration: Duration = .seconds(5)

    let id = "timer"
    var title: String { String(localized: "Timer") }
    var priority: ActivityPriority { .high }
    var tint: Color { .orange }
    var tabSymbol: String { "timer" }
    var homeCardIsQuiet: Bool { state == .idle }
    var isLive: Bool { state != .idle }

    private(set) var state = State.idle {
        didSet {
            if state != .idle { shown = state }
            keepMacAwake(isRunning)
        }
    }

    /// What the views draw: the countdown, or once it has stopped or finished, the countdown as it last was. The view
    /// leaving the island after Stop then fades out on the time it showed, not on 0:00 and an empty ring.
    private(set) var shown = State.idle

    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    var isPaused: Bool { state.isPaused }

    /// Whether this timer is keeping the Mac from sleeping right now.
    var isKeepingMacAwake: Bool { keepAwake != nil }

    /// Room for the countdown beside the notch: "25:00" is 39 pt wide there, and "1:00:00" 51 pt (measured).
    var compactSlotWidth: CGFloat { shown.total >= 3600 ? 54 : 42 }
    /// The ring.
    var compactLeadingWidth: CGFloat { IslandLayout.compactGlyphHeight }

    /// Weak, since the center holds its activities.
    @ObservationIgnored private weak var activities: ActivityCenter?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let keepsMacAwake: Bool
    @ObservationIgnored private let onFinish: @MainActor () -> Void
    @ObservationIgnored private var wakeUp: Task<Void, Never>?
    @ObservationIgnored private var keepAwake: (any NSObjectProtocol)?
    /// From the Mac going to sleep until it is fully awake again. It wakes for moments in between, with the display off
    /// and no sound (dark wakes), and the wake-up would otherwise finish an end that passed during sleep in one of them.
    @ObservationIgnored private var isMacAsleep = false

    /// - Parameters:
    ///   - now: The current time; tests pass their own clock.
    ///   - keepsMacAwake: Whether a running countdown keeps the Mac from sleeping; previews turn it off.
    ///   - onFinish: Plays the taps and sound for a finished countdown.
    init(activities: ActivityCenter, now: @escaping @MainActor () -> Date = { .now }, keepsMacAwake: Bool = true,
         onFinish: @escaping @MainActor () -> Void = {}) {
        self.activities = activities
        self.now = now
        self.keepsMacAwake = keepsMacAwake
        self.onFinish = onFinish
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification,
                              object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification,
                              object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clockDidChange),
                                               name: .NSSystemClockDidChange, object: nil)
    }

    /// Time left at `date`; zero when idle.
    func remaining(at date: Date) -> TimeInterval {
        state.remaining(at: date)
    }

    /// How much of the countdown is left at `date`, from 1 down to 0.
    func fraction(at date: Date) -> Double {
        state.fraction(at: date)
    }

    func start(_ duration: Duration) {
        // A countdown that ends before it starts can't even be stored.
        guard duration > .zero else { return }
        let start = now()
        state = .running(start...start.addingTimeInterval(duration / .seconds(1)))
        Logger.activities.notice("timer started for \(duration.description, privacy: .public)")
        scheduleWakeUp()
    }

    func pause() {
        guard case .running(let interval) = state else { return }
        let pausedAt = now()
        // The time can run out a moment before the wake-up gets to it. Paused then, the timer would hold 0:00 and never
        // ring.
        guard pausedAt < interval.upperBound else {
            finish(endingAt: interval.upperBound)
            return
        }
        state = .paused(interval, at: pausedAt)
        wakeUp?.cancel()
        Logger.activities.notice("timer paused")
    }

    func resume() {
        guard case .paused(let interval, let pausedAt) = state else { return }
        let pause = now().timeIntervalSince(pausedAt)
        state = .running(interval.lowerBound.addingTimeInterval(pause)...interval.upperBound.addingTimeInterval(pause))
        Logger.activities.notice("timer resumed")
        scheduleWakeUp()
    }

    /// Adds a minute to both the time left and the whole countdown, so the ring grows back a little.
    func addMinute() {
        let added = Self.addedTime / .seconds(1)
        switch state {
        case .idle:
            return
        case .running(let interval):
            state = .running(interval.lowerBound...interval.upperBound.addingTimeInterval(added))
            scheduleWakeUp()
        case .paused(let interval, let pausedAt):
            state = .paused(interval.lowerBound...interval.upperBound.addingTimeInterval(added), at: pausedAt)
        }
        Logger.activities.notice("timer got another minute")
    }

    func stop() {
        guard state != .idle else { return }
        state = .idle
        wakeUp?.cancel()
        Logger.activities.notice("timer stopped")
    }

    /// Finishes the countdown if its time has come, or waits for it again. Runs when the wait ends, on wake, and when
    /// the clock changes, since the wait's clock and the wall clock can drift apart.
    func checkTime() {
        guard case .running(let interval) = state else { return }
        if now() < interval.upperBound {
            scheduleWakeUp()
        } else if isMacAsleep {
            // Finished on the full wake instead, where it can be seen and heard.
            Logger.activities.notice("timer end waits for the Mac to wake")
        } else {
            finish(endingAt: interval.upperBound)
        }
    }

    private func finish(endingAt end: Date) {
        // The state and the peek change in the same turn, so the island goes straight from the countdown to the peek.
        state = .idle
        wakeUp?.cancel()
        let lateness = Int(now().timeIntervalSince(end) * 1_000)
        Logger.activities.notice("timer done, \(lateness, privacy: .public) ms after its end")
        // The sound plays now; the peek waits for the owner if nobody can see the island.
        activities?.peek(Peek(symbol: "bell.fill", tint: .orange, title: String(localized: "Timer done"),
                              duration: Self.donePeekDuration, mustBeSeen: true, source: id))
        onFinish()
    }

    private func scheduleWakeUp() {
        wakeUp?.cancel()
        guard case .running(let interval) = state else { return }
        let wait = max(interval.upperBound.timeIntervalSince(now()), 0)
        wakeUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait), tolerance: Motion.timerTolerance)
            guard !Task.isCancelled else { return }
            self?.checkTime()
        }
    }

    /// While the timer runs, the Mac doesn't fall asleep by itself (the display still may), so the end is heard even
    /// when nobody touches the Mac. This also keeps App Nap from delaying the end while the island is hidden.
    private func keepMacAwake(_ awake: Bool) {
        if awake, keepsMacAwake, keepAwake == nil {
            keepAwake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "A timer is counting down")
        } else if !awake, let keepAwake {
            ProcessInfo.processInfo.endActivity(keepAwake)
            self.keepAwake = nil
        }
    }

    @objc private func systemWillSleep() {
        isMacAsleep = true
        if isRunning { Logger.activities.notice("the Mac is going to sleep while a timer runs") }
    }

    /// Posted only once the Mac is fully awake, not for its dark wakes.
    @objc private func systemDidWake() {
        isMacAsleep = false
        if isRunning { Logger.activities.notice("the Mac woke while a timer runs") }
        checkTime()
    }

    /// Posted on the main thread these days, but it hops there anyway rather than rely on it.
    @objc nonisolated private func clockDidChange() {
        Task { @MainActor in self.checkTime() }
    }
}
