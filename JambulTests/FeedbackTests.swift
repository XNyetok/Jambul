import Foundation
import Testing
@testable import Jambul

@MainActor
struct FeedbackTests {
    /// The first sound after launch spent up to 0.2 s setting up audio, and on the main thread that stalled the "Timer
    /// done" peek as it opened. A stand-in that takes as long makes no sound.
    @Test func playingASoundLeavesTheMainThreadFree() {
        let started = DispatchSemaphore(value: 0)
        let sounds = SoundPlayer { _ in
            Thread.sleep(forTimeInterval: 0.2)
            started.signal()
            return nil
        }
        let took = ContinuousClock().measure {
            sounds.play((name: "Glass", url: URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")))
        }
        #expect(took < .milliseconds(20))
        // It still starts, on the player's own queue.
        #expect(started.wait(timeout: .now() + 2) == .success)
    }
}
