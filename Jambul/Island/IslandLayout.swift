import SwiftUI

/// Size and corner radii of the island for each presentation.
struct IslandLayout {
    /// The open island, the same on every tab so it never grows or shrinks under the pointer as tabs change.
    static let expandedSize = CGSize(width: 480, height: 150)
    /// Room around the open island in its window.
    static let canvasMargin: CGFloat = 24
    /// Bottom corner radius of the idle island, kept inside the physical notch's outline.
    static let notchCornerRadius: CGFloat = 10
    /// Flares at the top of the compact island, which take this much off each side of its frame.
    static let compactTopRadius: CGFloat = 6
    /// Height of the glyphs beside the notch, such as the timer's dial and digits.
    static let compactGlyphHeight: CGFloat = 16

    /// Space from the drawn edge of the compact island to its content: the same as above and below the glyphs in the
    /// band, since Apple asks for even margins around content in the Dynamic Island. 8.5 pt on the MacBook Air. Measured
    /// from the frame it was once 10 pt, which the flares cut down to 4 pt beside 8.5 pt above and below.
    static func compactMargin(_ notch: NotchMetrics) -> CGFloat {
        (notch.compactHeight - compactGlyphHeight) / 2
    }

    /// From the edge of the compact island's frame to its content.
    static func compactInset(_ notch: NotchMetrics) -> CGFloat {
        compactTopRadius + compactMargin(notch)
    }

    /// Horizontal padding of the expanded content: the tab's own, and the tabs and clock beside the notch above it.
    static let expandedContentInset: CGFloat = 36
    /// Space between the notch and the tab's content, which is centered in what is left below the notch.
    static let expandedContentTopGap: CGFloat = 6
    static let expandedContentBottomInset: CGFloat = 12
    /// While a full-screen app hides the menu bar, the open island is this much taller, for the day and time right
    /// below the camera, so the room for a tab's content stays the same.
    static let clockRowHeight: CGFloat = 18

    /// The open island's size, a row taller with the clock below the camera.
    static func expandedSize(showsClock: Bool) -> CGSize {
        CGSize(width: expandedSize.width, height: expandedSize.height + (showsClock ? clockRowHeight : 0))
    }

    /// How many tabs sit on each side of the camera: half on each, the extra one on the left, so neither side crowds
    /// and both line up with the edges of the content below.
    static func tabSides(count: Int) -> (leading: Int, trailing: Int) {
        ((count + 1) / 2, count / 2)
    }

    /// The timer's dial on its tab: as tall as the room below the notch allows, with an even margin above and below.
    static let tabDialSize: CGFloat = 84
    /// The timer's countdown on its tab, and a smaller one from an hour up: "9:59:59" is 178 pt wide in the larger,
    /// more than the 160 pt beside the dial and the controls (measured).
    static let tabCountdownFont = Font.system(size: 44, weight: .semibold, design: .rounded)
    static let tabLongCountdownFont = Font.system(size: 36, weight: .semibold, design: .rounded)
    /// A one-row tab's name and the line under it.
    static let tabTitleFont = Font.system(size: 15, weight: .semibold)
    static let tabDetailFont = Font.system(size: 12, weight: .medium)
    /// A large number in the name's place, like how long Keep Awake has been on.
    static let tabHeadlineFont = Font.system(size: 30, weight: .semibold, design: .rounded)

    /// Each tab's button beside the notch, and the highlight behind the chosen one, as wide as it gets
    /// (`tabButtonWidth`).
    static let tabButtonSize = CGSize(width: 30, height: 24)
    static let tabButtonSpacing: CGFloat = 2
    /// The least space between the notch and what sits beside it in the open island.
    static let besideNotchGap: CGFloat = 8

    /// Room for a tab's content below the notch: 100 pt below the MacBook Air's 32 pt notch.
    static func expandedContentRoom(_ notch: NotchMetrics) -> CGFloat {
        expandedSize.height - notch.size.height - expandedContentTopGap - expandedContentBottomInset
    }

    /// Room on either side of the notch in the open island, for the tabs: 106.5 pt beside the MacBook Air's 179 pt
    /// notch.
    static func besideNotchRoom(_ notch: NotchMetrics) -> CGFloat {
        (expandedSize.width - notch.size.width) / 2 - expandedContentInset - besideNotchGap
    }

    /// Each tab button's width, for `count` tabs on one side of the notch: `tabButtonSize` while they fit there at that
    /// width, narrower once there are more than fit, and on whole points. Three keep 30 pt beside the MacBook Air's
    /// notch; four would take 25 pt each, where 30 would need 126 pt of the 106.5 there. The island keeps its size.
    static func tabButtonWidth(count: Int, notch: NotchMetrics) -> CGFloat {
        guard count > 0 else { return tabButtonSize.width }
        let room = besideNotchRoom(notch) - CGFloat(count - 1) * tabButtonSpacing
        return min(tabButtonSize.width, (room / CGFloat(count)).rounded(.down))
    }

    /// The fixed size of the window hosting the island: the open island and some room around it.
    static func canvasSize(_ notch: NotchMetrics) -> CGSize {
        CGSize(width: expandedSize.width + 2 * canvasMargin, height: expandedSize.height + canvasMargin)
    }

    let size: CGSize
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    /// How far right of the notch's middle the island's own middle sits: half of what the right slot is wider than the
    /// left by, beside the notch; nothing for a peek or the open island.
    var xOffset: CGFloat = 0

    /// A peek's second line (`Peek.subtitle`) makes it this much taller.
    static let peekSubtitleHeight: CGFloat = 16

    /// - Parameters:
    ///   - compactSlotWidth: The width of the slot right of the notch, or `nil` when nothing is live.
    ///   - compactLeadingWidth: The width of the slot left of it, or `nil` for the same.
    ///   - peekHasSubtitle: Whether the peek showing has a second line.
    ///   - showsClock: Whether the open island shows the day and time below the camera.
    init(_ presentation: IslandPresentation, notch: NotchMetrics, compactSlotWidth: CGFloat?,
         compactLeadingWidth: CGFloat? = nil, peekHasSubtitle: Bool = false, showsClock: Bool = false) {
        let leading = compactLeadingWidth ?? compactSlotWidth
        let resting = compactSlotWidth.map {
            CGSize(width: notch.size.width + $0 + (leading ?? $0) + 2 * Self.compactInset(notch),
                   height: notch.compactHeight)
        } ?? notch.size
        let offset = compactSlotWidth.map { ($0 - (leading ?? $0)) / 2 } ?? 0
        switch presentation {
        case .idle:
            // Without a notch to hide behind, the idle island folds away into the top edge.
            let size = notch.hasPhysicalNotch ? notch.size : CGSize(width: notch.size.width, height: 0)
            self.init(size: size, topRadius: 0, bottomRadius: Self.notchCornerRadius)
        case .compact:
            self.init(size: resting, topRadius: Self.compactTopRadius, bottomRadius: 14)
            xOffset = offset
        case .lifted:
            self.init(size: CGSize(width: resting.width + 24, height: resting.height + 6), topRadius: Self.compactTopRadius,
                      bottomRadius: 14)
            xOffset = offset
        case .peek:
            let subtitle = peekHasSubtitle ? Self.peekSubtitleHeight : 0
            self.init(size: CGSize(width: max(340, resting.width), height: notch.size.height + 38 + subtitle),
                      topRadius: 10, bottomRadius: 24)
        case .expanded:
            self.init(size: Self.expandedSize(showsClock: showsClock), topRadius: 14, bottomRadius: 32)
        }
    }

    /// Where the island sits on screen: hanging from the top of its panel, `xOffset` right of its middle.
    func frame(hangingFrom panel: CGRect) -> CGRect {
        CGRect(x: panel.midX + xOffset - size.width / 2, y: panel.maxY - size.height, width: size.width, height: size.height)
    }

    private init(size: CGSize, topRadius: CGFloat, bottomRadius: CGFloat) {
        self.size = size
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }
}
