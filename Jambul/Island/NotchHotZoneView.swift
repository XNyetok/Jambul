import AppKit

/// An invisible view over the notch, or the top center of a screen without one. It notices the pointer there, so the
/// island's window can ignore the mouse while the island is idle.
final class NotchHotZoneView: NSView {
    var onHoverChange: (@MainActor (Bool) -> Void)?
    var onClick: (@MainActor () -> Void)?

    /// Where the notch sits within the view. The window is framed on whole points; the notch may sit on a half one.
    var notchFrame: CGRect = .zero {
        didSet { withoutAnimation { fill.frame = notchFrame } }
    }

    /// Fills the notch's shape in black, hidden behind the notch itself; screens without a notch would show the
    /// fill, so there it stays clear. Clicks don't depend on it: the hot zone's window sets `ignoresMouseEvents` to
    /// false, so it takes every click across its frame, clear pixels too.
    var drawsNotch = true {
        didSet { withoutAnimation { fill.isHidden = !drawsNotch } }
    }

    private let fill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.backgroundColor = NSColor.black.cgColor
        fill.cornerRadius = IslandLayout.notchCornerRadius
        fill.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
