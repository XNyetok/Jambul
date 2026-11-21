import AppKit
import SwiftUI

/// The Settings window: a tab in its toolbar for each pane, and as tall as the pane it shows. Jambul has no Dock icon,
/// so showing it also brings the app forward.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let preferences: Preferences
    private let usage: UsageActivity?
    private let agent: AgentActivity?
    private let loginItem = LoginItem()
    private lazy var tabs = makeTabs()
    private lazy var window = makeWindow()

    init(preferences: Preferences, usage: UsageActivity? = nil, agent: AgentActivity? = nil) {
        self.preferences = preferences
        self.usage = usage
        self.agent = agent
    }

    /// Shows the window on `pane`, or on the pane it showed last.
    func show(_ pane: SettingsPane? = nil) {
        loginItem.refresh()
        if let pane { tabs.selectedTabViewItemIndex = pane.rawValue }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Approval may have changed in System Settings while the window was in the background.
    func windowDidBecomeKey(_ notification: Notification) {
        loginItem.refresh()
    }

    private func makeTabs() -> SettingsTabs {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let controller = switch pane {
            case .general: Self.pane(GeneralSettingsView(preferences: preferences, loginItem: loginItem))
            case .aiTools: Self.pane(AIToolsSettingsView(preferences: preferences, usage: usage, agent: agent))
            }
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        return tabs
    }

    /// A pane whose preferred size is its SwiftUI content's, so the window can follow it.
    private static func pane(_ content: some View) -> NSViewController {
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        tabs.fitWindow(animated: false)
        window.center()
        return window
    }
}

/// Tabs that size their window to the pane they show, keeping its top edge in place, as a pane changes and as the pane
/// showing grows or shrinks. AppKit doesn't tell a tab controller when a pane's preferred size changes, so it watches.
final class SettingsTabs: NSTabViewController {
    private var observations: [NSKeyValueObservation] = []

    override func insertTabViewItem(_ tabViewItem: NSTabViewItem, at index: Int) {
        super.insertTabViewItem(tabViewItem, at: index)
        guard let pane = tabViewItem.viewController else { return }
        observations.append(pane.observe(\.preferredContentSize) { [weak self] pane, _ in
            MainActor.assumeIsolated {
                guard let self, pane === self.selectedPane else { return }
                self.fitWindow(animated: self.view.window?.isVisible == true)
            }
        })
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animated: view.window?.isVisible == true)
    }

    func fitWindow(animated: Bool) {
        guard let window = view.window, let size = selectedPane?.preferredContentSize, size.width > 0, size.height > 0
        else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        guard content.size != size else { return }
        let fitted = window.frameRect(forContentRect: CGRect(x: content.minX, y: content.maxY - size.height,
                                                             width: size.width, height: size.height))
        window.setFrame(fitted, display: true, animate: animated)
    }

    private var selectedPane: NSViewController? {
        tabViewItems.indices.contains(selectedTabViewItemIndex) ? tabViewItems[selectedTabViewItemIndex].viewController : nil
    }
}
