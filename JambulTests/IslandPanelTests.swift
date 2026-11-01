import AppKit
import Testing
@testable import Jambul

@MainActor
struct IslandPanelTests {
    @Test func aPressThePanelTurnsDownNeverReachesItsViews() {
        // A window only takes clicks while it is ordered in; this one sits far off every screen.
        let panel = IslandPanel(contentRect: CGRect(x: -20_000, y: -20_000, width: 100, height: 100))
        let view = PressRecorder(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        panel.contentView = view
        panel.acceptsPress = { $0 == 1 }
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        // The rest of a double click: its press, drag and release all go, so no button is left pressed.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            panel.sendEvent(mouseEvent(type, clickCount: 2, in: panel))
        }
        #expect(view.received.isEmpty)

        // A fresh click goes through whole.
        panel.sendEvent(mouseEvent(.leftMouseDown, clickCount: 1, in: panel))
        panel.sendEvent(mouseEvent(.leftMouseUp, clickCount: 1, in: panel))
        #expect(view.received == [.leftMouseDown, .leftMouseUp])
    }

    private func mouseEvent(_ type: NSEvent.EventType, clickCount: Int, in panel: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
                           windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                           pressure: 1)!
    }
}

/// A view that notes the presses reaching it.
private final class PressRecorder: NSView {
    var received: [NSEvent.EventType] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { received.append(event.type) }
    override func mouseDragged(with event: NSEvent) { received.append(event.type) }
    override func mouseUp(with event: NSEvent) { received.append(event.type) }
}
