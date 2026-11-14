import AppKit
import SwiftUI
import Testing
@testable import Jambul

/// The glyph left of the notch travelling to its place in the open island and back: each activity that has such a glyph
/// marks its place, and once the island has settled it looks as if the glyph had never left.
@MainActor
@Suite(.serialized)
final class GlyphFlightTests {
    private let notch = NotchMetrics(size: CGSize(width: 179, height: 32), compactHeight: 33)
    private let activities = ActivityCenter()
    private let defaults: UserDefaults
    private var panels: [NSWindow] = []

    init() {
        let suiteName = "JambulTests.GlyphFlight"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        MainActor.assumeIsolated { panels.forEach { $0.orderOut(nil) } }
    }

    /// Jambul's activities, with a timer paused at 25 minutes so nothing drawn changes by itself.
    private func registerWithAPausedTimer() -> TimerActivity {
        let home = HomeActivity(activities: activities)
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        let keepAwake = KeepAwakeActivity(activities: activities, defaults: defaults, bootSession: nil, holdsScreen: false)
        activities.registerJambulsActivities(home: home, usage: UsageActivity(activities: activities),
                                             agent: AgentActivity(activities: activities), keepAwake: keepAwake,
                                             timer: timer, battery: BatteryActivity(activities: activities))
        timer.start(.seconds(25 * 60))
        timer.pause()
        return timer
    }

    /// The island's view in a panel far off every screen.
    private func host(_ model: IslandModel) -> NSView {
        host(IslandView(model: model))
    }

    /// The island as it is at rest, drawn without anything that travels: the glyph left of the notch sits in its slot
    /// as plain content, and the open island's glyphs are simply where they belong.
    private func hostAtRest(_ model: IslandModel) -> NSView {
        let layout = model.layout
        let shape = IslandShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius)
        return host(ZStack(alignment: .top) {
            shape.fill(.black)
            ZStack(alignment: .top) {
                if model.presentation == .expanded {
                    let size = IslandLayout.expandedSize(showsClock: false)
                    ExpandedContent(model: model).frame(width: size.width, height: size.height)
                } else if let slot = model.compactSlotWidth, let leading = model.compactLeadingWidth {
                    CompactContent(activities: model.compactActivities, notch: model.notch, leadingWidth: leading,
                                   slotWidth: slot)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .offset(x: layout.xOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    }

    private func host(_ view: some View) -> NSView {
        let canvas = IslandLayout.canvasSize(notch)
        let panel = IslandPanel(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: canvas))
        let host = NSHostingView(rootView: view.frame(width: canvas.width, height: canvas.height))
        panel.contentView = host
        panel.orderFrontRegardless()
        panels.append(panel)
        return host
    }

    private func pixels(of view: NSView) throws -> [UInt8] {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try #require(rep.bitmapData)
        bytesPerRow = rep.bytesPerRow
        bytesPerPixel = rep.bitsPerPixel / 8
        return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    private var bytesPerRow = 1
    private var bytesPerPixel = 4

    /// Waits until two views are drawn alike, and says where they differ if they never are.
    private func waitUntilDrawnAlike(_ one: NSView, _ other: NSView) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let first = try pixels(of: one), second = try pixels(of: other)
            if difference(first, second) == 0 { return }
            if ContinuousClock.now >= deadline {
                let differing = zip(first, second).enumerated()
                    .filter { abs(Int($0.element.0) - Int($0.element.1)) > 24 }.map(\.offset)
                let columns = differing.map { ($0 % bytesPerRow) / bytesPerPixel }, rows = differing.map { $0 / bytesPerRow }
                let place = "columns \(columns.min() ?? 0)...\(columns.max() ?? 0), rows \(rows.min() ?? 0)...\(rows.max() ?? 0)"
                // Thrown, so the test's own line in the results says where they differ.
                throw DrawnApart(description: "\(differing.count) values differ, in \(place) of "
                                 + "\(bytesPerRow / bytesPerPixel) columns")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Whether anything but black is drawn: some color value clearly above none, leaving out each pixel's opacity, which
    /// is full all over the island.
    private func drawsSomething(_ pixels: [UInt8]) -> Bool {
        pixels.enumerated().contains { $0.offset % bytesPerPixel < 3 && $0.element > 100 }
    }

    /// How many color values differ clearly between two drawings of the island.
    private func difference(_ one: [UInt8], _ other: [UInt8]) -> Int {
        guard one.count == other.count else { return .max }
        return zip(one, other).count { abs(Int($0) - Int($1)) > 24 }
    }

    /// The glyphs a view marks as places the one left of the notch can travel to.
    private func glyphsShown(by view: some View) async throws -> Set<String> {
        let found = Found()
        let panel = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 480, height: 150),
                             styleMask: .borderless, backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: GlyphProbe(found: found) { view })
        panel.orderFrontRegardless()
        panels.append(panel)
        try await waitUntil { found.ids != nil }
        return Set((found.ids ?? [:]).keys)
    }

    @Test func theTimersDialHasAPlaceOnItsTabAndOnHome() async throws {
        let timer = registerWithAPausedTimer()
        defer { timer.stop() }
        let glyph = try #require(timer.compactGlyph)
        #expect(try await glyphsShown(by: timer.tab).contains(glyph))
        #expect(try await glyphsShown(by: HomeTab(center: activities)).contains(glyph))
    }

    @Test func keepAwakesEyesHaveAPlaceOnItsTabAndOnHome() async throws {
        let keepAwake = KeepAwakeActivity(activities: activities, defaults: defaults, bootSession: nil, holdsScreen: false)
        keepAwake.start()
        defer { keepAwake.stop() }
        let glyph = try #require(keepAwake.compactGlyph)
        #expect(try await glyphsShown(by: keepAwake.tab).contains(glyph))
        #expect(try await glyphsShown(by: keepAwake.homeCard).contains(glyph))
    }

    @Test func theLogoOfTheSubscriptionNearestItsLimitHasAPlaceOnTheUsageTabAndItsCard() async throws {
        let usage = UsageActivity(activities: activities)
        usage.enabled = [.claude]
        usage.record(UsageReading(provider: .claude, windows: [
            UsageWindow(id: "five_hour", label: "5h", used: 0.96, resetsAt: .now.addingTimeInterval(3_600))],
                                  measuredAt: .now))
        let glyph = try #require(usage.compactGlyph)
        #expect(try await glyphsShown(by: usage.tab).contains(glyph))
        #expect(try await glyphsShown(by: usage.homeCard).contains(glyph))
    }

    @Test func aWorkingSessionsCircleIsWhereClaudesLogoTravels() async throws {
        let agent = AgentActivity(activities: activities)
        agent.isConnected = true
        agent.receive(AgentEvent(kind: .sessionStart, session: "s1", cwd: "/tmp/work/Jambul"))
        agent.receive(AgentEvent(kind: .prompt, session: "s1", cwd: "/tmp/work/Jambul"))
        let glyph = try #require(agent.compactGlyph)
        #expect(try await glyphsShown(by: agent.tab).contains(glyph))
        #expect(try await glyphsShown(by: agent.homeCard).contains(glyph))
    }

    /// Opened from beside the notch, the island ends up drawn exactly as its content alone: the glyph that flew in has
    /// given way to the one that belongs there.
    @Test func onceOpenTheGlyphThatFlewInIsGone() async throws {
        let timer = registerWithAPausedTimer()
        defer { timer.stop() }
        let always = IslandModel(notch: notch, activities: activities, presentation: .expanded)
        always.selectTab(timer.id)
        let alwaysOpen = hostAtRest(always)

        let model = IslandModel(notch: notch, activities: activities)
        let opened = host(model)
        try await Task.sleep(for: .milliseconds(300))
        model.clicked()
        #expect(model.presentation == .expanded)
        model.selectTab(timer.id)
        model.clicked()
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.presentation != .expanded)
        model.clicked()
        #expect(model.selectedTab == timer.id)
        try await waitUntilDrawnAlike(opened, alwaysOpen)
        #expect(try drawsSomething(pixels(of: opened)))
    }

    /// Closed again, the island is drawn exactly as one that never opened: the glyph is back in its slot, to the pixel.
    /// Compared with the island's own view rather than with its content alone: on a display with one pixel per point,
    /// as CI's is, the travelling glyph rounds a slot on a half point to another pixel than plain content does.
    @Test func onceClosedTheGlyphIsBackBesideTheNotch() async throws {
        let timer = registerWithAPausedTimer()
        defer { timer.stop() }
        let neverOpened = host(IslandModel(notch: notch, activities: activities))

        let model = IslandModel(notch: notch, activities: activities)
        let closed = host(model)
        try await Task.sleep(for: .milliseconds(300))
        model.clicked()
        try await Task.sleep(for: .milliseconds(900))
        model.clicked()
        #expect(model.presentation == .compact)
        try await waitUntilDrawnAlike(closed, neverOpened)
        // And something is drawn there at all: the dial, in the timer's color.
        #expect(try drawsSomething(pixels(of: closed)))
    }

    /// A glyph narrower than its slot sits at the slot's left edge, as it does drawn as plain content.
    @Test func aGlyphNarrowerThanItsSlotSitsAtItsLeftEdge() async throws {
        let demo = DemoActivity()
        demo.isLive = true
        activities.register(demo)
        let model = IslandModel(notch: notch, activities: activities)
        let island = host(model), plain = hostAtRest(model)
        try await waitUntilDrawnAlike(island, plain)
        #expect(try drawsSomething(pixels(of: island)))
    }
}

private struct DrawnApart: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class Found {
    var ids: [String: String]?
}

/// Gives a view the island's glyph namespace and collects the places it marks.
private struct GlyphProbe<Content: View>: View {
    let found: Found
    @ViewBuilder let content: Content
    @Namespace private var glyphs

    var body: some View {
        content
            .environment(\.islandGlyphs, glyphs)
            .onPreferenceChange(IslandGlyphsShown.self) { ids in
                MainActor.assumeIsolated { found.ids = ids }
            }
    }
}
