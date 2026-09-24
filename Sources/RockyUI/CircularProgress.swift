import SwiftUI

/// An indeterminate progress arc like Material UI's `<CircularProgress />`: the arc turns once every 1.4 s while it
/// grows to most of the circle and shrinks back. The numbers are MUI's `circular-rotate` and `circular-dash`
/// keyframes. It only redraws while it is on screen, and it is shown only while something is working.
struct CircularProgress: View {
    var size: CGFloat = 14
    var tint: Color = Theme.progressTint

    private static let period = 1.4
    /// MUI draws the circle in a 44-unit box with a 3.6-unit stroke: radius 20.2.
    private static let circumference = 2 * Double.pi * 20.2

    var body: some View {
        let size = Zoom.shared(size)
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
            let arc = Self.arc(at: t)
            Circle()
                .trim(from: CGFloat(arc.start), to: CGFloat(arc.end))
                .stroke(tint, style: StrokeStyle(lineWidth: max(1.5, size * 0.12), lineCap: .round))
                .rotationEffect(.degrees(360 * t))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Loading")
    }

    /// Start and end of the visible arc, as fractions of the circle, at `t` in 0..<1 of the loop.
    /// MUI's keyframes, in its circle units: dash 1 → 100 and offset 0 → -15 in the first half,
    /// then the dash stays 100 while the offset moves on to -125, so the arc shrinks from its tail.
    static func arc(at t: Double) -> (start: Double, end: Double) {
        let length: Double
        let offset: Double
        if t < 0.5 {
            let progress = easeInOut(t / 0.5)
            length = 1 + 99 * progress
            offset = 15 * progress
        } else {
            let progress = easeInOut((t - 0.5) / 0.5)
            length = 100
            offset = 15 + 110 * progress
        }
        return (offset / circumference, min(offset + length, circumference) / circumference)
    }

    /// CSS `ease-in-out`, `cubic-bezier(0.42, 0, 0.58, 1)`: find the curve parameter whose x is `x`, return its y.
    static func easeInOut(_ x: Double) -> Double {
        func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if bezier(middle, 0.42, 0.58) < x { low = middle } else { high = middle }
        }
        return bezier((low + high) / 2, 0, 1)
    }
}

/// The progress arc next to a label, for "Starting…" and other waits.
struct ProgressLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            CircularProgress()
            Text(text).foregroundStyle(.secondary)
        }
    }
}
