import AppKit
import SwiftUI
import Testing
@testable import Jambul

/// Most of these leave the screen alone; one holds the screen on for a moment to check that it really does. They keep
/// their memory in one defaults domain of their own, emptied as each test starts, and take turns with it.
@MainActor
@Suite(.serialized)
final class KeepAwakeActivityTests {
    private let activities = ActivityCenter()
    private let clock = KeepAwakeClock()
    private let peeks = KeepAwakePeeks()
    private let defaults: UserDefaults

    init() {
        let suiteName = "JambulTests.KeepAwake"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        activities.onPeek = { [peeks] in peeks.list.append($0) }
    }

    private func makeKeepAwake(bootSession: String = "boot 1", holdsScreen: Bool = false,
                               closingTime: @escaping @MainActor (EyesClosing) -> Duration = { Motion.eyesClosing($0) })
        -> KeepAwakeActivity {
        KeepAwakeActivity(activities: activities, defaults: defaults, bootSession: bootSession,
                          now: { [clock] in clock.now }, holdsScreen: holdsScreen, closingTime: closingTime)
    }

    @Test func turningItOnHoldsTheScreenOnUntilItIsTurnedOff() async throws {
        let keepAwake = makeKeepAwake(holdsScreen: true)
        keepAwake.start()
        #expect(keepAwake.isOn)
        #expect(keepAwake.isLive)
        #expect(keepAwake.since == clock.now)
        #expect(keepAwake.isKeepingScreenOn)

        // Hours later, nothing has turned it off.
        clock.advance(by: 5 * 3_600)
        #expect(keepAwake.isOn)

        keepAwake.stop()
        // The screen may sleep at once; the eyes close before it leaves the island.
        #expect(!keepAwake.isKeepingScreenOn)
        #expect(!keepAwake.isOn)
        #expect(keepAwake.isLive)
        #expect(keepAwake.closing == .plain)
        try await waitUntil { !keepAwake.isLive }
    }

    @Test func turningItOnAgainWhileTheEyesCloseKeepsItOn() async throws {
        let keepAwake = makeKeepAwake()
        keepAwake.start()
        keepAwake.stop()
        keepAwake.start()
        try await Task.sleep(for: Motion.eyesClosing(.plain) + .milliseconds(150))
        #expect(keepAwake.isOn)
    }

    // MARK: Until Claude Code finishes

    @Test func onUntilAgentsFinishItTurnsOffAsTheyDo() async throws {
        // Its eyes take far longer to close with a smile than plainly here, so a plain closing would show.
        let keepAwake = makeKeepAwake(closingTime: { $0 == .plain ? .milliseconds(50) : .seconds(60) })
        keepAwake.start(untilAgentsFinish: true)
        #expect(keepAwake.untilAgentsFinish)
        keepAwake.agentsFinished()
        #expect(!keepAwake.isOn)
        #expect(peeks.list.map(\.title) == ["Keep Awake off"])
        #expect(peeks.list.first?.detail == "Claude Code finished")
        // Its eyes smile before they shut, beside the notch and in the peek alike, and it stays until they have.
        #expect(peeks.list.first?.motion == .smilingEyes)
        #expect(keepAwake.closing == .smile)
        try await Task.sleep(for: .milliseconds(300))
        #expect(keepAwake.isLive)
        // Nobody clicked, so its tab offers Turn On at once, and a click on its face turns it back on.
        #expect(keepAwake.isTurningItselfOff)
        #expect(!keepAwake.offersTurnOff)
        keepAwake.toggleFromFace()
        #expect(keepAwake.isOn)
        #expect(keepAwake.offersTurnOff)
    }

    @Test func theRestOfADoubleClickOnItsFaceLeavesItOff() async throws {
        let keepAwake = makeKeepAwake(closingTime: { _ in .milliseconds(100) })
        keepAwake.toggleFromFace()
        #expect(keepAwake.isOn)
        // The first click turns it off; the second, while its eyes close, does nothing, as on Turn Off.
        keepAwake.toggleFromFace()
        #expect(!keepAwake.isOn)
        #expect(keepAwake.offersTurnOff)
        keepAwake.toggleFromFace()
        #expect(!keepAwake.isOn)
        #expect(keepAwake.isLive)
        // Once it has left the island, a click turns it on again.
        try await waitUntil { !keepAwake.isLive }
        #expect(!keepAwake.offersTurnOff)
        keepAwake.toggleFromFace()
        #expect(keepAwake.isOn)
    }

    @Test func turnedOnPlainlyItStaysOnWhenAgentsFinish() {
        let keepAwake = makeKeepAwake()
        keepAwake.start()
        keepAwake.agentsFinished()
        #expect(keepAwake.isOn)
        #expect(peeks.list.isEmpty)
    }

    @Test func onUntilAgentsFinishSurvivesARelaunch() {
        makeKeepAwake().start(untilAgentsFinish: true)
        let relaunched = makeKeepAwake()
        #expect(relaunched.isOn)
        #expect(relaunched.untilAgentsFinish)
        relaunched.stop()
        relaunched.start()
        #expect(!makeKeepAwake().untilAgentsFinish)
    }

    /// With Claude Code's sessions turned off nothing will say they finished, so it stays on until turned off.
    @Test func onUntilAgentsFinishItStaysOnOnceSessionsAreTurnedOff() {
        let keepAwake = makeKeepAwake()
        keepAwake.start(untilAgentsFinish: true)
        keepAwake.stopWaitingForAgents()
        #expect(!keepAwake.untilAgentsFinish)
        keepAwake.agentsFinished()
        #expect(keepAwake.isOn)
        #expect(!makeKeepAwake().untilAgentsFinish)
    }

    @Test func itsTabSaysItWaitsForClaudeCode() {
        let since = Date(timeIntervalSinceReferenceDate: 0)
        for seconds in [30, 12 * 60] as [TimeInterval] {
            #expect(KeepAwakeActivity.detailLine(since: since, at: since + seconds, untilAgentsFinish: true)
                    == "Until Claude Code finishes")
        }
        #expect(KeepAwakeActivity.headline(since: since, at: since + 12 * 60) == "12m")
    }

    // MARK: The battery

    @Test func itTurnsOffAsTheBatteryFallsTo20Percent() {
        let keepAwake = makeKeepAwake()
        keepAwake.update(PowerState(percent: 25, isOnExternalPower: false))
        keepAwake.start()
        keepAwake.update(PowerState(percent: 21, isOnExternalPower: false))
        #expect(keepAwake.isOn)
        keepAwake.update(PowerState(percent: 20, isOnExternalPower: false))
        #expect(!keepAwake.isOn)
        // Said so in a peek that waits for the owner, who is away, with eyes that grow heavy before they shut.
        #expect(peeks.list.map(\.title) == ["Keep Awake off"])
        #expect(peeks.list.first?.mustBeSeen == true)
        #expect(peeks.list.first?.source == keepAwake.id)
        #expect(peeks.list.first?.motion == .tiredEyes)
        #expect(keepAwake.closing == .tired)
    }

    @Test func turnedOnBelow20PercentItLastsUntil5() {
        let keepAwake = makeKeepAwake()
        keepAwake.update(PowerState(percent: 18, isOnExternalPower: false))
        keepAwake.start()
        keepAwake.update(PowerState(percent: 12, isOnExternalPower: false))
        #expect(keepAwake.isOn)
        keepAwake.update(PowerState(percent: 5, isOnExternalPower: false))
        #expect(!keepAwake.isOn)
    }

    @Test func onTheChargerTheBatteryNeverTurnsItOff() {
        let keepAwake = makeKeepAwake()
        keepAwake.update(PowerState(percent: 25, isOnExternalPower: true))
        keepAwake.start()
        keepAwake.update(PowerState(percent: 20, isOnExternalPower: true))
        #expect(keepAwake.isOn)
        #expect(peeks.list.isEmpty)
    }

    @Test func aMacWithoutABatteryKeepsItOn() {
        let keepAwake = makeKeepAwake()
        keepAwake.start()
        keepAwake.update(nil)
        #expect(keepAwake.isOn)
    }

    // MARK: Relaunching

    @Test func itComesBackOnAfterJambulRelaunches() {
        let before = makeKeepAwake()
        before.start()
        clock.advance(by: 600)
        // A build relaunches Jambul in the same run of the Mac.
        let after = makeKeepAwake()
        #expect(after.isOn)
        #expect(after.since == before.since)
    }

    @Test func itDoesntComeBackAfterTheMacRestarts() {
        makeKeepAwake().start()
        #expect(!makeKeepAwake(bootSession: "boot 2").isLive)
        // Forgotten, not just skipped.
        #expect(!makeKeepAwake().isLive)
    }

    @Test func quittingJambulTurnsItOffForGood() {
        let keepAwake = makeKeepAwake()
        keepAwake.start()
        keepAwake.forgetOnQuit()
        #expect(!makeKeepAwake().isLive)
    }

    @Test func turningItOffIsRememberedToo() {
        let keepAwake = makeKeepAwake()
        keepAwake.start()
        keepAwake.stop()
        #expect(!makeKeepAwake().isLive)
    }

    // MARK: On the island

    @Test func theTimeOnReadsInHoursAndMinutes() {
        #expect(KeepAwakeActivity.elapsed(0) == "0m")
        #expect(KeepAwakeActivity.elapsed(12 * 60 + 59) == "12m")
        #expect(KeepAwakeActivity.elapsed(65 * 60) == "1h 05m")
        #expect(KeepAwakeActivity.elapsed(10 * 3_600) == "10h 00m")
    }

    @Test func itsTabSaysHowLongOnlyFromAMinuteOn() {
        let english = Locale(identifier: "en_US")
        let since = clock.now
        let time = since.formatted(.dateTime.hour().minute().locale(english))
        // Never "0m": just turned on, it says it is awake, and since when.
        #expect(KeepAwakeActivity.headline(since: since, at: since.addingTimeInterval(59)) == "Awake")
        #expect(KeepAwakeActivity.detailLine(since: since, at: since.addingTimeInterval(59), locale: english)
                == "Since \(time)")
        #expect(KeepAwakeActivity.headline(since: since, at: since.addingTimeInterval(60)) == "1m")
        #expect(KeepAwakeActivity.headline(since: since, at: since.addingTimeInterval(65 * 60)) == "1h 05m")
        #expect(KeepAwakeActivity.detailLine(since: since, at: since.addingTimeInterval(65 * 60), locale: english)
                == "Awake since \(time)")
    }

    @Test func besideTheNotchItSaysHowLongShortly() {
        #expect(KeepAwakeActivity.compactOnFor(0) == "On")
        #expect(KeepAwakeActivity.compactOnFor(59) == "On")
        #expect(KeepAwakeActivity.compactOnFor(12 * 60 + 59) == "12m")
        #expect(KeepAwakeActivity.compactOnFor(65 * 60) == "1h05")
        #expect(KeepAwakeActivity.compactOnFor(9 * 3_600 + 59 * 60) == "9h59")
        #expect(KeepAwakeActivity.compactOnFor(10 * 3_600 + 30 * 60) == "10h")
        #expect(KeepAwakeActivity.compactOnFor(150 * 3_600) == "6d")
        #expect(KeepAwakeActivity.compactOnFor(1_000 * 3_600) == "41d")
    }

    @Test func theEyesAndHowLongItsBeenOnFitBesideTheNotch() {
        let keepAwake = makeKeepAwake()
        keepAwake.start()
        let eyes = NSHostingView(rootView: keepAwake.compactLeading).fittingSize
        #expect(eyes.width <= keepAwake.compactLeadingWidth && eyes.height <= IslandLayout.compactGlyphHeight, "\(eyes)")
        // However long it has been on, the island keeps its width.
        for seconds in [0, 12 * 60, 9 * 3_600 + 59 * 60, 23 * 3_600, 150 * 3_600, 1_000 * 3_600] as [TimeInterval] {
            keepAwake.start(since: .now.addingTimeInterval(-seconds))
            let width = NSHostingView(rootView: keepAwake.compactTrailing).fittingSize.width
            #expect(width <= keepAwake.compactSlotWidth, "\(KeepAwakeActivity.compactOnFor(seconds)) is \(width) pt")
        }
        // Beside a countdown, its eyes take the left, which is no wider than the timer's own.
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        #expect(keepAwake.compactLeadingWidth <= timer.compactLeadingWidth)
    }

    @Test func theTimerKeepsTheRightBesideTheNotch() {
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        let keepAwake = makeKeepAwake()
        activities.register(keepAwake)
        activities.register(timer)
        keepAwake.start()
        timer.start(.seconds(300))
        #expect(activities.liveActivities.map(\.id) == [timer.id, keepAwake.id])
        timer.stop()
    }

    @Test func itsTabFitsBelowTheNotchOnOrOff() {
        let keepAwake = makeKeepAwake()
        let notch = NotchMetrics(size: CGSize(width: 179, height: 32), compactHeight: 33)
        let room = CGSize(width: IslandLayout.expandedSize.width - 2 * IslandLayout.expandedContentInset,
                          height: IslandLayout.expandedContentRoom(notch))
        // Off with Claude Code at work, its two buttons stand one above the other beside the line.
        keepAwake.agentsAreWorking = { true }
        for on in [false, true] {
            if on { keepAwake.start(since: clock.now.addingTimeInterval(-99 * 3_600)) }
            let size = NSHostingView(rootView: keepAwake.tab).fittingSize
            #expect(size.width <= room.width && size.height <= room.height, "\(size) in \(room)")
        }
    }

    @Test func itHasATabToStartFromWithoutBeingLiveFirst() {
        let keepAwake = makeKeepAwake()
        #expect(keepAwake.hasTab)
        #expect(!keepAwake.isLive)
    }

    // MARK: The eyes

    @Test func everyPairOfEyesMakesTheSameMoveOnOneBeat() {
        // Each move asked for differs from the last, so pairs that each asked for their own would differ.
        let moves = MoveStub()
        let beat = KeepAwakeBeat(gap: { 3_600 }, move: { moves.next() })
        let besideTheNotch = CountingFollower()
        let onHome = CountingFollower()
        beat.add(besideTheNotch)
        beat.add(onHome)
        #expect(beat.isRunning)
        beat.tick()
        beat.tick()
        #expect(besideTheNotch.moves == [.blink, .glance(toRight: true)])
        #expect(onHome.moves == besideTheNotch.moves)

        beat.remove(besideTheNotch)
        #expect(beat.isRunning)
        beat.remove(onHome)
        #expect(!beat.isRunning)
    }

    @Test func mostBeatsAreBlinks() {
        let moves = (0..<2_000).map { _ in BeatMove.random() }
        let glances = moves.count { $0 != .blink }
        #expect(glances > 400 && glances < 800, "\(glances) glances in 2000 beats")
        #expect(moves.contains(.glance(toRight: true)) && moves.contains(.glance(toRight: false)))
    }

    @Test func theEyesKeepTheBeatOnlyWhileTheyMoveOnScreen() {
        let beat = KeepAwakeBeat(gap: { 3_600 })
        let eyes = makeEyes(isOpen: true, beat: beat)
        eyes.moves = true
        #expect(!beat.isRunning)

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 20), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.contentView?.addSubview(eyes)
        #expect(beat.isRunning)
        eyes.moves = false
        #expect(!beat.isRunning)

        eyes.moves = true
        #expect(beat.isRunning)
        eyes.removeFromSuperview()
        #expect(!beat.isRunning)
    }

    @Test func theEyesRestOpenOrShut() throws {
        let eyes = makeEyes(isOpen: true)
        #expect(eyes.showsEyes && !eyes.showsLids)
        #expect(eyes.eyeOpenness == [1, 1])
        // Turned off, they end shut, whichever way they close; turned on again, open.
        for closing in [EyesClosing.plain, .smile, .tired] {
            eyes.closing = closing
            eyes.isOpen = false
            #expect(!eyes.showsEyes && eyes.showsLids, "\(closing)")
            eyes.isOpen = true
            #expect(eyes.showsEyes && !eyes.showsLids, "\(closing)")
            #expect(eyes.eyeOpenness == [1, 1])
        }
        // Just turned on, they start shut and pop open; otherwise they appear as they are, open or shut.
        let opening = makeEyes(isOpen: true, opensAsItAppears: true)
        #expect(opening.showsEyes)
        #expect(animations(in: try #require(opening.layer)).contains("openness"))
        #expect(!animations(in: try #require(makeEyes(isOpen: true).layer)).contains("openness"))
        #expect(makeEyes(isOpen: false).showsLids)
    }

    @Test func aShutEyeIsACurvedLidNotAFlatLine() throws {
        for size in [EyesSize.compact, .card, .face] {
            let metrics = size.metrics
            let eyes = EyesView(metrics: metrics, tint: .cyan, lidColor: .white, isOpen: false, opensAsItAppears: false)
            let lids = shapes(in: try #require(eyes.layer)).filter { $0.opacity > 0 }
            #expect(lids.count == 2, "\(size)")
            for lid in lids {
                let bounds = try #require(lid.path?.boundingBoxOfPath)
                #expect(abs(bounds.width - metrics.eye.width) < 0.01, "\(size)")
                #expect(bounds.height > metrics.lidDepth - 0.01, "\(size): \(bounds)")
            }
        }
    }

    @Test func theEyesMoveOnTheBeatOnlyWhileOpen() throws {
        let eyes = makeEyes(isOpen: false)
        eyes.onBeat(.blink)
        eyes.onBeat(.glance(toRight: true))
        #expect(animations(in: try #require(eyes.layer)).isEmpty)

        eyes.isOpen = true
        eyes.layer?.sublayers?.forEach { removeAnimations(in: $0) }
        eyes.onBeat(.blink)
        #expect(animations(in: try #require(eyes.layer)).filter { $0 == "blink" }.count == 2)
        eyes.onBeat(.glance(toRight: false))
        #expect(animations(in: try #require(eyes.layer)).contains("glance"))
    }

    @Test func oneEyePeeksHalfOpenWhileTheyAreShut() {
        let eyes = makeEyes(isOpen: false)
        eyes.peeks = true
        #expect(eyes.eyeOpenness == [Motion.eyePeek, 0])
        eyes.peeks = false
        #expect(eyes.eyeOpenness == [0, 0])
        #expect(eyes.showsLids)
        // Open, there is nothing to peek from.
        eyes.isOpen = true
        eyes.peeks = true
        #expect(eyes.eyeOpenness == [1, 1])
    }

    @Test func everyEyeSitsOnHalfPoints() {
        for size in [EyesSize.compact, .card, .face] {
            let metrics = size.metrics
            let left = (metrics.box.width - 2 * metrics.eye.width - metrics.gap) / 2
            let bottom = (metrics.box.height - metrics.eye.height) / 2
            for edge in [left, bottom, left + metrics.eye.width, left + metrics.eye.width + metrics.gap,
                         bottom + metrics.eye.height] {
                #expect((edge * 2).rounded() == edge * 2, "\(size): \(edge)")
            }
        }
        // The eyes that fly from beside the notch to Home or the tab, scaled by height, land on the eyes there.
        let compact = EyesSize.compact.metrics
        for size in [EyesSize.card, .face] {
            let metrics = size.metrics, scale = metrics.box.height / compact.box.height
            #expect(abs(compact.eye.width * scale - metrics.eye.width) <= 0.5, "\(size)")
            #expect(abs(compact.eye.height * scale - metrics.eye.height) <= 0.5, "\(size)")
            #expect(abs(compact.gap * scale - metrics.gap) <= 0.5, "\(size)")
            #expect(metrics.box.width == metrics.box.height, "\(size)")
        }
    }

    @Test func itsTabShowsItsFaceShutWhileOffAndOpenWhileOn() async throws {
        let keepAwake = makeKeepAwake()
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 448, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: KeepAwakeTabHost(keepAwake: keepAwake))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(50))
        let content = try #require(window.contentView)

        // Off, as its tab is mostly seen: one face, its eyes shut.
        let face = try #require(views(EyesView.self, in: content).first)
        #expect(views(EyesView.self, in: content) == [face])
        #expect(face.metrics == EyesSize.face.metrics)
        #expect(face.showsLids)

        keepAwake.start()
        try await waitUntil { face.showsEyes }
        #expect(views(EyesView.self, in: content) == [face])

        keepAwake.stop()
        try await waitUntil { face.showsLids }
        try await waitUntil { !keepAwake.isLive }
        #expect(views(EyesView.self, in: content) == [face])
    }

    @Test func aBeatWithOnlyGoneGlyphsStops() {
        let beat = KeepAwakeBeat(gap: { 3_600 })
        do {
            let eye = CountingFollower()
            beat.add(eye)
        }
        #expect(beat.isRunning)
        beat.tick()
        #expect(!beat.isRunning)
    }
}

/// Hands out a blink, then a glance, and so on.
@MainActor
private final class MoveStub {
    private var count = 0

    func next() -> BeatMove {
        count += 1
        return count % 2 == 1 ? .blink : .glance(toRight: true)
    }
}

@MainActor
private final class CountingFollower: BeatFollower {
    private(set) var moves: [BeatMove] = []

    func onBeat(_ move: BeatMove) {
        moves.append(move)
    }
}

@MainActor
private final class KeepAwakeClock {
    private(set) var now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func advance(by seconds: TimeInterval) {
        now.addTimeInterval(seconds)
    }
}

@MainActor
private final class KeepAwakePeeks {
    var list: [Peek] = []
}

/// Keep Awake's tab as the open island shows it: built in a view's body, so it follows Keep Awake turning on and off.
private struct KeepAwakeTabHost: View {
    let keepAwake: KeepAwakeActivity

    var body: some View {
        keepAwake.tab
    }
}

/// Every view of a kind inside `view`, however deep.
@MainActor
private func views<Found: NSView>(_ kind: Found.Type, in view: NSView) -> [Found] {
    view.subviews.flatMap { subview in
        ((subview as? Found).map { [$0] } ?? []) + views(kind, in: subview)
    }
}

/// A pair of eyes as its card on Home shows them, keeping its own beat.
@MainActor
private func makeEyes(isOpen: Bool, opensAsItAppears: Bool = false, beat: KeepAwakeBeat = KeepAwakeBeat(gap: { 3_600 }))
    -> EyesView {
    EyesView(metrics: EyesSize.card.metrics, tint: .cyan, lidColor: .white, isOpen: isOpen,
             opensAsItAppears: opensAsItAppears, beat: beat)
}

/// The keys of every animation running in `layer` and the layers inside it.
private func animations(in layer: CALayer) -> [String] {
    (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap { animations(in: $0) }
}

private func removeAnimations(in layer: CALayer) {
    layer.removeAllAnimations()
    layer.sublayers?.forEach { removeAnimations(in: $0) }
}

/// Every shape layer in `layer`, however deep.
private func shapes(in layer: CALayer) -> [CAShapeLayer] {
    ((layer as? CAShapeLayer).map { [$0] } ?? []) + (layer.sublayers ?? []).flatMap { shapes(in: $0) }
}
