import AppKit
import SwiftUI

/// Rocky's colors until the visual design milestone defines the palette. Rocky is dark-only for now: these
/// backgrounds are dark, and the system text colors of light mode would not be readable on them.
enum Theme {
    /// #23272E, chosen by the user on 2026-09-23. The system window color is tinted by the wallpaper.
    static let background = NSColor(srgbRed: 0x23 / 255, green: 0x27 / 255, blue: 0x2E / 255, alpha: 1)
    /// A little darker than `background`, so the sidebar reads as its own column.
    static let sidebar = NSColor(srgbRed: 0x1E / 255, green: 0x21 / 255, blue: 0x27 / 255, alpha: 1)
    /// The loading arc (`CircularProgress`).
    static let progressTint = Color.accentColor
}

extension Color {
    static let rockyBackground = Color(nsColor: Theme.background)
    static let rockySidebar = Color(nsColor: Theme.sidebar)
}
