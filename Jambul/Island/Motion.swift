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

    /// How long the island takes to come back to rest. Hidden for a full-screen app, its window only goes once that
    /// motion is over, so a peek that came out shrinks away rather than vanishing.
    static let returnToRest: Duration = .milliseconds(500)

    /// A control inside the island sinking under the pointer and springing back.
    static let buttonPress: Animation = .spring(duration: 0.2, bounce: 0)

    /// Keep Awake's eye blinking: shut and open again in this long.
    static let eyeBlink: TimeInterval = 0.3
    /// When in a blink the eye is shut: it snaps shut over the first 40% and eases open over the rest.
    static let eyeBlinkShutAt: Double = 0.4
    /// How far the eye squeezes shut: a thin line, as a closed eye reads.
    static let eyeShut: CGFloat = 0.1
    /// The wait between blinks, a little different each time so the eye reads as alive rather than ticking. Nothing
    /// moves in between, so the eye costs next to nothing (measured: no more WindowServer CPU than with it off); an
    /// animation that never stops cost WindowServer about 16 CPU points.
    static let eyeBlinkGap: ClosedRange<TimeInterval> = 8...12
    /// How late a blink may come. They are a little random anyway, so the system may line them up with other work.
    static let eyeBlinkTolerance: Duration = .milliseconds(500)
    /// The eye shutting, in a blink and as Keep Awake turns off.
    static var eyeShutting: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeIn) }
    /// The eye opening, after a blink and as Keep Awake turns on.
    static var eyeOpening: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
    /// The eye opening as Keep Awake turns on.
    static let eyeOpen: TimeInterval = 0.35
    /// The eye closing as Keep Awake turns off. Keep Awake leaves the island once it has closed, and the laptop's code
    /// clears in the same time.
    static let eyeClose: Duration = .milliseconds(300)
    /// Keep Awake's laptop typing one line of its code, in a few steps as characters appear. The three lines take about
    /// 0.56 s on each beat, against the 0.3 s of the eye's blink beside it.
    static let laptopLineTyping: TimeInterval = 0.16
    /// From one line starting to the next.
    static let laptopLineGap: TimeInterval = 0.2

    /// The lift as the pointer arrives. Slow and unbouncy, so it is still moving near top speed when the hover intent
    /// ends and flows straight into opening. A quicker, bouncier lift settled first, and opening then read as a
    /// second step after a pause.
    static let arrivalLift = Spring(duration: 0.55, bounce: 0)

    static func animation(from previous: IslandPresentation, to next: IslandPresentation) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.18) }
        switch next {
        case .idle: return .spring(duration: 0.35, bounce: 0)
        case .compact: return .spring(duration: 0.4, bounce: 0.2)
        case .lifted:
            // Folding back after a click is a close, so it moves like one.
            return previous == .expanded ? .spring(duration: 0.35, bounce: 0) : .spring(arrivalLift)
        case .peek, .expanded: return .spring(duration: 0.45, bounce: 0.25)
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

    /// An activity's tab trading what it shows, like the timer's quick starts for its countdown.
    static var tabStateChange: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0)
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
