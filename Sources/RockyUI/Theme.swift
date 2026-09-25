import AppKit
import RockyKit
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

    // M2.5 tokens (docs/superpowers/design/2026-09-23-sidebar-topbar.html, TOK-01). The sidebar, top bar, tabs and
    // terminal panel use these instead of hierarchical styles, `Color.accentColor` or inline opacities, so their
    // contrast is the measured one.

    /// Above the sidebar footer.
    static let hairlineSoft = Color.white.opacity(0.06)
    /// The terminal panel's bar.
    static let panelBar = Color.white.opacity(0.03)
    /// Titles: 13.1 : 1 on the sidebar.
    static let textPrimary = Color(red: 0xE6 / 255, green: 0xE8 / 255, blue: 0xEB / 255)
    /// The repository in the top bar, fallback titles, unselected tabs: 6.8 : 1.
    static let textSecondary = Color(red: 0xA3 / 255, green: 0xA9 / 255, blue: 0xB1 / 255)
    /// Hints, PORT, a finished process's last line: 4.75 : 1.
    static let textTertiary = Color(red: 0x85 / 255, green: 0x8C / 255, blue: 0x95 / 255)
    /// The "/" in the top bar (decorative).
    static let separatorGlyph = Color(red: 0x5C / 255, green: 0x63 / 255, blue: 0x6C / 255)
    /// Row and panel tab hover and selection.
    static let fillHover = Color.white.opacity(0.04)
    static let fillSelected = Color.white.opacity(0.08)
    /// The search field.
    static let fillControl = Color.white.opacity(0.05)
    /// Icon buttons.
    static let fillIconHover = Color.white.opacity(0.06)
    static let fillPressed = Color.white.opacity(0.10)
    /// Run, Restart, the empty-state button.
    static let fillButton = Color.white.opacity(0.08)
    static let fillButtonHover = Color.white.opacity(0.12)
    static let fillButtonPressed = Color.white.opacity(0.16)
    /// The unread dot and the focus ring (the same value as `plan`). Never a selection fill.
    static let accent = Color(red: 0x78 / 255, green: 0xBD / 255, blue: 0xF5 / 255)
    /// Needs you.
    static let attention = Color(red: 0xE8 / 255, green: 0xA9 / 255, blue: 0x4B / 255)
    /// The error glyph, a failed process's dot, destructive menu items.
    static let danger = Color(red: 0xF0 / 255, green: 0x87 / 255, blue: 0x6A / 255)
    /// A running process's dot.
    static let success = Color(red: 0x7C / 255, green: 0xC0 / 255, blue: 0x8A / 255)
    /// A merged pull request: the header's merged group, Archive and the merged dot (HDR-01, #B48CF2).
    static let merged = Color(red: 0xB4 / 255, green: 0x8C / 255, blue: 0xF2 / 255)
    /// The "−D" of diff stats (GIT-03, CHG-03; #E48A8A), softer than `danger`. Their "+A" is `success`.
    static let diffDeletions = Color(red: 0xE4 / 255, green: 0x8A / 255, blue: 0x8A / 255)

    // M3 tokens (docs/superpowers/design/2026-09-23-m3-review-edit-pr.html, TOK-10).

    /// Added diff rows (DIFF-02): `success` at 12 %, their number columns at 20 %.
    static let diffAddLine = success.opacity(0.12)
    static let diffAddGutter = success.opacity(0.20)
    /// Removed diff rows: `danger` at 12 %, their number columns at 20 %.
    static let diffDeleteLine = danger.opacity(0.12)
    static let diffDeleteGutter = danger.opacity(0.20)
    /// Lines selected for a comment (CMT-01): `accent` at 14 %, with a 3-point `accent` bar at their left edge.
    static let commentRange = accent.opacity(0.14)
    /// The editor's caret line (EDIT-01): white at 3 %.
    static let currentLine = Color.white.opacity(0.03)
    /// The editor's selected text: `accent` at 30 %, the mock's `::selection`.
    static let editorSelection = accent.opacity(0.30)
    /// The mock's banners over a file tab's content (EDIT-02, EDIT-03): a warning (the file changed on disk) on
    /// `attention` at 10 % with #F0C987 text, a note (unsaved edits, the agent working) on `accent` at 8 % with #B7D9F7.
    static let bannerWarning = attention.opacity(0.10)
    static let bannerWarningText = Color(red: 0xF0 / 255, green: 0xC9 / 255, blue: 0x87 / 255)
    static let bannerInfo = accent.opacity(0.08)
    static let bannerInfoText = Color(red: 0xB7 / 255, green: 0xD9 / 255, blue: 0xF7 / 255)

    /// DIFF-04's token colors, one map for the diff and the editor.
    enum Syntax {
        static let keyword = Color(red: 0xC7 / 255, green: 0x92 / 255, blue: 0xEA / 255)
        static let string = Color(red: 0xA5 / 255, green: 0xD6 / 255, blue: 0xA7 / 255)
        static let number = Color(red: 0xF2 / 255, green: 0xA9 / 255, blue: 0x6B / 255)
        static let comment = Color(red: 0x7F / 255, green: 0x84 / 255, blue: 0x8E / 255)
        static let function = Color(red: 0x7C / 255, green: 0xB7 / 255, blue: 0xF2 / 255)
        static let type = Color(red: 0xE6 / 255, green: 0xC0 / 255, blue: 0x7B / 255)
    }

    /// A token's color; nil for plain text, which keeps the text's own color.
    static func syntax(_ kind: SyntaxKind) -> Color? {
        switch kind {
        case .plain: nil
        case .keyword: Syntax.keyword
        case .string: Syntax.string
        case .number: Syntax.number
        case .comment: Syntax.comment
        case .function: Syntax.function
        case .type: Syntax.type
        }
    }

    /// Repository monograms (SB-03): each repository's stored `colorIndex`. `RepoMonogram.paletteCount` is its size.
    static let repoPalette: [Color] = [
        Color(red: 0x4C / 255, green: 0x7B / 255, blue: 0xD9 / 255),
        Color(red: 0x8E / 255, green: 0x6B / 255, blue: 0xE0 / 255),
        Color(red: 0x3A / 255, green: 0x9C / 255, blue: 0x8C / 255),
        Color(red: 0xC9 / 255, green: 0x78 / 255, blue: 0x4A / 255),
        Color(red: 0xC2 / 255, green: 0x57 / 255, blue: 0x7A / 255),
        Color(red: 0x6E / 255, green: 0x8C / 255, blue: 0x3A / 255),
    ]

    /// The motion every view uses (TOK-03).
    enum Motion {
        /// Hover color and fill.
        static let hover = Animation.easeOut(duration: 0.12)
        /// Folding a repository or the panel, the sidebar toggle, a tool settling.
        static let state = Animation.easeOut(duration: 0.15)
        /// A new chat row fading in (MOT-02).
        static let enter = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.22)
    }
}

extension Color {
    static let rockyBackground = Color(nsColor: Theme.background)
    static let rockySidebar = Color(nsColor: Theme.sidebar)
}
