import Foundation
import Testing

/// Waits until `condition` holds, and fails the test after `timeout`. Use it for a check that something has happened
/// rather than a fixed sleep: when a CI machine stalls, timers that come due during the stall can run in either order.
@MainActor
func waitUntil(timeout: Duration = .seconds(2), sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            // A stall across the deadline can hold back what the condition waits for, so it gets one more turn.
            try await Task.sleep(for: .milliseconds(1))
            try #require(condition(), "timed out", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
