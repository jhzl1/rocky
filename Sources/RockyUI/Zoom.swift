import AppKit
import SwiftUI

/// Rocky's zoom, like a browser's: View ▸ Zoom In (⌘+), Zoom Out (⌘-) and Actual Size (⌘0). Every font, and the
/// sizes that hold text (badges, menus, the reading column, the terminal), grow together. It scales sizes rather
/// than the rendered window: a scaled AppKit view (the message box, the terminal) stops receiving clicks near its
/// edges. Views read `scale` in their body, so a change redraws them. Remembered across launches.
@MainActor
@Observable
public final class Zoom {
    public static let shared = Zoom()

    public static let steps: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6, 1.8]
    private static let key = "zoom"

    public private(set) var scale: Double {
        didSet { UserDefaults.standard.set(scale, forKey: Self.key) }
    }

    private init() {
        // The nearest step: a value written as a 32-bit float reads back as 1.3999…, not 1.4.
        let saved = UserDefaults.standard.double(forKey: Self.key)
        scale = saved > 0 ? Self.steps.min { abs($0 - saved) < abs($1 - saved) } ?? 1 : 1
    }

    public var canZoomIn: Bool { scale < Self.steps.last! }
    public var canZoomOut: Bool { scale > Self.steps.first! }
    public var isActualSize: Bool { scale == 1 }

    public func zoomIn() {
        if let next = Self.steps.first(where: { $0 > scale }) { scale = next }
    }

    public func zoomOut() {
        if let previous = Self.steps.last(where: { $0 < scale }) { scale = previous }
    }

    public func reset() {
        scale = 1
    }

    /// `size` at the current zoom.
    func callAsFunction(_ size: CGFloat) -> CGFloat {
        size * scale
    }
}

extension Font {
    /// The system font at Rocky's zoom. For macOS's text styles: body 13, callout 12, caption 10, headline 13
    /// semibold.
    @MainActor
    static func rocky(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: Zoom.shared(size), weight: weight, design: design)
    }
}
