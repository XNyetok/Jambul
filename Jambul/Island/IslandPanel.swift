import AppKit

/// A borderless panel that floats above the menu bar, stays on every Space and never takes focus.
final class IslandPanel: NSPanel {
    /// Asked as each press begins, with its click count. A press it turns down never reaches the panel's views, and
    /// neither do its drags and release, so the island's buttons and its own toggle all skip it alike.
    var acceptsPress: (@MainActor (_ clickCount: Int) -> Bool)?
    private var isDroppingPress = false

    init(contentRect: NSRect, levelOffset: Int = 3) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + levelOffset)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            isDroppingPress = acceptsPress?(event.clickCount) == false
            if isDroppingPress { return }
        case .leftMouseDragged:
            if isDroppingPress { return }
        case .leftMouseUp:
            if isDroppingPress {
                isDroppingPress = false
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }
}
