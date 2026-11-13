import AppKit
import SwiftUI
import Testing
@testable import Jambul

/// The island panel at rest: only as large as the island, so clicks around it reach the apps there.
@MainActor
struct IslandPanelFitterTests {
    /// A 13-inch MacBook Air's screen as macOS 27 reports it, moved far off every real screen.
    private let geometry = NotchGeometry(screenFrame: CGRect(x: -20_000, y: -20_000, width: 1470, height: 956),
                                         visibleFrame: CGRect(x: -20_000, y: -20_000, width: 1470, height: 923),
                                         safeAreaTop: 32,
                                         leftArea: CGRect(x: -20_000, y: -19_076, width: 645.5, height: 32),
                                         rightArea: CGRect(x: -19_175.5, y: -19_076, width: 645.5, height: 32))
    private let activities = ActivityCenter()
    private let panel = IslandPanel(contentRect: .zero)
    /// Stands in for the island's view.
    private let content = NSView()
    /// Away from the island, unless a test moves it.
    private let pointer = PointerLocation()

    private func makeFitter(for model: IslandModel, content: NSView? = nil,
                            settles: Duration = .milliseconds(50)) -> IslandPanelFitter {
        IslandPanelFitter(panel: panel, content: content ?? self.content, model: model, geometry: geometry,
                          settles: settles, pointerLocation: { [pointer] in pointer.location })
    }

    /// A live activity resting beside the notch, as the usage limits do from 95%.
    private func restingIsland(settles: Duration = .milliseconds(50)) -> (IslandModel, IslandPanelFitter) {
        activities.register(TestActivity(isLive: true))
        let model = IslandModel(notch: geometry.metrics, activities: activities)
        return (model, makeFitter(for: model, settles: settles))
    }

    @Test func atRestThePanelCoversTheIslandAndNothingAroundIt() async throws {
        let (model, fitter) = restingIsland()
        #expect(model.presentation == .compact)
        // Until the island has settled, the panel leaves room for its motion.
        #expect(panel.frame == fitter.canvas)

        try await Task.sleep(for: .milliseconds(300))
        let island = model.layout.frame(hangingFrom: fitter.canvas)
        #expect(panel.frame.contains(island))
        // Below the notch, where a full-screen browser's tabs are, and beside the island, where the menu bar's items
        // are: clicks there reach the apps.
        #expect(!panel.frame.contains(CGPoint(x: island.midX, y: island.minY - 10)))
        #expect(!panel.frame.contains(CGPoint(x: island.minX - 10, y: island.midY)))
        #expect(!panel.frame.contains(CGPoint(x: island.maxX + 10, y: island.midY)))
        withExtendedLifetime(fitter) {}
    }

    @Test func thePanelTakesTheWholeCanvasBeforeTheIslandMoves() async throws {
        let (model, fitter) = restingIsland()
        try await Task.sleep(for: .milliseconds(300))
        #expect(panel.frame != fitter.canvas)

        // The pointer arriving lifts the island at once, and the panel already has room for the lift.
        model.pointer(.notch, isInside: true)
        #expect(model.presentation == .lifted)
        #expect(panel.frame == fitter.canvas)

        // Open, the panel keeps the whole canvas.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.presentation == .expanded)
        #expect(panel.frame == fitter.canvas)

        // Back at rest, it fits the island again.
        model.pointer(.notch, isInside: false)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.presentation == .compact)
        #expect(panel.frame == fitter.restingFrame)
        #expect(panel.frame != fitter.canvas)
        withExtendedLifetime(fitter) {}
    }

    @Test func anIslandWideningAtRestHasRoomBeforeItIsDrawn() async throws {
        let (model, fitter) = restingIsland(settles: .milliseconds(300))
        try await Task.sleep(for: .milliseconds(600))
        let narrow = panel.frame
        #expect(narrow != fitter.canvas)

        // The panel as the wider island is being stored, before anything can draw it.
        let asStored = FrameAsStored(of: panel)
        withObservationTracking { _ = model.liveActivities } onChange: {
            MainActor.assumeIsolated { asStored.note() }
        }
        // A wider activity joins the one at rest, as the timer does beside the usage limits.
        activities.register(TestActivity(id: "wide", isLive: true, priority: .high, compactSlotWidth: 54))
        try await waitUntil { model.liveActivities.count == 2 }
        #expect(asStored.frame == fitter.canvas)

        try await Task.sleep(for: .milliseconds(600))
        let wide = model.layout.frame(hangingFrom: fitter.canvas)
        #expect(wide.width > narrow.width)
        #expect(panel.frame.contains(wide))
        #expect(panel.frame != fitter.canvas)
        withExtendedLifetime(fitter) {}
    }

    @Test func anActivityWideningByItselfAtRestGetsRoom() async throws {
        let activity = WideningActivity()
        activities.register(activity)
        let model = IslandModel(notch: geometry.metrics, activities: activities)
        let fitter = makeFitter(for: model, settles: .milliseconds(300))
        try await Task.sleep(for: .milliseconds(600))
        let narrow = panel.frame
        #expect(narrow != fitter.canvas)

        // Nothing announces this one; the island widens without the model moving it. The panel never resizes while the
        // change is being stored, which made SwiftUI miss the change, but a turn later.
        activity.compactSlotWidth = 60
        #expect(panel.frame == narrow)
        try await Task.sleep(for: .milliseconds(30))
        #expect(panel.frame == fitter.canvas)

        try await Task.sleep(for: .milliseconds(600))
        let wide = model.layout.frame(hangingFrom: fitter.canvas)
        #expect(wide.width > narrow.width)
        #expect(panel.frame.contains(wide))
        #expect(panel.frame != fitter.canvas)
        withExtendedLifetime(fitter) {}
    }

    @Test func theIslandStaysWhereItIsAsThePanelChanges() async throws {
        let (_, fitter) = restingIsland()
        let onScreen = { panel.convertToScreen(content.convert(content.bounds, to: nil)) }
        #expect(onScreen() == fitter.canvas)

        try await Task.sleep(for: .milliseconds(300))
        #expect(panel.frame != fitter.canvas)
        #expect(onScreen() == fitter.canvas)
        withExtendedLifetime(fitter) {}
    }

    /// A change that starts at rest, drawn as SwiftUI draws it. A panel resized while the change was being stored fails
    /// this only in some runs, since the order SwiftUI and the panel hear of a change varies; the tests above and
    /// `IslandModelTests.theWindowsHearOfAChangeBeforeAnyOfItIsStored` catch that every time.
    @Test func theIslandDrawsAChangeThatStartsAtRest() async throws {
        activities.register(TestActivity(isLive: true))
        let model = IslandModel(notch: geometry.metrics, activities: activities)
        // Lifted it stays, for as long as the test looks.
        model.hoverIntent = .seconds(10)
        let drawn = DrawnPresentation()
        let host = NSHostingView(rootView: PresentationDrawing(model: model, drawn: drawn))
        host.sizingOptions = []
        let fitter = makeFitter(for: model, content: host)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(drawn.presentation == .compact)
        #expect(panel.frame != fitter.canvas)

        model.pointer(.notch, isInside: true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.presentation == .lifted)
        #expect(drawn.presentation == .lifted, "the lift was never drawn")
        withExtendedLifetime(fitter) {}
    }

    /// Shrunk under a pointer resting on the island, the panel made SwiftUI see the pointer leave and come back: a pill
    /// closed by a click could fold away under it, and a peek it never came for could stay past its time.
    @Test func thePanelWaitsForAPointerRestingOnTheIslandToMoveOff() async throws {
        let (model, fitter) = restingIsland()
        let island = model.layout.frame(hangingFrom: fitter.canvas)
        pointer.location = CGPoint(x: island.midX + 60, y: island.midY)
        try await Task.sleep(for: .milliseconds(300))
        #expect(panel.frame == fitter.canvas)

        pointer.location = CGPoint(x: island.midX - 60, y: island.midY)
        fitter.pointerMoved()
        #expect(panel.frame == fitter.canvas)

        // Off the island, onto a browser's tabs below it.
        pointer.location = CGPoint(x: island.midX, y: island.minY - 20)
        fitter.pointerMoved()
        #expect(panel.frame == fitter.restingFrame)
        #expect(panel.frame != fitter.canvas)
        withExtendedLifetime(fitter) {}
    }

    /// A pointer pushed against the top of the screen, as one coming from the menu bar is, sits at the screen's `maxY`: on
    /// the island, which hangs from there, though `CGRect.contains` leaves that edge out.
    @Test func aPointerPushedAgainstTheTopOfTheScreenIsOnTheIsland() async throws {
        let (model, fitter) = restingIsland()
        let island = model.layout.frame(hangingFrom: fitter.canvas)
        pointer.location = CGPoint(x: island.midX + 60, y: island.maxY)
        #expect(fitter.isPointerOnIsland)
        try await Task.sleep(for: .milliseconds(300))
        #expect(panel.frame == fitter.canvas)

        // Along the top edge, still on it.
        pointer.location = CGPoint(x: island.midX - 60, y: island.maxY)
        fitter.pointerMoved()
        #expect(panel.frame == fitter.canvas)

        // The row just below the island is off it.
        pointer.location = CGPoint(x: island.midX, y: island.minY)
        #expect(!fitter.isPointerOnIsland)
        fitter.pointerMoved()
        #expect(panel.frame == fitter.restingFrame)
        withExtendedLifetime(fitter) {}
    }

    /// Below the island, on a browser's tabs, is where clicks must get through, so a pointer there never keeps the panel
    /// large.
    @Test func aPointerBelowTheIslandLetsThePanelShrink() async throws {
        let (model, fitter) = restingIsland()
        let island = model.layout.frame(hangingFrom: fitter.canvas)
        pointer.location = CGPoint(x: island.midX, y: island.minY - 20)
        try await Task.sleep(for: .milliseconds(300))
        #expect(panel.frame == fitter.restingFrame)
        #expect(panel.frame != fitter.canvas)
        withExtendedLifetime(fitter) {}
    }

    @Test func thePanelTakesThePointerWhileTheIslandIsOut() async throws {
        // Resting from the start, as when Keep Awake comes back on at launch.
        let activity = TestActivity(isLive: true)
        activities.register(activity)
        let model = IslandModel(notch: geometry.metrics, activities: activities)
        let fitter = makeFitter(for: model)
        #expect(model.presentation == .compact)
        #expect(!panel.ignoresMouseEvents)

        activity.isLive = false
        try await waitUntil { model.presentation == .idle }
        #expect(panel.ignoresMouseEvents)

        activity.isLive = true
        try await waitUntil { model.presentation == .compact }
        #expect(!panel.ignoresMouseEvents)
        withExtendedLifetime(fitter) {}
    }

    @Test func anIdleIslandLetsThePointerThrough() {
        let model = IslandModel(notch: geometry.metrics, activities: activities)
        let fitter = makeFitter(for: model)
        #expect(model.presentation == .idle)
        #expect(panel.ignoresMouseEvents)
        withExtendedLifetime(fitter) {}
    }
}

/// Where the pointer is, as the panel asks for it.
@MainActor
private final class PointerLocation {
    var location = CGPoint.zero
}

/// The panel's frame at the moment a change was being stored.
@MainActor
private final class FrameAsStored {
    private let panel: NSWindow
    private(set) var frame: CGRect?

    init(of panel: NSWindow) {
        self.panel = panel
    }

    func note() {
        frame = panel.frame
    }
}

/// The presentation the island's view last drew.
@MainActor
private final class DrawnPresentation {
    var presentation: IslandPresentation?
}

/// Stands in for the island's view, noting what it draws.
private struct PresentationDrawing: View {
    let model: IslandModel
    let drawn: DrawnPresentation

    var body: some View {
        let _ = (drawn.presentation = model.presentation)
        Color.black
            .frame(width: model.layout.size.width, height: model.layout.size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A live activity whose slot beside the notch can widen by itself, as a countdown passing an hour might.
@MainActor
@Observable
private final class WideningActivity: IslandActivity {
    let id = "widening"
    let isLive = true
    var compactSlotWidth: CGFloat = 36

    var compactLeading: some View { EmptyView() }
    var compactTrailing: some View { EmptyView() }
}
