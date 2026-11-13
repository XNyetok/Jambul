import CoreGraphics
import SwiftUI
import Testing
@testable import Jambul

struct NotchGeometryTests {
    /// MacBook Air 13" at its default 1470×956 scale, as macOS 27 reports it, with the Dock hidden. The notch starts
    /// on a half point.
    private let macBookAir = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                           visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923), safeAreaTop: 32,
                                           leftArea: CGRect(x: 0, y: 924, width: 645.5, height: 32),
                                           rightArea: CGRect(x: 824.5, y: 924, width: 645.5, height: 32))

    @Test func findsThePhysicalNotchBetweenTheTopCorners() {
        #expect(macBookAir.hasPhysicalNotch)
        #expect(macBookAir.notchRect == CGRect(x: 645.5, y: 924, width: 179, height: 32))
    }

    @Test func theBandIsTheMenuBar() {
        #expect(macBookAir.bandHeight == 33)
    }

    @Test func withTheMenuBarHiddenTheBandStillClearsTheNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let geometry = NotchGeometry(screenFrame: frame, visibleFrame: frame, safeAreaTop: 32,
                                     leftArea: CGRect(x: 0, y: 924, width: 645.5, height: 32),
                                     rightArea: CGRect(x: 824.5, y: 924, width: 645.5, height: 32))
        #expect(geometry.bandHeight == 33)
    }

    @Test func theCompactIslandFillsTheBand() {
        // Full-screen windows start at the band's bottom too, so this never covers them.
        #expect(macBookAir.metrics.compactHeight == 33)
    }

    @Test func panelsSitOnWholePointsCenteredOnTheNotch() {
        let island = macBookAir.panelFrame(size: CGSize(width: 528, height: 174))
        #expect(island == CGRect(x: 471, y: 782, width: 528, height: 174))
        #expect(island.midX == macBookAir.notchRect.midX)

        let hotZone = macBookAir.hotZoneFrame
        #expect(hotZone == CGRect(x: 645, y: 924, width: 180, height: 32))
        #expect(hotZone.contains(macBookAir.notchRect))
    }

    @Test func theIslandHangsFromTheScreenTopCenteredOnTheNotch() {
        // Where the pointer is looked for as a peek appears under it.
        let panel = macBookAir.panelFrame(size: IslandLayout.canvasSize(macBookAir.metrics))
        let layout = IslandLayout(.peek, notch: macBookAir.metrics, compactSlotWidth: nil)
        let peek = layout.frame(hangingFrom: panel)
        #expect(peek.size == layout.size)
        #expect(peek.midX == macBookAir.notchRect.midX)
        #expect(peek.maxY == 956)
    }

    @Test func aPeekWithASecondLineIsALineTaller() {
        let one = IslandLayout(.peek, notch: macBookAir.metrics, compactSlotWidth: nil)
        let two = IslandLayout(.peek, notch: macBookAir.metrics, compactSlotWidth: nil, peekHasSubtitle: true)
        #expect(two.size.height == one.size.height + IslandLayout.peekSubtitleHeight)
        #expect(two.size.width == one.size.width)
    }

    @Test func aNotchCenteredOnAHalfPointWidensThePanelInsteadOfShiftingIt() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923), safeAreaTop: 32,
                                     leftArea: CGRect(x: 0, y: 924, width: 645, height: 32),
                                     rightArea: CGRect(x: 824, y: 924, width: 646, height: 32))
        let frame = geometry.panelFrame(size: CGSize(width: 528, height: 174))
        #expect(frame.minX == 470)
        #expect(frame.width == 529)
        #expect(frame.midX == geometry.notchRect.midX)
    }

    @Test func placesAVirtualNotchAtTheTopOfAnExternalDisplay() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 1470, y: 0, width: 1920, height: 1080),
                                     visibleFrame: CGRect(x: 1470, y: 0, width: 1920, height: 1056), safeAreaTop: 0,
                                     leftArea: nil, rightArea: nil)
        #expect(!geometry.hasPhysicalNotch)
        #expect(geometry.notchRect == CGRect(x: 2340, y: 1056, width: 180, height: 24))
        #expect(geometry.bandHeight == 24)
    }

    @Test func keepsTheVirtualNotchWhenTheMenuBarHides() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let geometry = NotchGeometry(screenFrame: frame, visibleFrame: frame, safeAreaTop: 0, leftArea: nil, rightArea: nil)
        #expect(geometry.notchRect.height == 24)
    }

    /// A pointer pushed against the top of the screen reads the screen's `maxY`, so a frame hanging from the top holds it,
    /// as AppKit counts the pointer: the top edge in, the bottom edge out.
    @Test func aFrameHangingFromTheTopHoldsAPointerPushedAgainstIt() {
        let island = CGRect(x: 589, y: 923, width: 292, height: 33)
        #expect(island.containsPointer(at: CGPoint(x: 700, y: 956)))
        #expect(!island.contains(CGPoint(x: 700, y: 956)))
        #expect(!island.containsPointer(at: CGPoint(x: 700, y: 923)))
        #expect(island.containsPointer(at: CGPoint(x: 700, y: 940)))
    }
}

struct IslandLayoutTests {
    private let notch = NotchMetrics(size: CGSize(width: 180, height: 32), compactHeight: 33)

    @Test func withoutANotchTheIdleIslandFoldsIntoTheTopEdge() {
        var screenWithoutNotch = notch
        screenWithoutNotch.hasPhysicalNotch = false
        #expect(IslandLayout(.idle, notch: screenWithoutNotch, compactSlotWidth: nil).size.height == 0)
        #expect(IslandLayout(.idle, notch: notch, compactSlotWidth: nil).size == notch.size)
    }

    @Test func theCompactIslandIsAsTallAsTheBand() {
        let compact = IslandLayout(.compact, notch: notch, compactSlotWidth: 40)
        #expect(compact.size.height == 33)
        #expect(compact.size.width == 180 + 2 * (40 + IslandLayout.compactInset(notch)))
    }

    /// Apple asks for even margins around content in the Dynamic Island. Measured from the frame, the flares at the
    /// top once cut the side margin to 4 pt beside 8.5 pt above and below, and the content looked cramped.
    @Test func compactContentSitsAsFarFromTheSidesAsFromTheTopAndBottom() {
        let compact = IslandLayout(.compact, notch: notch, compactSlotWidth: 42)
        let outline = IslandShape(topRadius: compact.topRadius, bottomRadius: compact.bottomRadius)
            .path(in: CGRect(origin: .zero, size: compact.size))
        let middle = compact.size.height / 2
        // Where the island is drawn at mid-height, to the half point.
        let edge = stride(from: 0, to: compact.size.width / 2, by: 0.5).first {
            outline.contains(CGPoint(x: $0 + 0.25, y: middle))
        }
        let sideMargin = IslandLayout.compactInset(notch) - (edge ?? 0)
        let verticalMargin = (compact.size.height - IslandLayout.compactGlyphHeight) / 2
        #expect(sideMargin == verticalMargin)
        #expect(sideMargin == 8.5)
    }
}
