import Foundation

/// The words of the two panels' toggles: the sidebar's (View ▸ Show Sidebar, ⌃⌘S) and the right panel's (`PNL-02`,
/// `KBD-03`: View ▸ Show Pull Request Panel, ⌥⌘B). Each toggle and its menu command share one open state, so both
/// read their words from here.
public enum PanelToggleText {
    /// The View menu's command for the sidebar, macOS's own wording.
    public static func sidebarMenuTitle(isVisible: Bool) -> String {
        isVisible ? "Hide Sidebar" : "Show Sidebar"
    }

    /// The tooltip of the sidebar's buttons, with the command's shortcut.
    public static func sidebarTooltip(isVisible: Bool) -> String {
        "\(isVisible ? "Hide" : "Show") sidebar (⌃⌘S)"
    }

    /// `KBD-03`: View ▸ Show / Hide Pull Request Panel.
    public static func pullRequestPanelMenuTitle(isOpen: Bool) -> String {
        isOpen ? "Hide Pull Request Panel" : "Show Pull Request Panel"
    }

    /// `PNL-02`'s tooltip: "Hide the pull request panel (⌥⌘B)" while it is open.
    public static func pullRequestPanelTooltip(isOpen: Bool) -> String {
        "\(pullRequestPanelAccessibilityLabel(isOpen: isOpen)) (⌥⌘B)"
    }

    /// The toggle's name for VoiceOver: the tooltip without the shortcut.
    public static func pullRequestPanelAccessibilityLabel(isOpen: Bool) -> String {
        "\(isOpen ? "Hide" : "Show") the pull request panel"
    }
}

/// Double-clicks on Rocky's title bar rows (`windowDragBackground`), which stand in for the hidden title bar: the
/// sidebar's top row, the workspace's top bar and the right panel's header (`PNL-01`).
public enum TitleBarDoubleClick {
    /// What a title bar double-click does, from System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar
    /// to".
    public enum Action: Equatable, Sendable {
        case zoom, minimize, none
    }

    /// The global default that holds that setting.
    public static let settingKey = "AppleActionOnDoubleClick"

    /// Whether a mouse-down ends a double-click on this view: the system counts a second click, and the first one also
    /// came to this view, no longer than the double-click interval before. A first click on a control that then moves
    /// away, such as a panel toggle whose panel folds, never reached the view, so `previousMouseDown` is nil and the
    /// second click only drags: the window does not zoom (user report, 2026-09-23).
    public static func isDoubleClick(
        clickCount: Int,
        timestamp: TimeInterval,
        previousMouseDown: TimeInterval?,
        interval: TimeInterval
    ) -> Bool {
        guard clickCount >= 2, let previousMouseDown else { return false }
        let elapsed = timestamp - previousMouseDown
        return elapsed >= 0 && elapsed <= interval
    }

    /// The setting's action: "Minimize" minimizes, "None" does nothing, and "Maximize", no setting or a value Rocky
    /// does not know zooms, as a title bar does by default.
    public static func action(setting: String?) -> Action {
        switch setting {
        case "Minimize": .minimize
        case "None": .none
        default: .zoom
        }
    }
}
