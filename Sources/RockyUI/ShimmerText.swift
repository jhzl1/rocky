import SwiftUI

/// Live activity's label (MOT-03): the text in `textSecondary` with a light band, peaking at `textPrimary`, that
/// sweeps left to right in 1.6 s and rests 0.5 s, instead of a spinner. When it stops being live it settles to
/// `settledColor` in 150 ms, with the same text and font, so nothing moves. At most 30 frames a second, paused while
/// the window cannot be seen (`windowIsVisible`), static `textSecondary` with Reduce Motion.
struct ShimmerText: View {
    let text: String
    var isLive = true
    var settledColor: Color = Theme.textPrimary
    @Environment(\.windowIsVisible) private var windowIsVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sweep = 1.6
    private static let rest = 0.5
    /// The band's width, as a share of the text's.
    private static let band = 0.4

    init(_ text: String, isLive: Bool = true, settledColor: Color = Theme.textPrimary) {
        self.text = text
        self.isLive = isLive
        self.settledColor = settledColor
    }

    var body: some View {
        Text(text)
            .foregroundStyle(isLive ? Theme.textSecondary : settledColor)
            .overlay {
                if isLive, !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !windowIsVisible)) { context in
                        Text(text)
                            .foregroundStyle(Theme.textPrimary)
                            .mask(Self.mask(at: context.date))
                    }
                    .transition(.opacity)
                }
            }
            .animation(Theme.Motion.state, value: isLive)
    }

    /// The band at `date`: its center goes from just before the text to just after it during the sweep, then waits.
    private static func mask(at date: Date) -> LinearGradient {
        let cycle = sweep + rest
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        let progress = min(elapsed / sweep, 1)
        let center = -band / 2 + progress * (1 + band)
        return LinearGradient(
            stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.5), .init(color: .clear, location: 1)],
            startPoint: UnitPoint(x: center - band / 2, y: 0.5),
            endPoint: UnitPoint(x: center + band / 2, y: 0.5)
        )
    }
}
