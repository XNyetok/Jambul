import AppKit

/// What the island needs to know about the notch it sits on.
struct NotchMetrics: Equatable {
    var size: CGSize
    /// Height of the compact island: the band macOS keeps clear across the top of the screen. Full-screen windows
    /// start below that band too (measured: y = 33 on the MacBook Air), so the island never covers them.
    var compactHeight: CGFloat
    var hasPhysicalNotch = true
}

/// Where the notch sits on a screen, in global screen coordinates (points).
struct NotchGeometry: Equatable {
    /// The physical notch, or a notch-sized area at the top center on screens without one.
    let notchRect: CGRect
    /// Height of the band macOS keeps clear across the top of the screen: the menu bar, which on notched screens
    /// is sized to hide the camera housing. With the menu bar hidden, a point past the safe area does the same.
    let bandHeight: CGFloat
    let screenFrame: CGRect
    let hasPhysicalNotch: Bool

    @MainActor
    init(screen: NSScreen) {
        self.init(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
                  leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
    }

    init(screenFrame frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat, leftArea: CGRect?, rightArea: CGRect?) {
        let menuBarHeight = frame.maxY - visibleFrame.maxY
        if safeAreaTop > 0, let leftArea, let rightArea {
            notchRect = CGRect(x: frame.minX + leftArea.width, y: frame.maxY - safeAreaTop,
                               width: frame.width - leftArea.width - rightArea.width, height: safeAreaTop)
            bandHeight = max(menuBarHeight, safeAreaTop.rounded(.up) + 1)
            hasPhysicalNotch = true
        } else {
            // With the menu bar hidden, visibleFrame reaches the top edge; fall back to a typical menu bar height.
            let height = max(menuBarHeight, 24)
            notchRect = CGRect(x: frame.midX - 90, y: frame.maxY - height, width: 180, height: height)
            bandHeight = height
            hasPhysicalNotch = false
        }
        screenFrame = frame
    }

    var metrics: NotchMetrics {
        NotchMetrics(size: notchRect.size, compactHeight: bandHeight, hasPhysicalNotch: hasPhysicalNotch)
    }

    /// A frame of `size` hanging from the top edge, centered on the notch. AppKit snaps window origins down to
    /// whole points and the notch can sit on a half point, so the origin stays whole and the width takes up the
    /// difference, which keeps the center exactly on the notch.
    func panelFrame(size: CGSize) -> CGRect {
        let x = notchRect.midX - size.width / 2
        let offset = x - x.rounded(.down)
        return CGRect(x: x - offset, y: screenFrame.maxY - size.height, width: size.width + 2 * offset,
                      height: size.height)
    }

    /// The smallest whole-point frame around the notch, for the hot zone's window.
    var hotZoneFrame: CGRect { notchRect.integral }

    /// The built-in notched screen if there is one, otherwise the main screen.
    @MainActor
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}
