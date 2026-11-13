import AppKit
import os
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let activities = ActivityCenter()
    private let preferences = Preferences()
    private lazy var settings = SettingsWindowController(preferences: preferences, usage: usage,
                                                                 agent: agent)
    private var island: IslandController?
    private var statusItem: NSStatusItem?
    private lazy var home = HomeActivity(activities: activities)
    private lazy var timer = TimerActivity(activities: activities, onFinish: { [preferences] in
        Feedback.play(preferences.timerSound)
        Feedback.playTaps(preferences.hapticTaps)
    })
    private lazy var battery = BatteryActivity(activities: activities)
    /// Made only when Jambul really launches: under tests it would pick up the running app's saved state and forget it.
    private var keepAwake: KeepAwakeActivity?
    private let power = PowerMonitor()
    /// Lazy like Keep Awake, for the same reason: it remembers the last numbers in the real settings.
    private lazy var usage = UsageActivity(activities: activities, defaults: .standard)
    private let antigravityUsage = AntigravityUsageSource()
    private let codexUsage = CodexUsageSource()
    private var usageSocket: InputSocket?
    private lazy var claudeStatusLine = ClaudeStatusLineInstaller(
        settingsURL: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json"),
        savedURL: Self.supportFolder.appending(path: "claude-statusline.json"),
        socketPath: Self.supportFolder.appending(path: "usage.sock").path)
    private lazy var agent = AgentActivity(activities: activities)
    private var agentSocket: InputSocket?
    /// The app in front before the one just activated, to tell unlocking the screen from the owner switching apps.
    private var lastActiveApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    private lazy var agentHooks = AgentHookInstaller(
        settingsURL: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json"),
        socketPath: Self.supportFolder.appending(path: "agent.sock").path)
    #if DEBUG
    private let demo = DemoActivity()
    #endif

    /// ~/Library/Application Support/Jambul. Short enough for the socket's path, which a Unix socket limits.
    private static var supportFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Jambul", directoryHint: .isDirectory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app; keep the island off the screen while they do.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        let keepAwake = KeepAwakeActivity(activities: activities)
        self.keepAwake = keepAwake
        activities.registerJambulsActivities(home: home, usage: usage, agent: agent, keepAwake: keepAwake,
                                             timer: timer, battery: battery)
        #if DEBUG
        activities.register(demo)
        #endif
        if let screen = NotchGeometry.preferredScreen() {
            let island = IslandController(screen: screen, activities: activities, preferences: preferences)
            island.show()
            self.island = island
        }
        startUsage()
        startAgent(keepAwake: keepAwake)
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

    // MARK: - Usage limits

    private func startUsage() {
        activities.onPeekShown = { [usage] in usage.peekWasShown($0) }
        usage.onTabAppear = { [usage, antigravityUsage] in
            if usage.enabled.contains(.antigravity) { antigravityUsage.refresh() }
        }
        usage.onConnect = { [weak self] _ in self?.openSettings() }
        antigravityUsage.onReading = { [usage] in usage.record($0) }
        antigravityUsage.onProblem = { [usage] in usage.markProblem(.antigravity, $0) }
        codexUsage.onReading = { [usage] in usage.record($0) }
        // The island applies its own settings; the usage settings ride along.
        let islandSettingsChanged = preferences.onChange
        preferences.onChange = { [weak self] in
            islandSettingsChanged?()
            self?.applyUsagePreferences()
        }
        // A limit may have started over during a sleep, and Antigravity's numbers moved on meanwhile.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.usage.checkResets()
                if self.usage.enabled.contains(.antigravity) { self.antigravityUsage.refresh() }
            }
        }
        applyUsagePreferences()
    }

    /// Starts and stops each source as the owner turns subscriptions on and off. Claude's status line changes only with
    /// the owner's agreement, and goes back as it was once Claude is off.
    private func applyUsagePreferences() {
        let wanted = preferences.usageProviders
        usage.enabled = UsageProvider.allCases.filter { wanted.contains($0) }
        let claudeAgreed = preferences.claudeStatusLineAgreed
        usage.needsConnecting = wanted.contains(.claude) && !claudeAgreed ? [.claude] : []

        if wanted.contains(.claude), claudeAgreed {
            startUsageSocket()
            // Writes nothing when the line is already right, and brings an older line of Jambul's up to date.
            do {
                try claudeStatusLine.install()
            } catch {
                usage.markProblem(.claude, String(localized: "Couldn’t change Claude Code’s settings"))
                Logger.app.error("usage: couldn't connect Claude Code's status line: \(error, privacy: .public)")
            }
        } else {
            if claudeStatusLine.isInstalled() {
                do {
                    try claudeStatusLine.uninstall()
                } catch {
                    Logger.app.error("usage: couldn't disconnect Claude Code's status line: \(error, privacy: .public)")
                }
            }
            usageSocket?.stop()
            usageSocket = nil
        }

        if wanted.contains(.antigravity) {
            antigravityUsage.start()
            antigravityUsage.refresh()
        } else {
            antigravityUsage.stop()
        }
        if wanted.contains(.codex) {
            codexUsage.start()
        } else {
            codexUsage.stop()
        }
    }

    private func startUsageSocket() {
        guard usageSocket == nil else { return }
        let socket = InputSocket(path: claudeStatusLine.socketPath) { [usage] input in
            let isCurrent = UsageParsing.claudeRequestTime(fromStatusLine: input).map {
                usage.noteClaudeRequestTime($0.milliseconds, session: $0.session)
            } ?? false
            guard let windows = UsageParsing.claudeWindows(fromStatusLine: input) else { return }
            usage.record(UsageReading(provider: .claude, windows: windows, measuredAt: .now), isCurrent: isCurrent)
        }
        do {
            try socket.start()
            usageSocket = socket
        } catch {
            usage.markProblem(.claude, String(localized: "Couldn’t listen for Claude Code"))
            Logger.app.error("usage: couldn't open the socket: \(error, privacy: .public)")
        }
    }

    // MARK: - Claude Code sessions

    private func startAgent(keepAwake: KeepAwakeActivity) {
        agent.onConnect = { [weak self] in self?.openSettings() }
        agent.onAllFinished = { [weak keepAwake] in keepAwake?.agentsFinished() }
        keepAwake.agentsAreWorking = { [agent] in agent.isLive }
        // In the terminal of a session waiting on the owner, they see its request.
        // Not when unlocking the screen brings the terminal back: nobody has seen the request yet.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.lastActiveApp = bundle }
                guard self.lastActiveApp != "com.apple.loginwindow" else { return }
                self.agent.appActivated(bundle)
            }
        }
        // Each change of settings already applies the island's and the usage limits'; the sessions ride along.
        let settingsChanged = preferences.onChange
        preferences.onChange = { [weak self] in
            settingsChanged?()
            self?.applyAgentPreferences()
        }
        applyAgentPreferences()
    }

    /// Adds Jambul's hooks to Claude Code as the owner turns its sessions on, and takes them out as they turn them off.
    private func applyAgentPreferences() {
        if preferences.showsAgentSessions {
            startAgentSocket()
            do {
                // Writes nothing when the hooks are already right.
                try agentHooks.install()
                if agentSocket != nil { agent.problem = nil }
            } catch {
                agent.problem = String(localized: "Couldn’t change Claude Code’s settings")
                Logger.app.error("agent: couldn't connect Claude Code's hooks: \(error, privacy: .public)")
            }
            agent.isConnected = true
        } else {
            if agentHooks.hasAny() {
                do {
                    try agentHooks.uninstall()
                } catch {
                    Logger.app.error("agent: couldn't disconnect Claude Code's hooks: \(error, privacy: .public)")
                }
            }
            agentSocket?.stop()
            agentSocket = nil
            agent.isConnected = false
            agent.problem = nil
            agent.forgetSessions()
            keepAwake?.stopWaitingForAgents()
        }
    }

    private func startAgentSocket() {
        guard agentSocket == nil else { return }
        let socket = InputSocket(path: agentHooks.socketPath, name: "Claude Code's hooks",
                                 keepsStartOfLargeInput: true) { [agent] in agent.receive($0) }
        do {
            try socket.start()
            agentSocket = socket
        } catch {
            agent.problem = String(localized: "Couldn’t listen for Claude Code")
            Logger.app.error("agent: couldn't open the socket: \(error, privacy: .public)")
        }
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

extension ActivityCenter {
    /// Registers Jambul's own activities, for the app, its previews and its tests alike. The order they register in is
    /// the order of the open island's tabs and of the cards on Home: Home first, where the island opens as Jambul
    /// starts, then the usage limits, Claude Code's sessions, Keep Awake and the timer. The battery has no tab, so its
    /// card comes last on Home. Between live activities of the same priority, the one registered first also takes the
    /// right beside the notch.
    func registerJambulsActivities(home: HomeActivity, usage: UsageActivity, agent: AgentActivity,
                                   keepAwake: KeepAwakeActivity, timer: TimerActivity, battery: BatteryActivity) {
        let inOrder: [any IslandActivity] = [home, usage, agent, keepAwake, timer, battery]
        for activity in inOrder { register(activity) }
    }
}
