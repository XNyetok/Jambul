import Testing
@testable import Jambul

/// Battery peeks from sequences of readings, as IOKit would report them.
@MainActor
struct BatteryActivityTests {
    private let activities = ActivityCenter()
    private let log = PeekLog()

    init() {
        activities.onPeek = { [log] in log.peeks.append($0) }
    }

    private func battery(startingAt first: PowerState?) -> BatteryActivity {
        let battery = BatteryActivity(activities: activities)
        battery.update(first)
        return battery
    }

    private func onBattery(_ percent: Int) -> PowerState { PowerState(percent: percent, isOnExternalPower: false) }
    private func pluggedIn(_ percent: Int) -> PowerState { PowerState(percent: percent, isOnExternalPower: true) }

    @Test func theFirstReadingIsOnlyAStartingPoint() {
        let battery = battery(startingAt: onBattery(15))
        battery.update(onBattery(15))
        #expect(log.peeks.isEmpty)
        // 20% was already behind it, so only 5% is still to come.
        battery.update(onBattery(5))
        #expect(log.lines == ["Low battery 5%"])
    }

    @Test func pluggingInSaysCharging() {
        let battery = battery(startingAt: onBattery(62))
        battery.update(pluggedIn(62))
        #expect(log.lines == ["Charging 62%"])
        #expect(log.peeks.first?.mustBeSeen == false)
    }

    @Test func pluggingInWhenFullSaysFullyCharged() {
        let battery = battery(startingAt: onBattery(100))
        battery.update(pluggedIn(100))
        battery.update(pluggedIn(100))
        #expect(log.lines == ["Fully charged 100%"])
    }

    @Test func unpluggingSaysOnBattery() {
        let battery = battery(startingAt: pluggedIn(80))
        battery.update(onBattery(80))
        #expect(log.lines == ["On battery 80%"])
    }

    @Test func aLowBatteryWarnsAt20And5Only() {
        let battery = battery(startingAt: onBattery(25))
        // macOS warns at 10% itself.
        for percent in [24, 21, 20, 19, 11, 10, 9, 6, 5, 4, 2, 1] {
            battery.update(onBattery(percent))
        }
        #expect(log.lines == ["Low battery 20%", "Low battery 5%"])
    }

    @Test func aLowBatteryIsAWarningTheOwnerMustSee() throws {
        let battery = battery(startingAt: onBattery(21))
        battery.update(onBattery(20))
        let peek = try #require(log.peeks.first)
        #expect(peek.mustBeSeen)
        #expect(peek.duration == BatteryActivity.lowPeekDuration)
        #expect(peek.source == battery.id)
    }

    @Test func aDropPastBothLevelsWarnsOnce() {
        // As across a sleep.
        let battery = battery(startingAt: onBattery(30))
        battery.update(onBattery(4))
        battery.update(onBattery(3))
        #expect(log.lines == ["Low battery 4%"])
    }

    @Test func chargingBringsTheWarningsBack() {
        let battery = battery(startingAt: onBattery(21))
        battery.update(onBattery(20))
        battery.update(pluggedIn(20))
        battery.update(pluggedIn(25))
        battery.update(onBattery(25))
        battery.update(onBattery(20))
        #expect(log.lines == ["Low battery 20%", "Charging 20%", "On battery 25%", "Low battery 20%"])
    }

    @Test func unpluggingBelowALevelDoesntWarnForIt() {
        // Plugging in brings the warnings back, so this unplugs with 20% still to come.
        let battery = battery(startingAt: onBattery(15))
        battery.update(pluggedIn(15))
        battery.update(onBattery(16))
        battery.update(onBattery(15))
        battery.update(onBattery(5))
        #expect(log.lines == ["Charging 15%", "On battery 16%", "Low battery 5%"])
    }

    @Test func startingOnTheChargerLeavesTheWarningsArmed() {
        let battery = battery(startingAt: pluggedIn(15))
        for percent in [50, 80] {
            battery.update(pluggedIn(percent))
        }
        for percent in [80, 21, 20, 10, 5] {
            battery.update(onBattery(percent))
        }
        #expect(log.lines == ["On battery 80%", "Low battery 20%", "Low battery 5%"])
    }

    @Test func aReadingThatMissesTheBatteryChangesNothing() {
        let battery = battery(startingAt: onBattery(25))
        battery.update(onBattery(21))
        battery.update(nil)
        battery.update(onBattery(20))
        battery.update(pluggedIn(20))
        battery.update(nil)
        battery.update(onBattery(20))
        #expect(log.lines == ["Low battery 20%", "Charging 20%", "On battery 20%"])
    }

    @Test func chargingFullSaysSoOncePerCharge() {
        let battery = battery(startingAt: onBattery(90))
        for percent in [90, 99, 100, 100] {
            battery.update(pluggedIn(percent))
        }
        battery.update(onBattery(100))
        battery.update(pluggedIn(100))
        #expect(log.lines == ["Charging 90%", "Fully charged 100%", "On battery 100%", "Fully charged 100%"])
    }

    @Test func aMacThatStartsFullAndPluggedInDoesntSayFull() {
        let battery = battery(startingAt: pluggedIn(100))
        battery.update(pluggedIn(100))
        #expect(log.peeks.isEmpty)
    }

    @Test func theChargeChangingWhilePluggedInSaysNothing() {
        let battery = battery(startingAt: pluggedIn(40))
        for percent in [41, 60, 80, 99, 98] {
            battery.update(pluggedIn(percent))
        }
        #expect(log.peeks.isEmpty)
    }

    @Test func aMacWithoutABatterySaysNothing() {
        let battery = battery(startingAt: nil)
        battery.update(nil)
        battery.update(nil)
        #expect(log.peeks.isEmpty)
        #expect(!battery.isLive)
    }

    @Test func aBatteryFoundLaterStartsFresh() {
        // IOKit can take a while to find the battery at boot.
        let battery = battery(startingAt: nil)
        battery.update(onBattery(15))
        #expect(log.peeks.isEmpty)
    }

    @Test func theSymbolFollowsTheCharge() {
        #expect(BatteryActivity.symbol(for: 100) == "battery.100")
        #expect(BatteryActivity.symbol(for: 62) == "battery.50")
        #expect(BatteryActivity.symbol(for: 20) == "battery.25")
        #expect(BatteryActivity.symbol(for: 5) == "battery.0")
    }
}

@MainActor
private final class PeekLog {
    var peeks: [Peek] = []

    /// "Title detail" for each peek, like "Charging 62%".
    var lines: [String] {
        peeks.map { [$0.title, $0.detail].compactMap { $0 }.joined(separator: " ") }
    }
}
