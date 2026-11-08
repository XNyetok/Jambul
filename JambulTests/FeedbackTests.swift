import Foundation
import Testing
@testable import Jambul

@MainActor
struct FeedbackTests {
    /// The first sound after launch spent up to 0.2 s setting up audio, and on the main thread that stalled the "Timer
    /// done" peek as it opened. The stand-in makes no sound and can't finish starting until the test is past `play`,
    /// so a `play` that waits for the sound to start fails. `play` itself isn't timed, since CI's shared machines
    /// stall now and then; the timeouts only turn a hang into a failure.
    @Test func playingASoundLeavesTheMainThreadFree() {
        let returned = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let sounds = SoundPlayer { _ in
            if returned.wait(timeout: .now() + 5) == .success { started.signal() }
            return nil
        }
        sounds.play((name: "Glass", url: URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")))
        returned.signal()
        #expect(started.wait(timeout: .now() + 5) == .success)
    }
}
