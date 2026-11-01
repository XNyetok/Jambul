import AppKit
import SwiftUI

/// Keep Awake's laptop, beside the notch on the right of its eye: a screen with three lines of code, typed out as Keep
/// Awake turns on, typed again on each beat while on, and cleared as it turns off.
///
/// Core Animation draws and moves it, like the eye, and only for the moment the typing takes: on the beat the eye blinks
/// on (`KeepAwakeBeat`), and not at all while nobody can see the island or Reduce Motion is on.
struct TypingLaptop: NSViewRepresentable {
    /// False while Keep Awake is off or turning off: the code clears.
    let isOn: Bool
    /// Types the code out as it appears, for Keep Awake just turned on; otherwise it appears as it is.
    var typesAsItAppears = false
    var tint: Color = .white
    @Environment(\.islandIsVisible) private var isVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LaptopView {
        LaptopView(tint: NSColor(tint), isOn: isOn, typesAsItAppears: isOn && typesAsItAppears && !reduceMotion)
    }

    func updateNSView(_ view: LaptopView, context: Context) {
        view.reduceMotion = reduceMotion
        view.tint = NSColor(tint)
        view.isOn = isOn
        view.types = isVisible && isOn && !reduceMotion
    }
}

/// Keep Awake's laptop as its tab shows it: the one beside the notch, held still with its code showing. Only its color
/// changes, at once, as Keep Awake turns on or off; it never types, and never joins the beat.
struct StillLaptop: NSViewRepresentable {
    let tint: Color

    func makeNSView(context: Context) -> LaptopView {
        LaptopView(tint: NSColor(tint), isOn: true, typesAsItAppears: false)
    }

    func updateNSView(_ view: LaptopView, context: Context) {
        view.tint = NSColor(tint)
    }
}

final class LaptopView: NSView, BeatFollower {
    /// The laptop's own size in points, scaled to fit its view.
    static let size = CGSize(width: 22, height: 16)
    /// Each line of code: how far it is indented, and how long it is.
    static let code: [(indent: CGFloat, length: CGFloat)] = [(0, 8.5), (2.5, 6), (0, 10)]

    /// With Reduce Motion, the code shows and clears without being typed.
    var reduceMotion = false

    var tint: NSColor {
        didSet { if tint != oldValue { paint() } }
    }

    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            if isOn { type() } else { clear() }
        }
    }

    /// Whether it types its code again on each beat: while on, and while someone can see it.
    var types = false {
        didSet { if types != oldValue { followBeat() } }
    }

    /// How much of each line shows once any typing settles, from 0 to 1.
    var typed: [CGFloat] { lines.map(\.transform.m11) }

    /// The color its screen and base are painted in.
    var painted: NSColor? { screen.backgroundColor.flatMap { NSColor(cgColor: $0) } }

    private let laptop = CALayer()
    private let base = CALayer()
    private let screen = CALayer()
    private let lines: [CALayer]
    private let beat: KeepAwakeBeat

    init(tint: NSColor, isOn: Bool, typesAsItAppears: Bool, beat: KeepAwakeBeat = .shared) {
        self.tint = tint
        self.isOn = isOn
        self.beat = beat
        lines = Self.code.map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        withoutActions {
            laptop.bounds = CGRect(origin: .zero, size: Self.size)
            // On whole and half points, so the edges fall on the pixels of a 2x display.
            base.frame = CGRect(x: 0.5, y: 1, width: 21, height: 2)
            base.cornerRadius = 1
            screen.frame = CGRect(x: 3, y: 3.5, width: 16, height: 11)
            screen.cornerRadius = 2
            laptop.addSublayer(base)
            laptop.addSublayer(screen)
            for (index, line) in lines.enumerated() {
                let code = Self.code[index]
                // Anchored on the left, so a line grows from where it starts, as typed text does.
                line.anchorPoint = CGPoint(x: 0, y: 0.5)
                line.bounds = CGRect(x: 0, y: 0, width: code.length, height: 1.5)
                line.position = CGPoint(x: 2.5 + code.indent, y: 7.75 - CGFloat(index) * 3)
                line.cornerRadius = 0.75
                // The island's black, so the code reads as cut out of the screen, like the pupil out of the eye.
                line.backgroundColor = NSColor.black.cgColor
                screen.addSublayer(line)
            }
            layer?.addSublayer(laptop)
            setTyped(isOn && !typesAsItAppears ? 1 : 0)
        }
        paint()
        if typesAsItAppears { type() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let scale = min(bounds.width / Self.size.width, bounds.height / Self.size.height)
        withoutActions {
            laptop.position = CGPoint(x: bounds.midX, y: bounds.midY)
            laptop.transform = CATransform3DMakeScale(scale, scale, 1)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sharpen()
        paint()
        followBeat()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sharpen()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    func onBeat() {
        type()
    }

    /// Types the lines out one after another, each in a few steps, as characters appear.
    private func type() {
        withoutActions { setTyped(1) }
        guard !reduceMotion else { return }
        for (index, line) in lines.enumerated() {
            line.removeAnimation(forKey: "clearing")
            let typing = CAKeyframeAnimation(keyPath: "transform.scale.x")
            typing.values = [0, 0.25, 0.5, 0.75, 1]
            typing.calculationMode = .discrete
            typing.duration = Motion.laptopLineTyping
            typing.beginTime = line.convertTime(CACurrentMediaTime(), from: nil) + Double(index) * Motion.laptopLineGap
            // Blank until its turn comes.
            typing.fillMode = .backwards
            line.add(typing, forKey: "typing")
        }
    }

    /// Clears the code from the last line up, as the eye beside it shuts.
    private func clear() {
        let shown = lines.map { ($0.presentation() ?? $0).transform.m11 }
        withoutActions { setTyped(0) }
        guard !reduceMotion else { return }
        let step = Motion.eyeClose / .seconds(1) / Double(lines.count)
        for (index, line) in lines.enumerated() {
            line.removeAnimation(forKey: "typing")
            let clearing = CABasicAnimation(keyPath: "transform.scale.x")
            clearing.fromValue = shown[index]
            clearing.toValue = 0
            clearing.duration = step
            clearing.beginTime = line.convertTime(CACurrentMediaTime(), from: nil)
                + Double(lines.count - 1 - index) * step
            clearing.fillMode = .backwards
            line.add(clearing, forKey: "clearing")
        }
    }

    private func setTyped(_ amount: CGFloat) {
        for line in lines { line.transform = CATransform3DMakeScale(amount, 1, 1) }
    }

    /// The screen and base in the tint, as the island's dark look resolves it: a system color like cyan depends on it.
    private func paint() {
        var color = tint
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = tint.usingColorSpace(.sRGB) ?? tint
        }
        withoutActions {
            base.backgroundColor = color.cgColor
            screen.backgroundColor = color.cgColor
        }
    }

    /// Rounded corners drawn at the display's own scale.
    private func sharpen() {
        let scale = window?.backingScaleFactor ?? 2
        withoutActions {
            for layer in [laptop, base, screen] + lines { layer.contentsScale = scale }
        }
    }

    /// Types on the shared beat while it should, and while it is in a window.
    private func followBeat() {
        if types, window != nil {
            beat.add(self)
        } else {
            beat.remove(self)
        }
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
