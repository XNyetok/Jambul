import CoreGraphics

/// Size and corner radii of the island for each presentation.
struct IslandLayout {
    /// The open island, the same on every tab so it never grows or shrinks under the pointer as tabs change.
    static let expandedSize = CGSize(width: 480, height: 150)
    static let shadowMargin: CGFloat = 24
    /// Bottom corner radius of the idle island, kept inside the physical notch's outline.
    static let notchCornerRadius: CGFloat = 10
    /// Flares at the top of the compact island, which take this much off each side of its frame.
    static let compactTopRadius: CGFloat = 6
    /// Height of the glyphs beside the notch, such as the timer's ring and digits.
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
    /// Each tab's button beside the notch, and the highlight behind the chosen one.
    static let tabButtonSize = CGSize(width: 30, height: 24)
    static let tabButtonSpacing: CGFloat = 2
    /// The least space between the notch and what sits beside it in the open island.
    static let besideNotchGap: CGFloat = 8

    /// Room for a tab's content below the notch: 100 pt below the MacBook Air's 32 pt notch.
    static func expandedContentRoom(_ notch: NotchMetrics) -> CGFloat {
        expandedSize.height - notch.size.height - expandedContentTopGap - expandedContentBottomInset
    }

    /// Room on either side of the notch in the open island, for the tabs on the left and the clock on the right:
    /// 106.5 pt beside the MacBook Air's 179 pt notch.
    static func besideNotchRoom(_ notch: NotchMetrics) -> CGFloat {
        (expandedSize.width - notch.size.width) / 2 - expandedContentInset - besideNotchGap
    }

    /// The fixed size of the window hosting the island: room for the open island and its shadow.
    static func canvasSize(_ notch: NotchMetrics) -> CGSize {
        CGSize(width: expandedSize.width + 2 * shadowMargin, height: expandedSize.height + shadowMargin)
    }

    let size: CGSize
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    /// - Parameter compactSlotWidth: The width of each slot beside the notch, or `nil` when nothing is live.
    init(_ presentation: IslandPresentation, notch: NotchMetrics, compactSlotWidth: CGFloat?) {
        let resting = compactSlotWidth.map {
            CGSize(width: notch.size.width + 2 * ($0 + Self.compactInset(notch)), height: notch.compactHeight)
        } ?? notch.size
        switch presentation {
        case .idle:
            // Without a notch to hide behind, the idle island folds away into the top edge.
            let size = notch.hasPhysicalNotch ? notch.size : CGSize(width: notch.size.width, height: 0)
            self.init(size: size, topRadius: 0, bottomRadius: Self.notchCornerRadius)
        case .compact:
            self.init(size: resting, topRadius: Self.compactTopRadius, bottomRadius: 14)
        case .lifted:
            self.init(size: CGSize(width: resting.width + 24, height: resting.height + 6), topRadius: Self.compactTopRadius,
                      bottomRadius: 14)
        case .peek:
            self.init(size: CGSize(width: max(340, resting.width), height: notch.size.height + 38), topRadius: 10,
                      bottomRadius: 24)
        case .expanded:
            self.init(size: Self.expandedSize, topRadius: 14, bottomRadius: 32)
        }
    }

    /// Where the island sits on screen: hanging from the top of its panel, centered on it.
    func frame(hangingFrom panel: CGRect) -> CGRect {
        CGRect(x: panel.midX - size.width / 2, y: panel.maxY - size.height, width: size.width, height: size.height)
    }

    private init(size: CGSize, topRadius: CGFloat, bottomRadius: CGFloat) {
        self.size = size
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }
}
