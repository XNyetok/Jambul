import Foundation
import Testing
@testable import Jambul

/// One defaults domain of their own, emptied for each test, so nothing touches the real settings. The tests take turns
/// with it; a fresh domain per test left an empty file behind in ~/Library/Preferences for every one.
@MainActor
@Suite(.serialized)
struct PreferencesTests {
    private let suiteName = "JambulTests.Preferences"

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test func startsWithTheAgreedDefaults() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            #expect(preferences.hoverSpeed == .normal)
            #expect(preferences.hapticTaps == 2)
            #expect(!preferences.hidesInFullScreen)
            #expect(preferences.timerSound == "Glass")
            #expect(!preferences.showsAgentSessions)
        }
    }

    @Test func remembersChangesAcrossLaunches() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.hoverSpeed = .fast
            preferences.hapticTaps = 3
            preferences.hidesInFullScreen = true
            preferences.timerSound = "Hero"
            preferences.showsAgentSessions = true

            let relaunched = Preferences(defaults: defaults)
            #expect(relaunched.hoverSpeed == .fast)
            #expect(relaunched.hapticTaps == 3)
            #expect(relaunched.hidesInFullScreen)
            #expect(relaunched.showsAgentSessions)
            #expect(relaunched.timerSound == "Hero")
        }
    }

    @Test func remembersATimerWithoutSound() {
        withDefaults { defaults in
            Preferences(defaults: defaults).timerSound = nil
            #expect(Preferences(defaults: defaults).timerSound == nil)
        }
    }

    @Test func aTimerSoundThatsGoneFallsBackToTheDefault() {
        withDefaults { defaults in
            defaults.set("Kentongan", forKey: "timerSound")
            #expect(Preferences(defaults: defaults).timerSound == Preferences.defaultTimerSound)
        }
    }

    @Test func theDefaultTimerSoundShipsWithMacOS() {
        #expect(Feedback.systemSounds[Preferences.defaultTimerSound] != nil)
        #expect(Feedback.systemSoundNames.contains("Hero"))
    }

    @Test func reportsEachChange() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            let changes = Counter()
            preferences.onChange = { changes.value += 1 }
            preferences.hapticTaps = 0
            preferences.hoverSpeed = .slow
            #expect(changes.value == 2)
        }
    }

    @Test func keepsTapCountsInRange() {
        withDefaults { defaults in
            defaults.set(9, forKey: "hapticTaps")
            #expect(Preferences(defaults: defaults).hapticTaps == 3)
        }
    }

    @Test func hoverSpeedsGetSlowerInOrder() {
        #expect(HoverSpeed.fast.intent == .zero)
        #expect(HoverSpeed.normal.intent == .milliseconds(60))
        #expect(HoverSpeed.normal.intent < HoverSpeed.slow.intent)
        // Past about 100 ms the wait reads as lag; even slow should only just cross it.
        #expect(HoverSpeed.slow.intent <= .milliseconds(150))
    }
}

@MainActor
private final class Counter {
    var value = 0
}
