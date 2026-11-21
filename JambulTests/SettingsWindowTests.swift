import AppKit
import Testing
@testable import Jambul

/// The Settings window is as tall as the pane it shows, and keeps its top edge where it is as that changes.
@MainActor
struct SettingsWindowTests {
    private func pane(height: CGFloat) -> NSViewController {
        let pane = NSViewController()
        pane.view = NSView(frame: CGRect(x: 0, y: 0, width: SettingsLayout.width, height: height))
        pane.preferredContentSize = CGSize(width: SettingsLayout.width, height: height)
        return pane
    }

    @Test func theWindowFollowsThePaneItShows() {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(NSTabViewItem(viewController: pane(height: 300)))
        tabs.addTabViewItem(NSTabViewItem(viewController: pane(height: 500)))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        tabs.fitWindow(animated: false)
        let top = window.frame.maxY
        #expect(window.contentRect(forFrameRect: window.frame).size == CGSize(width: SettingsLayout.width, height: 300))

        tabs.selectedTabViewItemIndex = 1
        #expect(window.contentRect(forFrameRect: window.frame).height == 500)
        #expect(window.frame.maxY == top)

        // A pane growing while it shows, as AI Tools does when Claude asks to be connected.
        tabs.tabViewItems[1].viewController?.preferredContentSize = CGSize(width: SettingsLayout.width, height: 540)
        #expect(window.contentRect(forFrameRect: window.frame).height == 540)
        #expect(window.frame.maxY == top)
        window.close()
    }
}
