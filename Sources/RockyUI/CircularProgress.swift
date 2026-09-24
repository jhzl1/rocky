import AppKit
import SwiftUI

/// Rocky's spinner (MOT-01): a faint full ring with a quarter arc that turns once every 0.9 s, smoothly and without
/// end. Core Animation turns it in the render server, so Rocky does no work per frame (spec Section 1, energy): the
/// Material-style arc it replaced ran a `TimelineView(.animation)` body every display frame, once per spinner.
/// Frozen at its angle while the window cannot be seen (`windowIsVisible`), static with Reduce Motion.
struct CircularProgress: View {
    var size: CGFloat = 14
    var tint: Color = Theme.progressTint
    @Environment(\.windowIsVisible) private var windowIsVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SpinnerRepresentable(color: NSColor(tint), turns: !reduceMotion, paused: !windowIsVisible)
            .frame(width: Zoom.shared(size), height: Zoom.shared(size))
            .accessibilityElement()
            .accessibilityLabel("Loading")
    }
}

private struct SpinnerRepresentable: NSViewRepresentable {
    let color: NSColor
    let turns: Bool
    let paused: Bool

    func makeNSView(context: Context) -> SpinnerView {
        let view = SpinnerView()
        update(view)
        return view
    }

    func updateNSView(_ view: SpinnerView, context: Context) {
        update(view)
    }

    private func update(_ view: SpinnerView) {
        view.color = color
        view.turns = turns
        view.paused = paused
    }
}

/// The ring and the arc as two shape layers, in a 16-unit box: ring radius 5.5, stroke 1.8, ring at 22 %; the arc
/// from 12 to 3 o'clock with round caps.
private final class SpinnerView: NSView {
    private let ring = CAShapeLayer()
    private let arc = CAShapeLayer()
    private static let spinKey = "spin"

    var color: NSColor = .white {
        didSet { if color != oldValue { applyColors() } }
    }

    var turns = true {
        didSet { if turns != oldValue { restartAnimation() } }
    }

    var paused = false {
        didSet { if paused != oldValue { applyPause() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [ring, arc] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// It never takes a click meant for the tab or row it sits in.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let unit = side / 16
        let box = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let center = CGPoint(x: side / 2, y: side / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [ring, arc] {
            shape.bounds = CGRect(origin: .zero, size: box.size)
            shape.position = CGPoint(x: box.midX, y: box.midY)
            shape.lineWidth = 1.8 * unit
        }
        let circle = CGMutablePath()
        circle.addArc(center: center, radius: 5.5 * unit, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ring.path = circle
        // 12 o'clock to 3 o'clock, clockwise (layers here have y going up).
        let quarter = CGMutablePath()
        quarter.addArc(center: center, radius: 5.5 * unit, startAngle: .pi / 2, endAngle: 0, clockwise: true)
        arc.path = quarter
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // AppKit drops a layer's animations when its view leaves the window.
        restartAnimation()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeColor = color.withAlphaComponent(color.alphaComponent * 0.22).cgColor
        arc.strokeColor = color.cgColor
        CATransaction.commit()
    }

    private func restartAnimation() {
        arc.removeAnimation(forKey: Self.spinKey)
        arc.speed = 1
        arc.timeOffset = 0
        arc.beginTime = 0
        guard turns, window != nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi   // clockwise on screen
        spin.duration = 0.9
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: Self.spinKey)
        applyPause()
    }

    /// Freezes the arc at its angle (layer speed 0, keeping the time it reached) and resumes from that angle.
    private func applyPause() {
        guard arc.animation(forKey: Self.spinKey) != nil else { return }
        if paused, arc.speed != 0 {
            let now = arc.convertTime(CACurrentMediaTime(), from: nil)
            arc.speed = 0
            arc.timeOffset = now
        } else if !paused, arc.speed == 0 {
            let pausedAt = arc.timeOffset
            arc.speed = 1
            arc.timeOffset = 0
            arc.beginTime = 0
            arc.beginTime = arc.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        }
    }
}

/// The spinner next to a label, for "Starting…" and other waits.
struct ProgressLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            CircularProgress()
            Text(text).foregroundStyle(.secondary)
        }
    }
}
