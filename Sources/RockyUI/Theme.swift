import AppKit
import SwiftUI

/// Rocky's colors until the visual design milestone defines the palette. Rocky is dark-only for now: these
/// backgrounds are dark, and the system text colors of light mode would not be readable on them.
enum Theme {
    /// #23272E, chosen by the user on 2026-09-23. The system window color is tinted by the wallpaper.
    static let background = NSColor(srgbRed: 0x23 / 255, green: 0x27 / 255, blue: 0x2E / 255, alpha: 1)
    /// A little darker than `background`, so the sidebar reads as its own column.
    static let sidebar = NSColor(srgbRed: 0x1E / 255, green: 0x21 / 255, blue: 0x27 / 255, alpha: 1)
    /// Thin separators between areas (sidebar, header, panel), lighter than the system's black dividers.
    static let hairline = Color.white.opacity(0.08)
    /// Rocky's menus (`MenuPanel`), a little darker than the sidebar.
    static let panel = Color(red: 0x1A / 255, green: 0x1D / 255, blue: 0x22 / 255)
    /// The message box and the agent's question card: opaque, a little lighter than `background`, since they float
    /// over the conversation.
    static let composer = Color(red: 0x2A / 255, green: 0x2F / 255, blue: 0x37 / 255)
    static let composerBorder = Color.white.opacity(0.1)
    /// Plan mode's chip in the message box.
    static let plan = Color(red: 0.47, green: 0.74, blue: 0.96)
    /// The loading arc (`CircularProgress`).
    static let progressTint = Color.white.opacity(0.9)
}

extension Color {
    static let rockyBackground = Color(nsColor: Theme.background)
    static let rockySidebar = Color(nsColor: Theme.sidebar)
}
