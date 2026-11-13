import AppKit
import SwiftUI
import Testing
@testable import Jambul

/// What a tab's symbol and a card on Home say about their activity: color for something going on, dim for nothing.
@MainActor
final class TabAndCardStateTests {
    private let activities = ActivityCenter()

    private func usage(claude used: Double) -> UsageActivity {
        let usage = UsageActivity(activities: activities)
        usage.enabled = [.claude, .antigravity]
        let resets = Date.now.addingTimeInterval(3 * 3_600)
        usage.record(UsageReading(provider: .claude, windows: [
            UsageWindow(id: "five_hour", label: "5h", used: used, resetsAt: resets),
            UsageWindow(id: "weekly", label: "wk", used: 0.3, resetsAt: resets)], measuredAt: .now))
        usage.record(UsageReading(provider: .antigravity, windows: [
            UsageWindow(id: "weekly", label: "wk", used: 0.18, resetsAt: resets)], measuredAt: .now))
        return usage
    }

    @Test func aTabTakesItsActivitysColorOnlyWhileItIsLive() {
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        #expect(timer.tabTint == nil)
        timer.start(.seconds(300))
        #expect(timer.tabTint == timer.tint)
        timer.stop()
    }

    @Test func theUsageTabTurnsYellowFrom80PercentAndRedFrom95() {
        #expect(usage(claude: 0.42).tabTint == nil)
        #expect(usage(claude: 0.79).tabTint == nil)
        // A subscription turned off no longer colors the tab.
        let off = usage(claude: 0.95)
        off.enabled = [.antigravity]
        #expect(off.tabTint == nil)
        #expect(usage(claude: 0.8).tabTint == .yellow)
        #expect(usage(claude: 0.95).tabTint == .red)
    }

    @Test func aCardWithNothingGoingOnIsQuiet() {
        let timer = TimerActivity(activities: activities, keepsMacAwake: false)
        #expect(timer.homeCardIsQuiet)
        timer.start(.seconds(300))
        #expect(!timer.homeCardIsQuiet)
        timer.stop()
        #expect(BatteryActivity(activities: activities).homeCardIsQuiet == false)

        let defaults = UserDefaults(suiteName: "JambulTests.TabAndCardState")!
        defaults.removePersistentDomain(forName: "JambulTests.TabAndCardState")
        let keepAwake = KeepAwakeActivity(activities: activities, defaults: defaults, bootSession: nil, holdsScreen: false)
        #expect(keepAwake.homeCardIsQuiet)
        keepAwake.start()
        #expect(!keepAwake.homeCardIsQuiet)
        keepAwake.stop()
    }

    /// A subscription with one limit starts as high as one that has two: centered, it sat lower.
    @Test func usageColumnsStartAtTheSameHeight() throws {
        let width = IslandLayout.expandedSize.width - 2 * IslandLayout.expandedContentInset
        let renderer = ImageRenderer(content: UsageTab(activity: usage(claude: 0.42))
            .frame(width: width).environment(\.colorScheme, .dark).foregroundStyle(.white))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = try #require(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The first row with anything drawn in each half.
        func top(_ columns: Range<Int>) -> Int? {
            (0..<h).first { y in columns.contains { pixels[(y * w + $0) * 4 + 3] > 40 } }
        }
        let left = try #require(top(0..<(w / 2))), right = try #require(top((w / 2)..<w))
        #expect(abs(left - right) <= 3, "the columns start at \(left) and \(right)")
    }
}
