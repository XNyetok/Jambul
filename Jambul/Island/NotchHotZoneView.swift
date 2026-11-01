import AppKit

/// An invisible view covering the physical notch. It notices the pointer while the island is idle,
/// so the island window never has to catch clicks anywhere outside the notch.
final class NotchHotZoneView: NSView {
    var onHoverChange: (@MainActor (Bool) -> Void)?
    var onClick: (@MainActor () -> Void)?

    /// Where the notch sits within the view. The window is framed on whole points; the notch may sit on a half one.
    var notchFrame: CGRect = .zero {
        didSet { withoutAnimation { fill.frame = notchFrame } }
    }

    /// The window server lets clicks fall through fully transparent pixels, so the hot zone fills the notch's
    /// shape in black, hidden behind the notch itself. Screens without a notch would show the fill, so there
    /// it stays clear and responds to hover alone.
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
