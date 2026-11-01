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

    /// The timer and Keep Awake, as Jambul registers them, neither of them live.
    private func registerTabs() -> (timer: TimerActivity, keepAwake: KeepAwakeActivity) {
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        let keepAwake = KeepAwakeActivity(activities: activities, defaults: defaults, bootSession: nil, holdsScreen: false)
        activities.register(timer)
        activities.register(keepAwake)
        return (timer, keepAwake)
    }

    @Test func theTabsFitBesideTheNotch() {
        let (timer, keepAwake) = registerTabs()
        let bar = NSHostingView(rootView: IslandTabBar(tabs: [timer, keepAwake], selected: timer.id) { _ in }).fittingSize
        let room = IslandLayout.besideNotchRoom(notch)
        #expect(bar.width <= room, "the tabs are \(bar.width) pt wide, with room for \(room)")
        #expect(bar.height <= notch.size.height)
    }

    @Test func theClockFitsBesideTheNotchOnEveryDayOfTheYear() throws {
        let room = IslandLayout.besideNotchRoom(notch)
        let calendar = Calendar.current
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 23, minute: 58)))
        var widest: (width: CGFloat, date: Date) = (0, start)
        for day in 0..<365 {
            let date = try #require(calendar.date(byAdding: .day, value: day, to: start))
            let width = NSHostingView(rootView: IslandClockFace(date: date)).fittingSize.width
            if width > widest.width { widest = (width, date) }
        }
        #expect(widest.width <= room, "\(widest.date) is \(widest.width) pt wide, with room for \(room)")
    }

    @Test func aClickOnATabChangesTheTabAndLeavesTheIslandOpen() async throws {
        let (timer, keepAwake) = registerTabs()
        let model = IslandModel(notch: notch, activities: activities, presentation: .expanded)
        #expect(model.selectedTab == timer.id)
        let canvas = IslandLayout.canvasSize(notch)
        // A window only takes clicks while it is ordered in; this one sits far off every screen.
        let panel = IslandPanel(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: canvas))
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))

        // Near the left end of Keep Awake's tab, the second beside the notch, where its symbol doesn't reach: the whole
        // pill is the tab's. The island hangs centered in its panel, and the tabs start at its content's inset,
        // centered in the notch's height.
        let secondTab = (canvas.width - IslandLayout.expandedSize.width) / 2 + IslandLayout.expandedContentInset
            + IslandLayout.tabButtonSize.width + IslandLayout.tabButtonSpacing
        let tab = CGPoint(x: secondTab + 4, y: canvas.height - notch.size.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(mouseEvent(type, at: tab, in: panel))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.selectedTab == keepAwake.id)
        #expect(model.presentation == .expanded)

        // Between the tabs and the notch, the click reaches the island itself, which closes.
        let besideTabs = CGPoint(x: secondTab + IslandLayout.tabButtonSize.width + 12, y: tab.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(mouseEvent(type, at: besideTabs, in: panel))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.presentation != .expanded)
    }

    // MARK: Double clicks on a tab's controls

    @Test func theRestOfADoubleClickOnKeepAwakesStopLeavesItOff() async throws {
        let (_, keepAwake) = registerTabs()
        keepAwake.start()
        let model = IslandModel(notch: notch, activities: activities, presentation: .expanded)
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
        let (timer, _) = registerTabs()
        timer.start(.seconds(300))
        let model = IslandModel(notch: notch, activities: activities, presentation: .expanded)
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
        let top = notch.size.height + IslandLayout.expandedContentTopGap
        let bottom = IslandLayout.expandedSize.height - IslandLayout.expandedContentBottomInset
        return CGPoint(x: right - IslandButtonStyle.height / 2, y: canvas.height - (top + bottom) / 2)
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
