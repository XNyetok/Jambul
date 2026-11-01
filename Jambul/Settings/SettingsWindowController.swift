import AppKit
import SwiftUI

/// The Settings window. Jambul has no Dock icon, so showing it also brings the app forward.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let preferences: Preferences
    private let usage: UsageActivity?
    private let loginItem = LoginItem()
    private lazy var window = makeWindow()

    init(preferences: Preferences, usage: UsageActivity? = nil) {
        self.preferences = preferences
        self.usage = usage
    }

    func show() {
        loginItem.refresh()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Approval may have changed in System Settings while the window was in the background.
    func windowDidBecomeKey(_ notification: Notification) {
        loginItem.refresh()
    }

    private func makeWindow() -> NSWindow {
        let content = SettingsView(preferences: preferences, loginItem: loginItem, usage: usage)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = String(localized: "Jambul Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}
