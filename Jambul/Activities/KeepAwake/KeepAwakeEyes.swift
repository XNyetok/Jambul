import AppKit
import SwiftUI

/// How Keep Awake's eyes close as it turns off: each expression plays once, and ends with the eyes shut.
enum EyesClosing: Equatable {
    /// They droop and shut: the owner turned it off.
    case plain
    /// They smile, then shut: the Claude Code sessions it stayed on for have finished.
    case smile
    /// They grow heavy, then shut: the battery ran low.
    case tired
}

/// The sizes Keep Awake's eyes come in.
enum EyesSize {
    /// Beside the notch, as tall as the other glyphs there.
    case compact
    /// On its card on Home and in its peeks: the compact eyes scaled to the card's 18 pt glyph row.
    case card
    /// On its tab, inside the face: the compact eyes scaled to 40 pt.
    case face
    // The eyes that fly from beside the notch are scaled by height to the larger sizes' boxes, so each larger size is
    // the compact one scaled to its box, give or take the half point that keeps its edges sharp: they land just where
    // the eyes that belong there are.

    var metrics: EyesMetrics {
        switch self {
        case .compact:
            EyesMetrics(box: CGSize(width: 16, height: 16), eye: CGSize(width: 6.5, height: 10), gap: 3,
                        glintRadius: 1.1, glintInset: CGPoint(x: 2.25, y: 2.5), lineWidth: 1.8, lidDepth: 1.6,
                        glance: 0.75)
        case .card:
            EyesMetrics(box: CGSize(width: 18, height: 18), eye: CGSize(width: 7.5, height: 11), gap: 3,
                        glintRadius: 1.25, glintInset: CGPoint(x: 2.5, y: 2.75), lineWidth: 2, lidDepth: 1.8,
                        glance: 0.85)
        case .face:
            EyesMetrics(box: CGSize(width: 40, height: 40), eye: CGSize(width: 16, height: 25), gap: 8,
                        glintRadius: 2.75, glintInset: CGPoint(x: 5.6, y: 6.25), lineWidth: 3.8, lidDepth: 3.5,
                        glance: 2.5)
        }
    }
}

/// The measures of a pair of eyes, in points. The eyes' edges fall on half points, so they stay sharp on a 2x display.
struct EyesMetrics: Equatable {
    /// The view's own size, with the eyes in its middle. As tall as it is wide, so the eyes that fly from beside the
    /// notch, scaled by height, land as wide as these.
    let box: CGSize
    let eye: CGSize
    let gap: CGFloat
    let glintRadius: CGFloat
    /// From an eye's top left to the middle of its glint.
    let glintInset: CGPoint
    /// The line a shut or smiling eye is drawn with.
    let lineWidth: CGFloat
    /// How far a shut eye's lid curves down.
    let lidDepth: CGFloat
    /// How far the eyes look aside in a glance.
    let glance: CGFloat
}

/// Keep Awake's eyes: two round-ended capsules with a glint each. They open as it turns on, blink or glance now and then
/// while on, and close as it turns off, into two lids curved like sleeping eyes. A pair of tall capsules read as a pause
/// symbol, and a single shut eye as a flat line, so they are neither.
///
/// Core Animation draws and moves them, as it did the eye before them: a repeating SwiftUI animation would redraw the
/// island at 60 fps for as long as Keep Awake is on (see docs/ARCHITECTURE.md). They move only for the moment a blink, a
/// glance or an expression takes, on the beat every pair on screen shares (`KeepAwakeBeat`), and not at all while nobody
/// can see the island or Reduce Motion is on.
struct KeepAwakeEyes: NSViewRepresentable {
    let size: EyesSize
    /// False while Keep Awake is off or turning off: the eyes close, or appear closed.
    let isOpen: Bool
    /// Opens as it appears, for Keep Awake just turned on; otherwise it appears as it is.
    var opensAsItAppears = false
    /// How the eyes close the next time they do.
    var closing: EyesClosing = .plain
    var tint: Color
    /// The color of the shut lids.
    var lidColor: Color
    /// While shut, one eye peeks open, as the pointer rests on the sleeping face.
    var peeks = false
    /// Whether they keep the beat while open; a peek's eyes only close.
    var keepsTheBeat = true
    @Environment(\.islandIsVisible) private var isVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> EyesView {
        EyesView(metrics: size.metrics, tint: NSColor(tint), lidColor: NSColor(lidColor), isOpen: isOpen,
                 opensAsItAppears: isOpen && opensAsItAppears && !reduceMotion)
    }

    func updateNSView(_ view: EyesView, context: Context) {
        view.reduceMotion = reduceMotion
        view.tint = NSColor(tint)
        view.lidColor = NSColor(lidColor)
        // Before `isOpen`, so a change to closed closes the way it should.
        view.closing = closing
        view.isOpen = isOpen
        view.peeks = peeks
        view.moves = keepsTheBeat && isVisible && isOpen && !reduceMotion
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EyesView, context: Context) -> CGSize? {
        size.metrics.box
    }
}

final class EyesView: NSView, BeatFollower {
    /// With Reduce Motion, the eyes open, close and peek without moving.
    var reduceMotion = false

    var tint: NSColor {
        didSet { if tint != oldValue { paint() } }
    }

    var lidColor: NSColor {
        didSet { if lidColor != oldValue { paint() } }
    }

    /// How the eyes close the next time they do.
    var closing: EyesClosing = .plain

    var isOpen: Bool {
        didSet {
            guard isOpen != oldValue else { return }
            if isOpen { open() } else { close() }
        }
    }

    /// While shut, the left eye peeks half open.
    var peeks = false {
        didSet { if peeks != oldValue { peek() } }
    }

    /// Whether they blink and glance on the beat: while open, and while someone can see them.
    var moves = false {
        didSet { if moves != oldValue { followBeat() } }
    }

    /// What shows once any motion settles, for tests: the open eyes, the shut lids, and how far each eye is open.
    var showsEyes: Bool { eyes.allSatisfy { $0.opacity > 0 } }
    var showsLids: Bool { lids.allSatisfy { $0.opacity > 0 } }
    var eyeOpenness: [CGFloat] { eyes.map { $0.opacity > 0 ? $0.transform.m22 : 0 } }

    let metrics: EyesMetrics
    /// Both eyes, moved aside together in a glance.
    private let pair = CALayer()
    private let eyes: [CALayer]
    private let glints: [CALayer]
    private let lids: [CAShapeLayer]
    private let smiles: [CAShapeLayer]
    private let beat: KeepAwakeBeat

    init(metrics: EyesMetrics, tint: NSColor, lidColor: NSColor, isOpen: Bool, opensAsItAppears: Bool,
         beat: KeepAwakeBeat = .shared) {
        self.metrics = metrics
        self.tint = tint
        self.lidColor = lidColor
        self.isOpen = isOpen
        self.beat = beat
        eyes = [CALayer(), CALayer()]
        glints = [CALayer(), CALayer()]
        lids = [CAShapeLayer(), CAShapeLayer()]
        smiles = [CAShapeLayer(), CAShapeLayer()]
        super.init(frame: CGRect(origin: .zero, size: metrics.box))
        wantsLayer = true
        withoutActions {
            build()
            show(open: isOpen && !opensAsItAppears)
        }
        paint()
        if opensAsItAppears { open() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        withoutActions { pair.position = CGPoint(x: bounds.midX, y: bounds.midY) }
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

    func onBeat(_ move: BeatMove) {
        guard isOpen else { return }
        switch move {
        case .blink: blink()
        case .glance(let toRight): glance(toRight: toRight)
        }
    }

    // MARK: Drawing

    /// Lays the eyes, their glints, lids and smiles out in the pair's own space, which has its origin at the bottom left.
    private func build() {
        let box = metrics.box, eye = metrics.eye
        pair.bounds = CGRect(origin: .zero, size: box)
        let left = (box.width - 2 * eye.width - metrics.gap) / 2, bottom = (box.height - eye.height) / 2
        for index in 0..<2 {
            let x = left + CGFloat(index) * (eye.width + metrics.gap)
            let shape = eyes[index]
            shape.bounds = CGRect(origin: .zero, size: eye)
            shape.position = CGPoint(x: x + eye.width / 2, y: bottom + eye.height / 2)
            shape.cornerRadius = eye.width / 2
            let glint = glints[index], radius = metrics.glintRadius
            glint.bounds = CGRect(x: 0, y: 0, width: 2 * radius, height: 2 * radius)
            glint.cornerRadius = radius
            glint.position = CGPoint(x: metrics.glintInset.x, y: eye.height - metrics.glintInset.y)
            shape.addSublayer(glint)

            // A shut eye: a lid curving down a little below the eye's middle.
            let lidY = box.height / 2 - eye.height * 0.05
            let lid = CGMutablePath()
            lid.move(to: CGPoint(x: x, y: lidY))
            lid.addQuadCurve(to: CGPoint(x: x + eye.width, y: lidY),
                             control: CGPoint(x: x + eye.width / 2, y: lidY - 2 * metrics.lidDepth))
            // A smiling eye: an arch, its feet a little below the eye's middle.
            let smileY = box.height / 2 - eye.height * 0.18
            let smile = CGMutablePath()
            smile.move(to: CGPoint(x: x, y: smileY))
            smile.addQuadCurve(to: CGPoint(x: x + eye.width, y: smileY),
                               control: CGPoint(x: x + eye.width / 2, y: smileY + eye.height * 0.45))
            for (layer, path, width) in [(lids[index], lid, metrics.lineWidth), (smiles[index], smile, metrics.lineWidth * 1.15)] {
                layer.frame = pair.bounds
                layer.path = path
                layer.fillColor = nil
                layer.lineWidth = width
                layer.lineCap = .round
            }
            pair.addSublayer(lids[index])
            pair.addSublayer(smiles[index])
            pair.addSublayer(shape)
        }
        layer?.addSublayer(pair)
    }

    /// The eyes in their color as the island's dark look resolves it (a system color like cyan depends on it), the
    /// glints white, and the lids in theirs.
    private func paint() {
        var eyeColor = tint, lid = lidColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            eyeColor = tint.usingColorSpace(.sRGB) ?? tint
            lid = lidColor.usingColorSpace(.sRGB) ?? lidColor
        }
        withoutActions {
            for eye in eyes { eye.backgroundColor = eyeColor.cgColor }
            for glint in glints { glint.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor }
            for smile in smiles { smile.strokeColor = eyeColor.cgColor }
            for shut in lids { shut.strokeColor = lid.cgColor }
        }
    }

    /// Curves drawn at the display's own scale.
    private func sharpen() {
        let scale = window?.backingScaleFactor ?? 2
        withoutActions {
            for layer in [pair] + eyes + glints + lids + smiles { layer.contentsScale = scale }
        }
    }

    /// The resting look: open eyes, or shut lids. Peeking and expressions build on it.
    private func show(open: Bool) {
        for eye in eyes {
            eye.opacity = open ? 1 : 0
            eye.transform = CATransform3DIdentity
        }
        for lid in lids { lid.opacity = open ? 0 : 1 }
        for smile in smiles { smile.opacity = 0 }
        pair.transform = CATransform3DIdentity
    }

    // MARK: Motion

    private func blink() {
        for eye in eyes {
            let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
            blink.values = [1, Motion.eyeShut, 1]
            blink.keyTimes = [0, NSNumber(value: Motion.eyeBlinkShutAt), 1]
            blink.timingFunctions = [Motion.eyeShutting, Motion.eyeOpening]
            blink.duration = Motion.eyeBlink
            eye.add(blink, forKey: "blink")
        }
    }

    private func glance(toRight: Bool) {
        let glance = CAKeyframeAnimation(keyPath: "transform.translation.x")
        let aside = toRight ? metrics.glance : -metrics.glance
        glance.values = [0, aside, aside, 0]
        glance.keyTimes = [0, 0.2, 0.75, 1]
        glance.timingFunctions = [Motion.eyeOpening, CAMediaTimingFunction(name: .linear),
                                  CAMediaTimingFunction(name: .easeInEaseOut)]
        glance.duration = Motion.eyeGlance
        pair.add(glance, forKey: "glance")
    }

    /// Pops the eyes open past their size and back, from shut or from wherever a peek or a closing left them.
    private func open() {
        let from = eyes.map { ($0.presentation() ?? $0).value(forKeyPath: "transform.scale.y") as? CGFloat ?? 0 }
        let lidsFrom = lids.map { ($0.presentation() ?? $0).opacity }
        let shown = eyes.map { ($0.presentation() ?? $0).opacity }
        removeAllAnimations()
        withoutActions { show(open: true) }
        guard !reduceMotion else { return }
        for (index, eye) in eyes.enumerated() {
            let pop = CASpringAnimation(keyPath: "transform.scale.y")
            pop.fromValue = shown[index] > 0 ? max(from[index], Motion.eyeShut) : Motion.eyeShut
            pop.toValue = 1
            pop.stiffness = Motion.eyePopStiffness
            pop.damping = Motion.eyePopDamping
            pop.duration = pop.settlingDuration
            eye.add(pop, forKey: "openness")
            eye.add(fade(from: shown[index], to: 1, over: 0.08), forKey: "fade")
        }
        for (index, lid) in lids.enumerated() { lid.add(fade(from: lidsFrom[index], to: 0, over: 0.1), forKey: "fade") }
    }

    /// Plays the closing expression, and rests with the lids shut.
    private func close() {
        let style = closing
        removeAllAnimations()
        withoutActions { show(open: false) }
        guard !reduceMotion else { return }
        let total = Motion.eyesClosing(style) / .seconds(1)
        switch style {
        case .plain:
            // Droops a little as it shuts, then the lids take its place.
            shut(scales: [1, 0.55, Motion.eyeShut], keyTimes: [0, 0.45, 1], drop: [0, 0.6, 1], over: total * 0.8)
            showLids(after: total * 0.72, over: total * 0.24)
        case .smile:
            for eye in eyes { eye.add(fade(from: 1, to: 0, over: 0.12), forKey: "fade") }
            for smile in smiles {
                let smiling = CAKeyframeAnimation(keyPath: "opacity")
                smiling.values = [0, 1, 1, 0]
                smiling.keyTimes = [0, 0.1, 0.72, 0.9]
                smiling.duration = total
                smile.add(smiling, forKey: "smile")
            }
            showLids(after: total * 0.72, over: total * 0.25)
        case .tired:
            // Heavy lids first, a moment's hold, then shut.
            shut(scales: [1, 0.42, 0.48, Motion.eyeShut], keyTimes: [0, 0.3, 0.68, 1], drop: [0, 0.8, 0.8, 1],
                 over: total * 0.88)
            showLids(after: total * 0.84, over: total * 0.14)
        }
    }

    /// The eyes squeezing shut through `scales` and sinking by parts of a tenth of their height, staying visible until
    /// they are shut.
    private func shut(scales: [CGFloat], keyTimes: [NSNumber], drop: [CGFloat], over duration: TimeInterval) {
        for eye in eyes {
            let squeeze = CAKeyframeAnimation(keyPath: "transform.scale.y")
            squeeze.values = scales
            squeeze.keyTimes = keyTimes
            squeeze.timingFunction = Motion.eyeShutting
            let sink = CAKeyframeAnimation(keyPath: "transform.translation.y")
            sink.values = drop.map { -$0 * metrics.eye.height * 0.1 }
            sink.keyTimes = keyTimes
            let visible = CAKeyframeAnimation(keyPath: "opacity")
            visible.values = [1, 1, 0]
            visible.keyTimes = [0, 0.9, 1]
            let group = CAAnimationGroup()
            group.animations = [squeeze, sink, visible]
            for part in [squeeze, sink, visible] { part.duration = duration }
            group.duration = duration
            eye.add(group, forKey: "closing")
        }
    }

    private func showLids(after delay: TimeInterval, over duration: TimeInterval) {
        for lid in lids {
            let appear = fade(from: 0, to: 1, over: duration)
            appear.beginTime = lid.convertTime(CACurrentMediaTime(), from: nil) + delay
            // Hidden until its turn comes.
            appear.fillMode = .backwards
            lid.add(appear, forKey: "fade")
        }
    }

    /// The left eye peeking half open from its sleep, or shutting again.
    private func peek() {
        guard !isOpen, let eye = eyes.first, let lid = lids.first else { return }
        let from = (eye.presentation() ?? eye).value(forKeyPath: "transform.scale.y") as? CGFloat ?? Motion.eyeShut
        let shown = (eye.presentation() ?? eye).opacity, lidShown = (lid.presentation() ?? lid).opacity
        withoutActions {
            eye.opacity = peeks ? Float(Motion.eyePeekOpacity) : 0
            eye.transform = peeks ? CATransform3DMakeScale(1, Motion.eyePeek, 1) : CATransform3DIdentity
            lid.opacity = peeks ? 0 : 1
        }
        guard !reduceMotion else { return }
        let move = CASpringAnimation(keyPath: "transform.scale.y")
        move.fromValue = shown > 0 ? from : Motion.eyeShut
        move.toValue = peeks ? Motion.eyePeek : Motion.eyeShut
        move.stiffness = Motion.eyePopStiffness
        move.damping = Motion.eyePopDamping
        move.duration = move.settlingDuration
        eye.add(move, forKey: "openness")
        eye.add(fade(from: shown, to: eye.opacity, over: peeks ? 0.08 : 0.2), forKey: "fade")
        lid.add(fade(from: lidShown, to: lid.opacity, over: 0.12), forKey: "fade")
    }

    private func fade(from: Float, to: Float, over duration: TimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        return fade
    }

    private func removeAllAnimations() {
        for layer in [pair] + eyes + lids + smiles { layer.removeAllAnimations() }
    }

    /// Moves on the shared beat while it should, and while it is in a window.
    private func followBeat() {
        if moves, window != nil {
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
