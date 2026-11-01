import AppKit
import os
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let activities = ActivityCenter()
    private let preferences = Preferences()
    private lazy var settings = SettingsWindowController(preferences: preferences)
    private var island: IslandController?
    private var statusItem: NSStatusItem?
    private lazy var timer = TimerActivity(activities: activities, onFinish: { [preferences] in
        Feedback.play(preferences.timerSound)
        Feedback.playTaps(preferences.hapticTaps)
    })
    private lazy var battery = BatteryActivity(activities: activities)
    /// Made only when Jambul really launches: under tests it would pick up the running app's saved state and forget it.
    private var keepAwake: KeepAwakeActivity?
    private let power = PowerMonitor()
    #if DEBUG
    private let demo = DemoActivity()
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app; keep the island off the screen while they do.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        let keepAwake = KeepAwakeActivity(activities: activities)
        self.keepAwake = keepAwake
        activities.register(timer)
        activities.register(keepAwake)
        activities.register(battery)
        #if DEBUG
        activities.register(demo)
        #endif
        if let screen = NotchGeometry.preferredScreen() {
            let island = IslandController(screen: screen, activities: activities, preferences: preferences)
            island.show()
            self.island = island
        }
        statusItem = makeStatusItem()
        // Once the island is there for its peeks; the first reading is only a starting point.
        // The battery first, so its low-battery warning comes before Keep Awake saying it turned off.
        power.onChange = { [battery] in
            battery.update($0)
            keepAwake.update($0)
        }
        power.start()
        #if DEBUG
        // For measuring a running countdown without clicking. Quit Jambul first, or `open` only brings the running one
        // forward: pkill -x Jambul; open --env JAMBUL_START_TIMER=<seconds> Jambul.app
        if let value = ProcessInfo.processInfo.environment["JAMBUL_START_TIMER"] {
            if let seconds = Int(value), seconds > 0 {
                timer.start(.seconds(seconds))
            } else {
                Logger.app.error("JAMBUL_START_TIMER=\(value, privacy: .public) isn't a whole number of seconds above 0")
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting turns Keep Awake off for good. A build relaunches Jambul with pkill, which never comes here, so Keep
        // Awake stays on through that.
        keepAwake?.forgetOnQuit()
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Jambul")
        let menu = NSMenu()
        // Also here for while the island is hidden for a full-screen app.
        menu.addItem(withTitle: String(localized: "Keep Awake"), action: #selector(toggleKeepAwake), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: String(localized: "About Jambul"), action: #selector(showAbout), keyEquivalent: "")
            .target = self
        #if DEBUG
        menu.addItem(.separator())
        menu.addItem(makeDebugMenuItem())
        #endif
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Jambul"),
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        return item
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func toggleKeepAwake() {
        guard let keepAwake else { return }
        if keepAwake.isOn { keepAwake.stop() } else { keepAwake.start() }
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    #if DEBUG
    private func makeDebugMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(withTitle: "Demo Activity Live", action: #selector(toggleDemoActivity(_:)), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Show Demo Peek", action: #selector(showDemoPeek), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Start 10-Second Timer", action: #selector(startShortTimer), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Keep Awake Since 2 Hours Ago", action: #selector(startLongKeepAwake), keyEquivalent: "")
            .target = self
        let batteryPeeks = NSMenu()
        for (index, name) in BatteryActivity.sampleNames.enumerated() {
            let sample = batteryPeeks.addItem(withTitle: name, action: #selector(showBatteryPeek(_:)), keyEquivalent: "")
            sample.target = self
            sample.tag = index
        }
        menu.addItem(withTitle: "Battery Peek", action: nil, keyEquivalent: "").submenu = batteryPeeks
        let item = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// For trying the end of a timer on the notch without waiting minutes for it.
    @objc private func startShortTimer() {
        timer.start(.seconds(10))
    }

    /// For trying how the time on reads past an hour, without waiting one.
    @objc private func startLongKeepAwake() {
        keepAwake?.start(since: .now.addingTimeInterval(-2 * 3_600))
    }

    /// For trying each battery peek on the notch without draining the battery.
    @objc private func showBatteryPeek(_ sender: NSMenuItem) {
        battery.showSample(sender.tag)
    }

    @objc private func toggleDemoActivity(_ sender: NSMenuItem) {
        demo.isLive.toggle()
        sender.state = demo.isLive ? .on : .off
    }

    @objc private func showDemoPeek() {
        activities.peek(Peek(symbol: "bird.fill", tint: .orange, title: "Hello from Jambul", detail: "Demo peek"))
    }
    #endif
}

extension AppDelegate: NSMenuItemValidation {
    /// Ticks Keep Awake in the menu while it is on.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleKeepAwake) {
            item.state = keepAwake?.isOn == true ? .on : .off
        }
        return true
    }
}
