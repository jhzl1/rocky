import Foundation
@testable import RockyKit
import Testing

struct WindowControlsTests {
    /// KBD-03, PNL-02: the menu command and the toggle say the same thing about the right panel.
    @Test func pullRequestPanelWordsFollowItsState() {
        #expect(PanelToggleText.pullRequestPanelMenuTitle(isOpen: true) == "Hide Pull Request Panel")
        #expect(PanelToggleText.pullRequestPanelMenuTitle(isOpen: false) == "Show Pull Request Panel")
        #expect(PanelToggleText.pullRequestPanelTooltip(isOpen: true) == "Hide the pull request panel (⌥⌘B)")
        #expect(PanelToggleText.pullRequestPanelTooltip(isOpen: false) == "Show the pull request panel (⌥⌘B)")
        #expect(PanelToggleText.pullRequestPanelAccessibilityLabel(isOpen: false) == "Show the pull request panel")
    }

    @Test func sidebarWordsFollowItsState() {
        #expect(PanelToggleText.sidebarMenuTitle(isVisible: true) == "Hide Sidebar")
        #expect(PanelToggleText.sidebarMenuTitle(isVisible: false) == "Show Sidebar")
        #expect(PanelToggleText.sidebarTooltip(isVisible: true) == "Hide sidebar (⌃⌘S)")
        #expect(PanelToggleText.sidebarTooltip(isVisible: false) == "Show sidebar (⌃⌘S)")
    }

    /// A double-click counts only when its first click came to the same view, within the interval.
    @Test func aDoubleClickNeedsItsFirstClickHere() {
        let interval = 0.5
        #expect(TitleBarDoubleClick.isDoubleClick(clickCount: 2, timestamp: 10.3, previousMouseDown: 10, interval: interval))
        // The first click went to a toggle that then moved away.
        #expect(!TitleBarDoubleClick.isDoubleClick(clickCount: 2, timestamp: 10.3, previousMouseDown: nil, interval: interval))
        // The first click here was too long ago: a later click elsewhere started the system's count.
        #expect(!TitleBarDoubleClick.isDoubleClick(clickCount: 2, timestamp: 12, previousMouseDown: 10, interval: interval))
        #expect(!TitleBarDoubleClick.isDoubleClick(clickCount: 1, timestamp: 10.3, previousMouseDown: 10, interval: interval))
        #expect(!TitleBarDoubleClick.isDoubleClick(clickCount: 2, timestamp: 9, previousMouseDown: 10, interval: interval))
        #expect(TitleBarDoubleClick.isDoubleClick(clickCount: 3, timestamp: 10.5, previousMouseDown: 10, interval: interval))
    }

    /// The user's "Double-click a window's title bar to" setting.
    @Test func doubleClickActionFollowsTheSystemSetting() {
        #expect(TitleBarDoubleClick.action(setting: "Maximize") == .zoom)
        #expect(TitleBarDoubleClick.action(setting: nil) == .zoom)
        #expect(TitleBarDoubleClick.action(setting: "Minimize") == .minimize)
        #expect(TitleBarDoubleClick.action(setting: "None") == TitleBarDoubleClick.Action.none)
        #expect(TitleBarDoubleClick.action(setting: "Something new") == .zoom)
    }
}
