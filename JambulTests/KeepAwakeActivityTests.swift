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

    private func makeKeepAwake(bootSession: String = "boot 1", holdsScreen: Bool = false) -> KeepAwakeActivity {
        KeepAwakeActivity(activities: activities, defaults: defaults, bootSession: bootSession,
                          now: { [clock] in clock.now }, holdsScreen: holdsScreen)
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
        // The screen may sleep at once; the eye closes before it leaves the island.
        #expect(!keepAwake.isKeepingScreenOn)
        #expect(!keepAwake.isOn)
        #expect(keepAwake.isLive)
        try await Task.sleep(for: Motion.eyeClose + .milliseconds(150))
        #expect(!keepAwake.isLive)
    }

    @Test func turningItOnAgainWhileTheEyeClosesKeepsItOn() async throws {
        let keepAwake = makeKeepAwake()
        keepAwake.start()
        keepAwake.stop()
        keepAwake.start()
        try await Task.sleep(for: Motion.eyeClose + .milliseconds(150))
        #expect(keepAwake.isOn)
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
        // Said so in a peek that waits for the owner, who is away.
        #expect(peeks.list.map(\.title) == ["Keep Awake off"])
        #expect(peeks.list.first?.mustBeSeen == true)
        #expect(peeks.list.first?.source == keepAwake.id)
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
        // Never "0m": just turned on, it only says since when.
        #expect(KeepAwakeActivity.sinceLine(since: since, at: since.addingTimeInterval(59), locale: english)
                == "On since \(time)")
        #expect(KeepAwakeActivity.sinceLine(since: since, at: since.addingTimeInterval(60), locale: english)
                == "On since \(time) · 1m")
        #expect(KeepAwakeActivity.sinceLine(since: since, at: since.addingTimeInterval(65 * 60), locale: english)
                == "On since \(time) · 1h 05m")
    }

    @Test func theEyeAndTheLaptopRestBesideTheNotchHoweverLongItsBeenOn() {
        let keepAwake = makeKeepAwake()
        // Just on, and on for days: the island keeps its width, since only the two glyphs show beside the notch.
        for hours in [0, 99] as [TimeInterval] {
            keepAwake.start(since: clock.now.addingTimeInterval(-hours * 3_600))
            #expect(keepAwake.compactSlotWidth == KeepAwakeActivity.glyphSlotWidth)
        }
        for side in [AnyView(keepAwake.compactLeading), AnyView(keepAwake.compactTrailing)] {
            #expect(NSHostingView(rootView: side).fittingSize.width <= keepAwake.compactSlotWidth)
        }
        // Beside a countdown, its eye takes the left in the timer's wider slot.
        #expect(KeepAwakeActivity.glyphSlotWidth <= TimerActivity(activities: activities, keepsMacAwake: false).compactSlotWidth)
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

    // MARK: The eye and the laptop

    @Test func everyGlyphMovesOnOneBeat() {
        let beat = KeepAwakeBeat(gap: { 3_600 })
        let eye = CountingFollower()
        let laptop = CountingFollower()
        beat.add(eye)
        beat.add(laptop)
        #expect(beat.isRunning)
        beat.tick()
        #expect(eye.beats == 1)
        #expect(laptop.beats == 1)

        beat.remove(eye)
        #expect(beat.isRunning)
        beat.remove(laptop)
        #expect(!beat.isRunning)
    }

    @Test func theEyeKeepsTheBeatOnlyWhileItBlinksOnScreen() {
        let beat = KeepAwakeBeat(gap: { 3_600 })
        let eye = EyeView(pointSize: 13, tint: .white, isOpen: true, opensAsItAppears: false, beat: beat)
        eye.blinks = true
        #expect(!beat.isRunning)

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 20), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.contentView?.addSubview(eye)
        #expect(beat.isRunning)
        eye.blinks = false
        #expect(!beat.isRunning)

        eye.blinks = true
        #expect(beat.isRunning)
        eye.removeFromSuperview()
        #expect(!beat.isRunning)
    }

    @Test func theLaptopKeepsTheBeatOnlyWhileItTypesOnScreen() {
        let beat = KeepAwakeBeat(gap: { 3_600 })
        let laptop = LaptopView(tint: .white, isOn: true, typesAsItAppears: false, beat: beat)
        laptop.types = true
        #expect(!beat.isRunning)

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 20), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.contentView?.addSubview(laptop)
        #expect(beat.isRunning)
        laptop.types = false
        #expect(!beat.isRunning)

        laptop.types = true
        laptop.removeFromSuperview()
        #expect(!beat.isRunning)
    }

    @Test func theLaptopShowsItsCodeOnlyWhileOn() {
        let laptop = LaptopView(tint: .white, isOn: true, typesAsItAppears: false)
        #expect(laptop.typed == [1, 1, 1])
        // Once the eye has closed beside it, the code is gone; turned on again, it is typed back.
        laptop.isOn = false
        #expect(laptop.typed == [0, 0, 0])
        laptop.isOn = true
        #expect(laptop.typed == [1, 1, 1])
        // Typing again on the beat ends where it started, with all of the code there.
        laptop.onBeat()
        #expect(laptop.typed == [1, 1, 1])
        // Just turned on, it starts blank and types its code out.
        #expect(LaptopView(tint: .white, isOn: true, typesAsItAppears: true).typed == [1, 1, 1])
        #expect(LaptopView(tint: .white, isOn: false, typesAsItAppears: false).typed == [0, 0, 0])
    }

    @Test func itsTabShowsTheLaptopStillWithItsCodeOnOrOff() async throws {
        let keepAwake = makeKeepAwake()
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 448, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: KeepAwakeTabHost(keepAwake: keepAwake))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(50))
        let content = try #require(window.contentView)

        // Off, as the island mostly opens on it: the laptop with its code, where an eye shut to a flat line stood.
        #expect(views(EyeView.self, in: content).isEmpty)
        let laptop = try #require(views(LaptopView.self, in: content).first)
        #expect(views(LaptopView.self, in: content) == [laptop])
        #expect(laptop.typed == [1, 1, 1])
        #expect(isPainted(laptop, on: false), "\(String(describing: laptop.painted))")

        // Turned on and off from the tab, it stays as it is: nothing types or clears, and nothing waits for the beat.
        // Only its color changes, which is all that tells on from off now that the eye is gone.
        for turn in [keepAwake.start, keepAwake.stop] {
            turn()
            try await Task.sleep(for: .milliseconds(50))
            #expect(views(LaptopView.self, in: content) == [laptop])
            #expect(laptop.typed == [1, 1, 1])
            #expect(!laptop.types)
            #expect(animations(in: try #require(laptop.layer)).isEmpty)
            #expect(isPainted(laptop, on: keepAwake.isOn), "\(String(describing: laptop.painted))")
        }
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

@MainActor
private final class CountingFollower: BeatFollower {
    private(set) var beats = 0

    func onBeat() {
        beats += 1
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

/// Whether the laptop is painted as Keep Awake is: in a full, saturated color while on (cyan, though the test host's
/// light look resolves it differently from the island's dark one), and in dim white while off.
@MainActor
private func isPainted(_ laptop: LaptopView, on: Bool) -> Bool {
    guard let paint = laptop.painted?.usingColorSpace(.sRGB) else { return false }
    return on
        ? paint.alphaComponent == 1 && paint.saturationComponent > 0.5
        : abs(paint.alphaComponent - 0.36) < 0.01 && paint.saturationComponent == 0
}

/// The keys of every animation running in `layer` and the layers inside it.
private func animations(in layer: CALayer) -> [String] {
    (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap { animations(in: $0) }
}
