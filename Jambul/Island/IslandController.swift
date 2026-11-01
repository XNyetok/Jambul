import AppKit
import os
import SwiftUI

/// Owns the island's windows and keeps them on the notch.
///
/// Two panels split the pointer work: a notch-sized hot zone that is always listening, and a larger
/// island panel that only catches the pointer while the island is out. When idle, nothing outside
/// the notch blocks clicks.
@MainActor
final class IslandController: NSObject {
    private let model: IslandModel
    private let preferences: Preferences
    private let spaces = SpaceInspector()
    private let islandPanel: IslandPanel
    private let hotZonePanel: IslandPanel
    private let hotZone = NotchHotZoneView()
    private var screen: NSScreen
    private var geometry: NotchGeometry
    private var isShowingFullScreen = false
    private var isHidden = true
    private var hideTask: Task<Void, Never>?
    /// The event monitors following the pointer for `watchPointer`, while it watches.
    private var pointerMonitors: [Any] = []

    init(screen: NSScreen, activities: ActivityCenter, preferences: Preferences) {
        self.screen = screen
        geometry = NotchGeometry(screen: screen)
        self.preferences = preferences
        model = IslandModel(notch: geometry.metrics, activities: activities, defaults: .standard)
        islandPanel = IslandPanel(contentRect: .zero)
        hotZonePanel = IslandPanel(contentRect: .zero, levelOffset: 4)
        super.init()

        let host = NSHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        islandPanel.contentView = host
        islandPanel.ignoresMouseEvents = true

        hotZone.drawsNotch = geometry.hasPhysicalNotch
        hotZone.onHoverChange = { [weak model] in model?.pointer(.notch, isInside: $0) }
        hotZone.onClick = { [weak model] in model?.clicked() }
        hotZonePanel.contentView = hotZone
        hotZonePanel.ignoresMouseEvents = false

        model.hoverIntent = preferences.hoverSpeed.intent
        model.canBeSeen = { [weak self] in self?.islandCanBeSeen() ?? true }
        model.isPointerOnIsland = { [weak self] in self?.pointerIsOnIsland() ?? false }
        model.watchesPointer = { [weak self] in self?.watchPointer($0) }
        model.onPresentationChange = { [weak self] in self?.presentationWillChange(from: $0, to: $1) }
        islandPanel.acceptsPress = { [weak model] in model?.acceptsPress(clickCount: $0) ?? true }
        hotZonePanel.acceptsPress = { [weak model] in model?.acceptsPress(clickCount: $0) ?? true }
        preferences.onChange = { [weak self] in self?.preferencesChanged() }
        layoutPanels()

        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(activeSpaceChanged),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.didWakeNotification] {
            workspace.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
        }
        // Delivered at once: AppKit holds back distributed notifications while the app isn't active, and Jambul only
        // is for a moment after Settings or About.
        for name in [Self.screenLocked, Self.screenUnlocked] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(visibilityChanged),
                                                                name: Notification.Name(name), object: nil,
                                                                suspensionBehavior: .deliverImmediately)
        }
    }

    func show() {
        isShowingFullScreen = spaces.isShowingFullScreen(screen)
        applyVisibility()
    }

    private func presentationWillChange(from previous: IslandPresentation, to next: IslandPresentation) {
        islandPanel.ignoresMouseEvents = next == .idle
        if isHidden { followWhileHidden(isOut: next != .idle && next != .compact) }
        // Tap as the pointer reaches the notch: a finger is on the trackpad then, and haptics are only felt through
        // a resting finger. By the time the island opens it has often lifted.
        if next == .lifted, previous == .idle || previous == .compact {
            Feedback.playTaps(preferences.hapticTaps)
        }
    }

    private func preferencesChanged() {
        model.hoverIntent = preferences.hoverSpeed.intent
        applyVisibility()
    }

    /// Orders the panels in, or out while the owner wants the island gone during full screen.
    private func applyVisibility() {
        let hide = preferences.hidesInFullScreen && isShowingFullScreen
        // Before the guard: the panels start out hidden, and at launch the model must hear it too.
        model.isHidden = hide
        model.isFullScreen = isShowingFullScreen
        guard hide != isHidden else { return }
        isHidden = hide
        if hide {
            model.reset()
            hideTask?.cancel()
            hotZonePanel.orderOut(nil)
            // A peek the owner must see stays out; the island goes once it is back at rest (`followWhileHidden`).
            if model.isResting { islandPanel.orderOut(nil) }
        } else {
            hideTask?.cancel()
            islandPanel.orderFrontRegardless()
            hotZonePanel.orderFrontRegardless()
        }
        Logger.island.notice("island \(hide ? "hidden while an app is full screen" : "shown", privacy: .public)")
    }

    /// While hidden, the island still comes out for a peek the owner must see: its window shows until the island is
    /// back at rest, and goes once that motion is over. The notch's hot zone stays hidden, so hovering the notch in
    /// the full-screen app still does nothing.
    private func followWhileHidden(isOut: Bool) {
        hideTask?.cancel()
        if isOut {
            guard !islandPanel.isVisible else { return }
            islandPanel.orderFrontRegardless()
            Logger.island.notice("island out for a peek while hidden")
        } else if islandPanel.isVisible {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: Motion.returnToRest, tolerance: Motion.timerTolerance)
                guard !Task.isCancelled, let self, isHidden else { return }
                islandPanel.orderOut(nil)
                Logger.island.notice("island hidden again")
            }
        }
    }

    /// Whether anyone can see the island: its display is awake, the screen isn't locked, and this session is the one
    /// on screen. The lock comes from the session's dictionary, under a key Apple doesn't document; without the key,
    /// the screen counts as unlocked.
    private func islandCanBeSeen() -> Bool {
        if let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           CGDisplayIsAsleep(display) != 0 {
            return false
        }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        let isLocked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        let isOnConsole = session["kCGSSessionOnConsoleKey"] as? Bool ?? true
        return !isLocked && isOnConsole
    }

    private func pointerIsOnIsland() -> Bool {
        model.layout.frame(hangingFrom: islandPanel.frame).contains(NSEvent.mouseLocation)
    }

    /// Follows the pointer for the model while hover waits for it to leave a peek it never came for: at most the
    /// peek's few seconds, so it costs nothing at rest. Moves over other apps reach the global monitor, and moves over
    /// Jambul's own panels the local one.
    private func watchPointer(_ watching: Bool) {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors = []
        guard watching else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let check: @MainActor () -> Void = { [weak self] in
            guard let self, !pointerIsOnIsland() else { return }
            model.pointerIsOffIsland()
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: moves) { _ in
            MainActor.assumeIsolated { check() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: moves) { event in
            MainActor.assumeIsolated { check() }
            return event
        }
        pointerMonitors = [global, local].compactMap { $0 }
    }

    private nonisolated static let screenLocked = "com.apple.screenIsLocked"
    private nonisolated static let screenUnlocked = "com.apple.screenIsUnlocked"
    /// The notifications after which nobody can see the island. Taken at their word, since the session's lock key may
    /// lag behind them.
    private nonisolated static let outOfSight: Set<String> = [
        screenLocked, NSWorkspace.screensDidSleepNotification.rawValue,
        NSWorkspace.sessionDidResignActiveNotification.rawValue,
    ]

    /// The display sleeping or waking, the screen locking or unlocking, the session switching. Hops to the main actor
    /// rather than rely on where distributed notifications arrive.
    @objc nonisolated private func visibilityChanged(_ notification: Notification) {
        let name = notification.name.rawValue
        let isOutOfSight = Self.outOfSight.contains(name)
        Task { @MainActor in
            let canBeSeen = self.islandCanBeSeen()
            Logger.island.notice("\(name, privacy: .public): island \(canBeSeen ? "can" : "can't", privacy: .public) be seen")
            if isOutOfSight {
                self.model.islandWentOutOfSight()
            } else {
                self.model.visibilityMayHaveChanged()
            }
        }
    }

    private func layoutPanels() {
        islandPanel.setFrame(geometry.panelFrame(size: IslandLayout.canvasSize(geometry.metrics)), display: true)
        let hotZoneFrame = geometry.hotZoneFrame
        hotZonePanel.setFrame(hotZoneFrame, display: true)
        hotZone.notchFrame = geometry.notchRect.offsetBy(dx: -hotZoneFrame.minX, dy: -hotZoneFrame.minY)
    }

    @objc private func screenParametersChanged() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        self.screen = screen
        let updated = NotchGeometry(screen: screen)
        guard updated != geometry else { return }
        geometry = updated
        model.notch = updated.metrics
        hotZone.drawsNotch = updated.hasPhysicalNotch
        layoutPanels()
    }

    @objc private func activeSpaceChanged() {
        let fullScreen = spaces.isShowingFullScreen(screen)
        guard fullScreen != isShowingFullScreen else { return }
        isShowingFullScreen = fullScreen
        Logger.island.notice("\(fullScreen ? "entered" : "left", privacy: .public) a full-screen space")
        applyVisibility()
    }
}
