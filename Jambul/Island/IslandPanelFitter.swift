import AppKit
import Observation

/// Decides where the island panel takes the pointer: nowhere while the island is idle, across the whole canvas while the
/// island moves or is open, and only on the island once it rests, so clicks around it reach the apps there.
///
/// A window that takes the pointer takes every click across its frame, clear pixels too, once its `ignoresMouseEvents`
/// has been set (measured). Left unset, clicks pass through clear pixels, but hover goes unreported when the pointer
/// reaches the island across them (measured), and hover is how the island opens. So the panel takes the pointer while the
/// island is out, and shrinks to the island's own frame once the island has settled, which leaves the area below and
/// beside the notch to the apps there while an activity rests beside the notch. While the island moves, and while it is
/// open, the panel is the whole canvas. Idle, it keeps the canvas for whatever comes out next.
///
/// The island's view keeps the canvas's size and place on screen whatever the panel's frame, so SwiftUI never lays it
/// out again and the island doesn't move as the panel changes (measured: not one frame out of place in 120 changes).
///
/// Two things SwiftUI did decide when the panel changes (both measured):
/// - Resized while a change was being stored, the panel made SwiftUI draw the island as it was and miss the change. So
///   the panel makes room as the model announces a change (`IslandModel.onWillChange`), before any of it is stored, and
///   never resizes from inside an observation.
/// - Shrunk under a pointer resting on the island, the panel made SwiftUI see the pointer leave and come back. So it
///   waits for such a pointer to move off the island first. Growing under the pointer, and shrinking with the pointer
///   off the island, below it in another app for instance, left hover as it was.
@MainActor
final class IslandPanelFitter {
    private let panel: NSWindow
    /// The island's view, always as large as the canvas.
    private let content: NSView
    private let model: IslandModel
    private let settles: Duration
    private let pointerLocation: @MainActor () -> CGPoint
    private var geometry: NotchGeometry
    private var fitTask: Task<Void, Never>?
    /// The frame the panel waits to shrink to until the pointer has moved off it, and the event monitors following the
    /// pointer meanwhile. Only while a pointer rests on the island at rest, so it costs nothing otherwise.
    private var waitingToFit: CGRect?
    private var pointerMonitors: [Any] = []

    /// - Parameters:
    ///   - settles: How long the island takes to come to rest after a change; tests pass a shorter time.
    ///   - pointerLocation: Where the pointer is on screen; tests pass their own.
    init(panel: NSWindow, content: NSView, model: IslandModel, geometry: NotchGeometry,
         settles: Duration = Motion.islandSettles,
         pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }) {
        self.panel = panel
        self.content = content
        self.model = model
        self.geometry = geometry
        self.settles = settles
        self.pointerLocation = pointerLocation
        let container = NSView()
        content.autoresizingMask = []
        container.addSubview(content)
        panel.contentView = container
        // From the start: an island that rests from launch, as when Keep Awake comes back on, takes the pointer at once.
        panel.ignoresMouseEvents = model.presentation == .idle
        layOut(on: geometry)
        model.onWillChange = { [weak self] in self?.makeRoom(for: $0) }
        followIsland()
    }

    /// Where the island's view sits on screen: room for the open island, hanging from the top of the screen, centered
    /// on the notch.
    var canvas: CGRect {
        geometry.panelFrame(size: IslandLayout.canvasSize(geometry.metrics))
    }

    /// The panel's frame with the island at rest as it is now: the island's own frame, on whole points, or the canvas
    /// while the island is idle or open. Open, it closes as soon as the pointer leaves, so shrinking then would only
    /// be undone.
    var restingFrame: CGRect {
        let layout = model.layout
        guard model.presentation != .idle, model.presentation != .expanded else { return canvas }
        // Around the island wherever it sits, which needn't be centered on the notch.
        let canvas = self.canvas, island = layout.frame(hangingFrom: canvas)
        let left = island.minX.rounded(.down), height = island.height.rounded(.up)
        return CGRect(x: left, y: canvas.maxY - height, width: island.maxX.rounded(.up) - left, height: height)
    }

    /// Lays the panel out on `geometry`, as at launch and when the screens change.
    func layOut(on geometry: NotchGeometry) {
        self.geometry = geometry
        content.frame = CGRect(origin: .zero, size: canvas.size)
        place(canvas)
        fitOnceSettled()
    }

    /// Whether the pointer is over the island as it is drawn now, a pointer pushed against the top of the screen too.
    var isPointerOnIsland: Bool {
        model.layout.frame(hangingFrom: canvas).containsPointer(at: pointerLocation())
    }

    /// Called as the pointer moves while the panel waits for it to leave the island, by the event monitors and by tests.
    func pointerMoved() {
        guard let frame = waitingToFit, !frame.containsPointer(at: pointerLocation()) else { return }
        fit()
    }

    /// Before the island changes: the panel takes the pointer unless the island goes idle, takes the whole canvas so the
    /// island has room for every step of its motion, and fits the island again once it has settled.
    private func makeRoom(for next: IslandPresentation) {
        panel.ignoresMouseEvents = next == .idle
        place(canvas)
        fitOnceSettled()
    }

    /// Follows the changes the model doesn't announce, like an activity's slot widening by itself: a turn later, once the
    /// change is stored, the panel takes the canvas if the island no longer fits it, and fits the island once it has
    /// settled.
    private func followIsland() {
        withObservationTracking {
            _ = model.layout
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.islandDidChange() }
        }
    }

    private func islandDidChange() {
        if !panel.frame.contains(restingFrame) { place(canvas) }
        fitOnceSettled()
        followIsland()
    }

    private func fitOnceSettled() {
        stopWaitingForThePointer()
        fitTask?.cancel()
        fitTask = Task { [weak self, settles] in
            try? await Task.sleep(for: settles, tolerance: Motion.timerTolerance)
            guard !Task.isCancelled, let self else { return }
            fit()
        }
    }

    /// Shrinks the panel to the island at rest, once no pointer rests on the island.
    private func fit() {
        stopWaitingForThePointer()
        let frame = restingFrame
        let shrinks = frame != panel.frame && panel.frame.contains(frame)
        if shrinks, frame.containsPointer(at: pointerLocation()) {
            waitForThePointer(toLeave: frame)
        } else {
            place(frame)
        }
    }

    /// Moves over other apps reach the global monitor, and moves over Jambul's own panels the local one.
    private func waitForThePointer(toLeave frame: CGRect) {
        waitingToFit = frame
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let global = NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
        pointerMonitors = [global, local].compactMap { $0 }
    }

    private func stopWaitingForThePointer() {
        waitingToFit = nil
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors = []
    }

    /// Frames the panel, and moves the island's view the other way, so it stays where it is on screen.
    private func place(_ frame: CGRect) {
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        let canvas = self.canvas
        let origin = CGPoint(x: canvas.minX - panel.frame.minX, y: canvas.minY - panel.frame.minY)
        if content.frame.origin != origin { content.setFrameOrigin(origin) }
    }
}
