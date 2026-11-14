import AppKit
import SwiftUI

/// Motion tokens for the island. Every animation goes through here so the feel stays consistent
/// and can be tuned in one place.
@MainActor
enum Motion {
    /// How long the island waits after the pointer leaves before it closes.
    static let exitGrace: Duration = .milliseconds(120)
    /// Gap between haptic taps: far enough apart to read as separate taps, close enough to read as one signal.
    static let hapticTapSpacing: Duration = .milliseconds(80)
    /// How late the system may fire the island's timers. Its default leeway added up to 40 ms to the hover intent.
    static let timerTolerance: Duration = .milliseconds(5)

    /// With more than two activities live, how long each of those past the first shows left of the notch before the
    /// next takes its place. One small change every few seconds, only while they take turns, like Keep Awake's blinks.
    static let compactTurn: Duration = .seconds(6)
    /// How late a turn may come, so the system can line it up with other work.
    static let compactTurnTolerance: Duration = .milliseconds(500)

    /// How long the island takes to come back to rest. Hidden for a full-screen app, its window only goes once that
    /// motion is over, so a peek that came out shrinks away rather than vanishing.
    static let returnToRest: Duration = .milliseconds(500)

    /// How long the island takes to settle after any change: every spring it moves on has come to rest by then (the
    /// slowest, the arrival lift, in 0.9 s; `MotionTests` checks). Its panel only shrinks to fit it after this, so the
    /// panel never cuts off a spring still moving.
    static let islandSettles: Duration = .seconds(1)

    /// A control inside the island sinking under the pointer and springing back.
    static let buttonPress: Animation = .spring(duration: 0.2, bounce: 0)

    /// Keep Awake's eyes blinking: shut and open again in this long.
    static let eyeBlink: TimeInterval = 0.3
    /// When in a blink the eyes are shut: they snap shut over the first 40% and ease open over the rest.
    static let eyeBlinkShutAt: Double = 0.4
    /// How far the eyes squeeze in a blink.
    static let eyeShut: CGFloat = 0.1
    /// The wait between beats, a little different each time so the eyes read as alive rather than ticking. Nothing
    /// moves in between, so the eyes cost next to nothing (measured with the single eye before them: no more
    /// WindowServer CPU than with Keep Awake off); an animation that never stops cost WindowServer about 16 CPU points.
    static let eyeBlinkGap: ClosedRange<TimeInterval> = 8...12
    /// How late a beat may come. They are a little random anyway, so the system may line them up with other work.
    static let eyeBlinkTolerance: Duration = .milliseconds(500)
    /// How many beats are a glance rather than a blink.
    static let eyeGlanceShare: Double = 0.3
    /// A glance: aside, a moment's look, and back.
    static let eyeGlance: TimeInterval = 1.0
    /// The eyes shutting, in a blink and as Keep Awake turns off.
    static var eyeShutting: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeIn) }
    /// The eyes opening, after a blink.
    static var eyeOpening: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
    /// The eyes popping open as Keep Awake turns on: a spring that stretches them a little past open, then settles in
    /// about half a second.
    static let eyePopStiffness: CGFloat = 320
    static let eyePopDamping: CGFloat = 18
    /// One eye peeking from its sleep as the pointer rests on the face: half open, and a little faint.
    static let eyePeek: CGFloat = 0.55
    static let eyePeekOpacity: Double = 0.8
    /// How long the eyes take to close as Keep Awake turns off: plainly, or with a smile or heavy lids first. Keep Awake
    /// leaves the island once they have.
    static func eyesClosing(_ closing: EyesClosing) -> Duration {
        switch closing {
        case .plain: .milliseconds(500)
        case .smile, .tired: .milliseconds(1_200)
        }
    }
    /// A peek's eyes wait until the peek is out before they close.
    static let peekEyesWait: Duration = .milliseconds(350)

    /// The lift as the pointer arrives. Slow and unbouncy, so it is still moving near top speed when the hover intent
    /// ends and flows straight into opening. A quicker, bouncier lift settled first, and opening then read as a
    /// second step after a pause.
    static let arrivalLift = Spring(duration: 0.55, bounce: 0)

    static func animation(from previous: IslandPresentation, to next: IslandPresentation) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(spring(from: previous, to: next))
    }

    /// The spring the island moves on from one presentation to the next.
    static func spring(from previous: IslandPresentation, to next: IslandPresentation) -> Spring {
        switch next {
        case .idle: Spring(duration: 0.35, bounce: 0)
        case .compact: Spring(duration: 0.4, bounce: 0.2)
        case .lifted:
            // Folding back after a click is a close, so it moves like one.
            previous == .expanded ? Spring(duration: 0.35, bounce: 0) : arrivalLift
        // A peek is news arriving, so it bounces; opening under the pointer is the owner's own move, and stays calmer.
        case .peek: Spring(duration: 0.45, bounce: 0.25)
        case .expanded: Spring(duration: 0.45, bounce: 0.15)
        }
    }

    /// Content arrives just after the shape starts growing, and leaves before it shrinks.
    static var contentTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: AnyTransition(.blurReplace).animation(.easeOut(duration: 0.22).delay(0.08)),
            removal: AnyTransition(.blurReplace).animation(.easeIn(duration: 0.1)))
    }

    /// Changing tabs: the highlight slides over to the chosen tab. It settles in about half a second and only moves
    /// on a click, so it costs nothing at rest.
    static var tabChange: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.15)
    }

    /// A tab's symbol brightening under the pointer.
    static let tabHover: Animation = .easeOut(duration: 0.15)

    /// How far a tab's content travels as it comes in.
    static let tabSlide: CGFloat = 22

    /// A tab's content coming in from the side its tab lies on, while the content it replaces fades where it is. Only
    /// the arrival has a direction: a view leaving keeps the transition it last had, which can face the old way.
    static func tabContentTransition(arrivingFrom edge: HorizontalEdge) -> AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .offset(x: edge == .trailing ? tabSlide : -tabSlide).combined(with: .opacity),
            removal: .opacity.animation(.easeIn(duration: 0.1)))
    }

    /// A number rolling to its new value, like a usage percentage or the battery's charge, and a symbol trading places
    /// with another, like pause with play. Only as the value changes, so nothing moves at rest.
    static var valueChange: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0)
    }

    /// How a number changes: its digits roll toward `value`, or simply swap with Reduce Motion.
    static func numberTransition(value: Double) -> ContentTransition {
        reduceMotion ? .identity : .numericText(value: value)
    }

    /// One glyph giving way to another in the same spot, like a session's ring to its check mark.
    static var glyphSwap: AnyTransition {
        reduceMotion ? .opacity : AnyTransition(.blurReplace)
    }

    /// How long the glyph left of the notch takes to reach its place in the open island: the opening spring is all but
    /// there by then. Its place stays empty until it lands.
    static let glyphFlight: Duration = .milliseconds(260)
    /// The glyph that flew giving way to the one that belongs there, which can be drawn differently.
    static let glyphLanding: Animation = .easeOut(duration: 0.12)

    /// An activity's tab trading what it shows, like the timer's quick starts for its countdown.
    static var tabStateChange: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0)
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The usage limits: each motion plays once, as something happens, so nothing moves at rest. The exceptions step on
    /// one shared beat while Claude Code works, and only while the open island shows them: Claude's logo here, and a
    /// working session's ring (`Agent`).
    enum Usage {
        /// A logo turning in as a peek or the tab comes out.
        static let turn: Animation = .spring(duration: 0.9, bounce: 0.45)
        static let turnFrom: Double = -90
        static let turnScale: Double = 0.6
        /// A logo popping in, one after another across the tab.
        static let pop: Animation = .spring(duration: 0.45, bounce: 0.5)
        static let popStagger: Double = 0.06
        static let popScale: Double = 0.4
        /// Antigravity's logo rising past its place and settling, as if weightless.
        static let float: Animation = .spring(duration: 1.0, bounce: 0.55)
        static let floatFrom: CGFloat = 7
        /// A bar filling to its level as the tab or a peek comes out.
        static let fill: Animation = .easeOut(duration: 0.75).delay(0.15)
        static let fillStagger: Double = 0.08
        /// The bar of a limit that started over, draining from full.
        static let drain: Animation = .easeOut(duration: 1.0).delay(0.4)
        /// One step of a beat: a pulse for urgency, a jump for good news.
        static let beat: Animation = .spring(duration: 0.22, bounce: 0.3)
        static let pulseScales: [Double] = [1, 1.3, 1, 1.2, 1]
        static let bounceOffsets: [Double] = [0, -6, 0, -2, 0]
        /// A logo whose limit ran out: smaller, tilted and dim, like it nodded off.
        static let fallAsleep: Animation = .easeInOut(duration: 1.2).delay(0.45)
        static let asleepScale: Double = 0.8
        static let asleepTilt: Double = -18
        static let asleepOpacity: Double = 0.45
        static let sparks: Animation = .easeOut(duration: 0.75).delay(0.4)
        static let sparkReach: CGFloat = 14
        /// The tab's large number rising into place.
        static let riseFrom: CGFloat = 7
        /// The tab coming in with Reduce Motion: only a fade.
        static let reducedFade: Animation = .easeOut(duration: 0.2)
        /// Claude's logo while Claude Code works, only while the open island shows it: a step of one ray each beat,
        /// with nothing moving in between. A turn that never stops cost about 25 CPU points in WindowServer (measured).
        static let workingBeat: TimeInterval = 2
        /// How long until the next beat. Beats fall on whole multiples of `workingBeat` on the clock, so everything
        /// stepping on it moves at the same moment and Jambul wakes once for all of it.
        static func untilNextBeat(after date: Date = .now) -> Duration {
            let into = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: workingBeat)
            return .seconds(workingBeat - into)
        }
        static let workingStep: Animation = .spring(duration: 0.6, bounce: 0.3)
        static let workingStepAngle: Double = 36
    }

    /// Claude Code's sessions: a finished turn's check, a failed turn's peek shaking its head, and a working session's
    /// ring in the open island.
    enum Agent {
        /// The check's circle pops in, past its size and back, as the peek comes out of its blur; the check then draws
        /// itself across it.
        static let checkPop: Animation = .spring(duration: 0.4, bounce: 0.45).delay(0.2)
        static let checkDraw: Animation = .easeOut(duration: 0.3).delay(0.35)
        /// The shake waits for the peek to come out, rather than playing while it is still blurred.
        static let shakeAfter: Duration = .milliseconds(350)
        static let shake: Animation = .spring(duration: 0.12, bounce: 0.2)
        static let shakeOffsets: [Double] = [0, -5, 5, -3, 3, 0]
        /// The ring of a working session turning an eighth on each beat (`Usage.untilNextBeat`), and only while the
        /// open island shows it. Nothing moves in between.
        static let workingStepAngle: Double = 45
    }
}
