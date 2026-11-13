import AppKit
import SwiftUI
import Testing
@testable import Jambul

/// The open island as drawn: what sits beside the notch, and where clicks on it land.
@MainActor
@Suite(.serialized)
final class OpenIslandTests {
    /// A 13-inch MacBook Air's notch, as measured on one.
    private let notch = NotchMetrics(size: CGSize(width: 179, height: 32), compactHeight: 33)
    private let activities = ActivityCenter()
    private let defaults: UserDefaults

    init() {
        let suiteName = "JambulTests.OpenIsland"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Jambul's activities as it registers them, none of them live: Home, the usage limits, Keep Awake, the timer and
    /// the battery. With `everyCard`, the battery has a reading and Claude is turned on, so Home shows all four cards;
    /// without, as on a Mac without a battery and with no subscription on, only Keep Awake's and the timer's.
    @discardableResult
    private func registerJambulsActivities(everyCard: Bool = true)
        -> (home: HomeActivity, timer: TimerActivity, keepAwake: KeepAwakeActivity) {
        let home = HomeActivity(activities: activities)
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        let keepAwake = KeepAwakeActivity(activities: activities, defaults: defaults, bootSession: nil, holdsScreen: false)
        let battery = BatteryActivity(activities: activities)
        let usage = UsageActivity(activities: activities)
        activities.registerJambulsActivities(home: home, usage: usage, keepAwake: keepAwake, timer: timer,
                                             battery: battery)
        if everyCard {
            battery.update(PowerState(percent: 76, isOnExternalPower: false))
            usage.enabled = [.claude]
        }
        return (home, timer, keepAwake)
    }

    /// Where the open island's left edge sits in its panel, which it hangs centered in.
    private var islandLeft: CGFloat {
        (IslandLayout.canvasSize(notch).width - IslandLayout.expandedSize.width) / 2
    }

    /// Toward the right of the card at `index` on Home, of `count` side by side, away from its symbol and its words,
    /// which sit on the left: the whole card is the button. The cards share the room below the notch, centered in its
    /// height.
    private func cardPoint(_ index: Int, of count: Int) -> CGPoint {
        let room = IslandLayout.expandedSize.width - 2 * IslandLayout.expandedContentInset
        let width = (room - CGFloat(count - 1) * HomeCardStyle.spacing) / CGFloat(count)
        let left = islandLeft + IslandLayout.expandedContentInset + CGFloat(index) * (width + HomeCardStyle.spacing)
        return CGPoint(x: left + width - 6, y: contentMiddle)
    }

    /// Every tab Jambul has fits beside the notch, the MacBook Air's measured one and wider ones too.
    @Test(arguments: [179, 190, 200, 210, 220] as [CGFloat])
    func everyTabFitsBesideTheNotch(notchWidth: CGFloat) {
        let (home, _, _) = registerJambulsActivities()
        let notch = NotchMetrics(size: CGSize(width: notchWidth, height: 32), compactHeight: 33)
        let tabs = activities.activities.filter(\.hasTab)
        let width = IslandLayout.tabButtonWidth(count: tabs.count, notch: notch)
        let bar = NSHostingView(rootView: IslandTabBar(tabs: tabs, selected: home.id, buttonWidth: width) { _ in })
            .fittingSize
        let room = IslandLayout.besideNotchRoom(notch)
        #expect(bar.width <= room, "\(tabs.count) tabs are \(bar.width) pt wide, with room for \(room)")
        #expect(bar.height <= notch.size.height)
    }

    /// The tabs beside the notch go Home, the usage limits, Keep Awake and the timer.
    @Test func theTabsGoHomeUsageKeepAwakeAndTheTimer() {
        registerJambulsActivities()
        let model = IslandModel(notch: notch, activities: activities)
        #expect(model.tabs.map(\.id) == ["home", "usage", "keepAwake", "timer"])
    }

    /// Beside the MacBook Air's notch, three tabs keep their full width and four narrow to fit, so the island keeps its
    /// size.
    @Test func tabsNarrowOnlyWhenTheyWouldntFit() {
        #expect(IslandLayout.tabButtonWidth(count: 3, notch: notch) == IslandLayout.tabButtonSize.width)
        #expect(IslandLayout.tabButtonWidth(count: 4, notch: notch) == 25)
    }

    /// Every day of the year at its widest times, in locales with a 24-hour clock and with a 12-hour one, since the
    /// clock writes the time as each person's locale does. It always fits, and it only drops the date or the day when
    /// they wouldn't fit.
    @Test(arguments: ["en_US", "en_GB", "en_ID", "id_ID", "de_DE", "fr_FR", "es_ES", "pt_BR", "ja_JP", "zh_Hans_CN",
                      "ko_KR", "hi_IN"])
    func theClockFitsBesideTheNotchOnEveryDayOfTheYear(localeID: String) throws {
        let room = IslandLayout.besideNotchRoom(notch)
        let locale = Locale(identifier: localeID)
        let timeZone = try #require(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        for day in 0..<365 {
            for hour in [10, 23] {
                let moment = DateComponents(year: 2026, month: 1, day: 1 + day, hour: hour, minute: 58)
                let date = try #require(calendar.date(from: moment))
                let lines = try IslandClockFace.days.map { day in
                    try width(of: IslandClockLine(date: date, day: day).environment(\.locale, locale)
                        .environment(\.timeZone, timeZone), proposedWidth: nil)
                }
                let face = IslandClockFace(date: date).environment(\.locale, locale).environment(\.timeZone, timeZone)
                let shown = try width(of: face, proposedWidth: room)
                guard let fitting = lines.first(where: { $0 <= room }), shown == fitting else {
                    Issue.record("\(localeID), \(date): \(shown) pt shown in \(room) pt, out of \(lines)")
                    return
                }
            }
        }
    }

    /// The open island draws nothing outside its own shape: a shadow there was cut off in a line by the window's edge.
    @Test func theOpenIslandDrawsNothingAroundItself() throws {
        registerJambulsActivities()
        let model = IslandModel(notch: notch, activities: activities, presentation: .expanded)
        let canvas = IslandLayout.canvasSize(notch)
        let renderer = ImageRenderer(content: IslandView(model: model).frame(width: canvas.width, height: canvas.height))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // From the top-left corner, as the island hangs from the top.
        func alpha(x: CGFloat, y: CGFloat) -> UInt8 { pixels[(Int(y) * width + Int(x)) * 4 + 3] }

        let bottom = IslandLayout.expandedSize.height
        let left = (canvas.width - IslandLayout.expandedSize.width) / 2
        #expect(alpha(x: canvas.width / 2, y: bottom - 4) == 255)
        for below in stride(from: CGFloat(2), to: IslandLayout.canvasMargin, by: 4) {
            #expect(alpha(x: canvas.width / 2, y: bottom + below) == 0, "\(below) pt below the island")
        }
        for beside in stride(from: CGFloat(2), to: IslandLayout.canvasMargin, by: 4) {
            #expect(alpha(x: left - beside, y: bottom / 2) == 0, "\(beside) pt left of the island")
        }
    }

    /// The width a view takes when offered `proposedWidth`, or all it wants when offered nothing.
    private func width(of view: some View, proposedWidth: CGFloat?) throws -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: proposedWidth, height: nil)
        return try #require(renderer.nsImage).size.width
    }

    @Test func aClickOnATabChangesTheTabAndLeavesTheIslandOpen() async throws {
        let (home, _, keepAwake) = registerJambulsActivities()
        let model = IslandModel(notch: notch, activities: activities, presentation: .expanded)
        #expect(model.selectedTab == home.id)
        let panel = try await openPanel(on: model)
        defer { panel.orderOut(nil) }

        // Near the left end of Keep Awake's tab, the third beside the notch, where its symbol doesn't reach: the whole
        // pill is the tab's. The tabs start at the island's content inset, centered in the notch's height.
        let canvas = IslandLayout.canvasSize(notch)
        let count = model.tabs.count
        let step = IslandLayout.tabButtonWidth(count: count, notch: notch) + IslandLayout.tabButtonSpacing
        let firstTab = islandLeft + IslandLayout.expandedContentInset
        let tab = CGPoint(x: firstTab + 2 * step + 3, y: canvas.height - notch.size.height / 2)
        click(panel, at: tab, count: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.selectedTab == keepAwake.id)
        #expect(model.presentation == .expanded)

        // Between the tabs and the notch, the click reaches the island itself, which closes.
        let besideTabs = CGPoint(x: firstTab + CGFloat(count) * step + 2, y: tab.y)
        click(panel, at: besideTabs, count: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.presentation != .expanded)
    }

    @Test func aClickOnAHomeCardOpensItsTabAndLeavesTheIslandOpen() async throws {
        let (home, _, keepAwake) = registerJambulsActivities()
        let model = IslandModel(notch: notch, activities: activities, presentation: .expanded)
        #expect(model.selectedTab == home.id)
        let panel = try await openPanel(on: model)
        defer { panel.orderOut(nil) }

        // Keep Awake's card, the second of four.
        click(panel, at: cardPoint(1, of: 4), count: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.selectedTab == keepAwake.id)
        #expect(model.presentation == .expanded)
    }

    /// The first click on a card opens its tab, which takes the card's place, so the rest of a double click would land
    /// on the tab. The timer's quick starts lie under its card, with four cards as with two (as on a Mac without a
    /// battery and with no subscription on), and the rest of the click would start a timer. The island stays open on
    /// the tab either way.
    @Test(arguments: [true, false])
    func theRestOfADoubleClickOnAHomeCardLeavesItsTabAsItIs(everyCard: Bool) async throws {
        let (_, timer, _) = registerJambulsActivities(everyCard: everyCard)
        let model = IslandModel(notch: notch, activities: activities, presentation: .expanded)
        let panel = try await openPanel(on: model)
        defer { panel.orderOut(nil) }

        // The timer's card, the third of four or the second of two.
        let card = everyCard ? cardPoint(2, of: 4) : cardPoint(1, of: 2)
        click(panel, at: card, count: 1)
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.selectedTab == timer.id)
        // Within a 0.5 s double-click interval.
        click(panel, at: card, count: 2)
        try await Task.sleep(for: .milliseconds(450))
        #expect(model.presentation == .expanded, "the rest of the double click closed the island")
        #expect(timer.state == .idle, "the rest of the double click started a timer")
        timer.stop()
    }

    // MARK: Double clicks on a tab's controls

    @Test func theRestOfADoubleClickOnKeepAwakesStopLeavesItOff() async throws {
        let (_, _, keepAwake) = registerJambulsActivities()
        keepAwake.start()
        let model = IslandModel(notch: notch, activities: activities, presentation: .expanded)
        model.selectTab(keepAwake.id)
        #expect(model.selectedTab == keepAwake.id)
        let panel = try await openPanel(on: model)
        defer { panel.orderOut(nil) }

        click(panel, at: stopButton, count: 1)
        try await Task.sleep(for: .milliseconds(120))
        #expect(!keepAwake.isOn)
        // Within a 0.5 s double-click interval, where Turn On would replace the stop button.
        click(panel, at: stopButton, count: 2)
        try await Task.sleep(for: .milliseconds(450))
        #expect(model.presentation == .expanded)
        #expect(!keepAwake.isOn, "the rest of the double click turned Keep Awake back on")
    }

    @Test func theRestOfADoubleClickOnTheTimersStopLeavesItStopped() async throws {
        let (_, timer, _) = registerJambulsActivities()
        timer.start(.seconds(300))
        let model = IslandModel(notch: notch, activities: activities, presentation: .expanded)
        model.selectTab(timer.id)
        #expect(model.selectedTab == timer.id)
        let panel = try await openPanel(on: model)
        defer { panel.orderOut(nil) }

        click(panel, at: stopButton, count: 1)
        try await Task.sleep(for: .milliseconds(120))
        #expect(timer.state == .idle)
        click(panel, at: stopButton, count: 2)
        try await Task.sleep(for: .milliseconds(450))
        #expect(model.presentation == .expanded)
        #expect(timer.state == .idle, "the rest of the double click started a timer")
        timer.stop()
    }

    /// The panel the island lives in, ordered in far off every screen, turning down presses as Jambul's does.
    private func openPanel(on model: IslandModel) async throws -> IslandPanel {
        let panel = IslandPanel(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000),
                                                    size: IslandLayout.canvasSize(notch)))
        panel.acceptsPress = { [weak model] in model?.acceptsPress(clickCount: $0) ?? true }
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        panel.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        return panel
    }

    /// Where a tab's stop button sits: the last 32 pt of its row, centered in the room below the notch.
    private var stopButton: CGPoint {
        let canvas = IslandLayout.canvasSize(notch)
        let right = (canvas.width + IslandLayout.expandedSize.width) / 2 - IslandLayout.expandedContentInset
        return CGPoint(x: right - IslandButtonStyle.height / 2, y: contentMiddle)
    }

    /// The height, in the panel, halfway down the room below the notch, where a tab's row is centered.
    private var contentMiddle: CGFloat {
        let top = notch.size.height + IslandLayout.expandedContentTopGap
        let bottom = IslandLayout.expandedSize.height - IslandLayout.expandedContentBottomInset
        return IslandLayout.canvasSize(notch).height - (top + bottom) / 2
    }

    private func click(_ panel: IslandPanel, at point: CGPoint, count: Int) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(mouseEvent(type, at: point, in: panel, clickCount: count))
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at location: CGPoint, in panel: NSWindow,
                            clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                           pressure: 1)!
    }
}
