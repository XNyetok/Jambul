import AppKit
import SwiftUI
import Testing
@testable import Jambul

/// The compact island's two sides: each as wide as what it holds, so the island needn't be centered on the notch.
@MainActor
final class CompactSidesTests {
    private let notch = NotchMetrics(size: CGSize(width: 180, height: 32), compactHeight: 33)
    private let activities = ActivityCenter()

    @Test func eachSideIsAsWideAsWhatItHolds() {
        let layout = IslandLayout(.compact, notch: notch, compactSlotWidth: 42, compactLeadingWidth: 16)
        #expect(layout.size.width == 180 + 42 + 16 + 2 * IslandLayout.compactInset(notch))
        // The right side is 26 pt wider, so the island's middle sits 13 pt right of the notch's.
        #expect(layout.xOffset == 13)
        let panel = CGRect(x: 0, y: 0, width: 600, height: 200)
        let frame = layout.frame(hangingFrom: panel)
        // The notch, in the panel's middle, keeps the left slot and its inset on its left and the right on its right.
        #expect(panel.midX - 90 - frame.minX == 16 + IslandLayout.compactInset(notch))
        #expect(frame.maxX - (panel.midX + 90) == 42 + IslandLayout.compactInset(notch))
    }

    @Test func sidesOfOneWidthKeepTheIslandCenteredAndSoDoAPeekAndTheOpenIsland() {
        #expect(IslandLayout(.compact, notch: notch, compactSlotWidth: 42).xOffset == 0)
        #expect(IslandLayout(.lifted, notch: notch, compactSlotWidth: 42, compactLeadingWidth: 16).xOffset == 13)
        #expect(IslandLayout(.peek, notch: notch, compactSlotWidth: 42, compactLeadingWidth: 16).xOffset == 0)
        #expect(IslandLayout(.expanded, notch: notch, compactSlotWidth: 42, compactLeadingWidth: 16).xOffset == 0)
    }

    @Test func theTimersRingTakesOnlyItsOwnWidthLeftOfTheNotch() {
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        activities.register(timer)
        timer.start(.seconds(300))
        let model = IslandModel(notch: notch, activities: activities)
        #expect(model.compactLeadingWidth == IslandLayout.compactGlyphHeight)
        #expect(model.compactSlotWidth == 42)
        timer.stop()
    }

    /// With two, the left side is the second activity's glyph and the right the first's.
    @Test func withTwoTheLeftSideIsTheSecondActivitysGlyph() {
        activities.register(TestActivity(id: "first", isLive: true, priority: .high, compactSlotWidth: 50))
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        activities.register(timer)
        timer.start(.seconds(300))
        let model = IslandModel(notch: notch, activities: activities)
        #expect(model.compactActivities.map(\.id) == ["first", timer.id])
        #expect(model.compactLeadingWidth == IslandLayout.compactGlyphHeight)
        #expect(model.compactSlotWidth == 50)
        timer.stop()
    }

    /// A second activity that starts while the pointer rests on the lifted island leaves both sides as they are:
    /// holding one room for both sides widened the left one and moved its glyph away from the notch.
    @Test func anActivityStartingUnderARestingPointerLeavesBothSidesAsTheyAre() async throws {
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        activities.register(timer)
        let other = TestActivity(id: "other", priority: .low, compactSlotWidth: 16)
        activities.register(other)
        timer.start(.seconds(300))
        defer { timer.stop() }
        let model = IslandModel(notch: notch, activities: activities)
        model.pointer(.island, isInside: true)
        model.clicked()
        model.clicked()
        #expect(model.presentation == .lifted)
        other.isLive = true
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.compactActivities.count == 2)
        #expect(model.compactLeadingWidth == 16)
        #expect(model.compactSlotWidth == 42)
    }

    /// A side that would narrow under a resting pointer keeps its room, each side its own.
    @Test func anActivityEndingUnderARestingPointerKeepsEachSidesRoom() async throws {
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        activities.register(timer)
        timer.start(.seconds(300))
        let model = IslandModel(notch: notch, activities: activities)
        model.pointer(.island, isInside: true)
        model.clicked()
        model.clicked()
        #expect(model.presentation == .lifted)
        timer.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.compactLeadingWidth == 16)
        #expect(model.compactSlotWidth == 42)
    }
}
