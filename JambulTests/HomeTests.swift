import AppKit
import SwiftUI
import Testing
@testable import Jambul

@MainActor
private final class Calls {
    var count = 0
}

/// Home, the open island's first tab: where the island first opens, which activities have a card on it, and what their
/// cards say.
@MainActor
final class HomeTests {
    private let activities = ActivityCenter()
    private let defaults: UserDefaults

    init() {
        let suiteName = "JambulTests.Home"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func homeIsWhereTheIslandFirstOpensAndItNeverComesBesideTheNotch() {
        let home = HomeActivity(activities: activities)
        activities.register(home)
        activities.register(TabbedTestActivity(id: "timer", isLive: true))
        #expect(home.hasTab)
        #expect(!home.isLive)
        #expect(!home.hasHomeCard)

        let model = IslandModel(notch: NotchMetrics(size: CGSize(width: 179, height: 32), compactHeight: 33),
                                activities: activities)
        #expect(model.compactActivities.map(\.id) == ["timer"])
        model.clicked()
        #expect(model.selectedTab == home.id)
    }

    @Test func cardsShowInTheOrderJambulRegistersThemOnceTheyHaveSomethingToSay() {
        let home = HomeActivity(activities: activities)
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        let keepAwake = KeepAwakeActivity(activities: activities, defaults: defaults, bootSession: nil, holdsScreen: false)
        let battery = BatteryActivity(activities: activities)
        let usage = UsageActivity(activities: activities)
        activities.registerJambulsActivities(home: home, usage: usage, agent: AgentActivity(activities: activities),
                                             keepAwake: keepAwake, timer: timer, battery: battery)
        var cards: [String] { activities.activities.filter(\.showsHomeCard).map(\.id) }

        // Before the battery's first reading, as on a Mac without one, and with every subscription turned off.
        #expect(cards == [keepAwake.id, timer.id])
        battery.update(PowerState(percent: 76, isOnExternalPower: false))
        usage.enabled = [.claude]
        // In the tabs' order, and the battery's, which has no tab, last.
        #expect(cards == [usage.id, keepAwake.id, timer.id, battery.id])
        usage.enabled = []
        #expect(cards == [keepAwake.id, timer.id, battery.id])
    }

    /// Each subscription the owner turned on fits on the usage card, as wide as one of four beside the MacBook Air's
    /// notch, and with three the card's name gives way to them.
    @Test(arguments: [1, 2, 3])
    func theUsageCardFitsEverySubscription(count: Int) {
        let usage = UsageActivity(activities: activities)
        usage.enabled = Array(UsageProvider.allCases.prefix(count))
        let padding = HomeCardStyle.padding
        let content = IslandLayout.expandedSize.width - 2 * IslandLayout.expandedContentInset
        let room = (content - 3 * HomeCardStyle.spacing) / 4 - padding.leading - padding.trailing
        let height = NSHostingView(rootView: usage.homeCard.frame(width: room)).fittingSize.height
        let inner = HomeCardStyle.height - padding.top - padding.bottom
        #expect(height <= inner, "\(count) subscriptions take \(height) pt, with room for \(inner)")
    }

    /// Like the usage tab, the card asks for numbers as it appears on Home, and the sources fetch only ones that are old.
    @Test func homeAsksForTheUsageNumbersAsItShowsThem() async throws {
        let usage = UsageActivity(activities: activities)
        activities.register(HomeActivity(activities: activities))
        activities.register(usage)
        let asked = Calls()
        usage.onTabAppear = { asked.count += 1 }
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 408, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: HomeTab(center: activities))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(50))
        // With every subscription off, there's no card to ask.
        #expect(asked.count == 0)

        usage.enabled = [.antigravity]
        try await Task.sleep(for: .milliseconds(50))
        #expect(asked.count == 1)
    }

    @Test func keepAwakesCardSaysOnUntilAMinuteHasPassed() {
        let since = Date(timeIntervalSinceReferenceDate: 0)
        #expect(KeepAwakeActivity.onFor(since: since, at: since.addingTimeInterval(59)) == "On")
        #expect(KeepAwakeActivity.onFor(since: since, at: since.addingTimeInterval(60)) == "1m")
        #expect(KeepAwakeActivity.onFor(since: since, at: since.addingTimeInterval(65 * 60)) == "1h 05m")
    }
}
