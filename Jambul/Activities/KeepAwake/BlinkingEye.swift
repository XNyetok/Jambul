import AppKit
import SwiftUI

/// Keep Awake's eye, which opens as it turns on, blinks now and then while on, and closes as it turns off.
///
/// Core Animation draws and moves it. A repeating SwiftUI animation would redraw the island at 60 fps for as long as
/// Keep Awake is on (see docs/ARCHITECTURE.md); this only moves for the moment a blink takes, and not at all while
/// nobody can see the island or Reduce Motion is on. It blinks on the beat the laptop beside it types on (`KeepAwakeBeat`), so the two
/// move as one, and Jambul wakes once for both.
struct BlinkingEye: NSViewRepresentable {
    let pointSize: CGFloat
    /// False while Keep Awake is off: the eye closes, or appears closed.
    let isOpen: Bool
    /// Opens as it appears, for Keep Awake just turned on; otherwise it appears as it is.
    var opensAsItAppears = false
    var tint: Color = .white
    @Environment(\.islandIsVisible) private var isVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> EyeView {
        EyeView(pointSize: pointSize, tint: NSColor(tint), isOpen: isOpen,
                opensAsItAppears: isOpen && opensAsItAppears && !reduceMotion)
    }

    func updateNSView(_ view: EyeView, context: Context) {
        view.reduceMotion = reduceMotion
        view.tint = NSColor(tint)
        view.isOpen = isOpen
        view.blinks = isVisible && isOpen && !reduceMotion
    }
}

final class EyeView: NSView, BeatFollower {
    /// With Reduce Motion, the eye opens and closes without moving.
    var reduceMotion = false

    var tint: NSColor {
        didSet { if tint != oldValue { drawSymbol() } }
    }

    var isOpen: Bool {
        didSet {
            guard isOpen != oldValue else { return }
            let duration = isOpen ? Motion.eyeOpen : Motion.eyeClose / .seconds(1)
            animateOpenness(to: isOpen ? 1 : Motion.eyeShut, over: duration)
        }
    }

    /// Whether it blinks every so often: while open, and while someone can see it.
    var blinks = false {
        didSet { if blinks != oldValue { followBeat() } }
    }

    private let eye = CALayer()
    private let pointSize: CGFloat
    private let beat: KeepAwakeBeat

    init(pointSize: CGFloat, tint: NSColor, isOpen: Bool, opensAsItAppears: Bool, beat: KeepAwakeBeat = .shared) {
        self.pointSize = pointSize
        self.tint = tint
        self.isOpen = isOpen
        self.beat = beat
        super.init(frame: .zero)
        wantsLayer = true
        eye.contentsGravity = .resizeAspect
        layer?.addSublayer(eye)
        if !isOpen || opensAsItAppears {
            eye.transform = CATransform3DMakeScale(1, Motion.eyeShut, 1)
        }
        if opensAsItAppears {
            animateOpenness(to: 1, over: Motion.eyeOpen)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        // Bounds and position rather than frame: a layer's frame isn't its size while it is squeezed shut.
        withoutActions {
            eye.bounds = CGRect(origin: .zero, size: bounds.size)
            eye.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        drawSymbol()
        followBeat()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawSymbol()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawSymbol()
    }

    func onBeat() {
        blink()
    }

    private func blink() {
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, Motion.eyeShut, 1]
        blink.keyTimes = [0, NSNumber(value: Motion.eyeBlinkShutAt), 1]
        blink.timingFunctions = [Motion.eyeShutting, Motion.eyeOpening]
        blink.duration = Motion.eyeBlink
        eye.add(blink, forKey: "blink")
    }

    private func drawSymbol() {
        let scale = window?.backingScaleFactor ?? 2
        // A system color like cyan depends on the look it is drawn in: the island's own, which is dark.
        var color = tint
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = tint.usingColorSpace(.sRGB) ?? tint
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let symbol = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        withoutActions {
            eye.contentsScale = scale
            eye.contents = symbol?.layerContents(forContentsScale: scale)
        }
    }

    /// Blinks on the shared beat while it should, and while it is in a window.
    private func followBeat() {
        if blinks, window != nil {
            beat.add(self)
        } else {
            beat.remove(self)
        }
    }

    private func animateOpenness(to openness: CGFloat, over duration: TimeInterval) {
        // From wherever it is now, even halfway through a blink.
        let from = (eye.presentation() ?? eye).value(forKeyPath: "transform.scale.y")
        eye.removeAnimation(forKey: "blink")
        withoutActions { eye.transform = CATransform3DMakeScale(1, openness, 1) }
        guard !reduceMotion else { return }
        let move = CABasicAnimation(keyPath: "transform.scale.y")
        move.fromValue = from
        move.toValue = openness
        move.duration = duration
        move.timingFunction = openness < 1 ? Motion.eyeShutting : Motion.eyeOpening
        eye.add(move, forKey: "openness")
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}

/// Something that moves on Keep Awake's beat: the eye blinks, the laptop types its code again.
@MainActor
protocol BeatFollower: AnyObject {
    func onBeat()
}

/// The beat Keep Awake's glyphs move on: one wait at a time, a little different each, and every glyph on screen moves as
/// it ends. The eye and the laptop beside the notch then move as one, and Jambul wakes once per beat however many glyphs
/// show. Nothing runs while none moves.
@MainActor
final class KeepAwakeBeat {
    static let shared = KeepAwakeBeat()

    private struct Member {
        weak var follower: (any BeatFollower)?
    }

    private var members: [ObjectIdentifier: Member] = [:]
    private var beat: Task<Void, Never>?
    private let gap: () -> TimeInterval

    /// - Parameter gap: The wait before each beat; tests pass their own.
    init(gap: @escaping () -> TimeInterval = { .random(in: Motion.eyeBlinkGap) }) {
        self.gap = gap
    }

    /// Whether it is counting down to a beat.
    var isRunning: Bool { beat != nil }

    func add(_ follower: any BeatFollower) {
        members[ObjectIdentifier(follower)] = Member(follower: follower)
        guard beat == nil else { return }
        beat = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.gap() else { return }
                try? await Task.sleep(for: .seconds(wait), tolerance: Motion.eyeBlinkTolerance)
                guard !Task.isCancelled, let self else { return }
                tick()
            }
        }
    }

    func remove(_ follower: any BeatFollower) {
        members[ObjectIdentifier(follower)] = nil
        if members.isEmpty { stop() }
    }

    /// Every glyph moves at once.
    func tick() {
        members = members.filter { $0.value.follower != nil }
        guard !members.isEmpty else { return stop() }
        for member in members.values { member.follower?.onBeat() }
    }

    private func stop() {
        beat?.cancel()
        beat = nil
    }
}
