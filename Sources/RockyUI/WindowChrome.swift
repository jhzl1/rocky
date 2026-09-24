import AppKit
import RockyKit
import SwiftUI

// The window's title bar is transparent and as tall as `WindowMetrics.titleBarHeight` (an empty compact toolbar,
// WIN-01): the sidebar's top row holds the window buttons, and the workspace's top bar row sits beside it. These
// helpers stand in for what a visible title bar did.

extension EnvironmentValues {
    /// Room the workspace header leaves on its left for the window buttons while the sidebar is hidden.
    @Entry var titleBarLeadingInset: CGFloat = 0
}

/// Sizes the window chrome shares (WIN-01).
enum WindowMetrics {
    /// H: the height of the title bar, the sidebar's top row (SB-01) and the workspace's top bar row (TB-01), with
    /// the traffic lights centered in it. AppKit's, so it does not follow the zoom. 38 is what a compact toolbar is
    /// expected to give; it is measured in the running app and corrected here if it differs.
    static let titleBarHeight: CGFloat = 38
    /// The sidebar's footer (SB-06) and the terminal panel's bar (TERM-02), at 100 % zoom: one height, so their top
    /// lines meet across the window (user feedback, 2026-09-23; the spec had 44 and 32).
    static let bottomBarHeight: CGFloat = 36

    /// The title bar row at the current zoom: H, or a 28-point icon button's height once the zoom makes that taller
    /// (from 140 %), so the row grows with its buttons instead of clipping them (TOK-02). The sidebar's top row, the
    /// workspace's top bar and the right panel's header share it, so the tab rows under the last two line up (LAY-01).
    @MainActor static var titleRowHeight: CGFloat {
        max(titleBarHeight, Zoom.shared(28))
    }
}

/// Where the sidebar's shown state is kept: `RootView`'s buttons and View ▸ Show Sidebar (⌃⌘S) share it.
public enum SidebarStorage {
    public static let visibleKey = "sidebarVisible"
}

extension View {
    /// Lets the user drag the window from this view's empty background, as they would from a title bar, and
    /// double-click it as a title bar (the user's "Double-click a window's title bar to" setting).
    func windowDragBackground() -> some View {
        background { WindowDragArea() }
    }
}

/// `windowDragBackground`'s view. SwiftUI's `WindowDragGesture` zoomed the window on any second click: a click on a
/// panel toggle folds its panel, the toggle moves away, and the second click of a double-click landed here (user
/// report, 2026-09-23). This view counts a double-click only when it also got the first click
/// (`TitleBarDoubleClick.isDoubleClick`); any other click drags the window.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        /// When this view last got a mouse-down, in `NSEvent.timestamp`'s clock; nil after a double-click, so a third
        /// click starts over.
        private var lastMouseDown: TimeInterval?

        /// The view moves the window itself (`performDrag`), so AppKit must not.
        override var mouseDownCanMoveWindow: Bool { false }

        /// A title bar drags even while the window is in the background.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let isDoubleClick = TitleBarDoubleClick.isDoubleClick(
                clickCount: event.clickCount,
                timestamp: event.timestamp,
                previousMouseDown: lastMouseDown,
                interval: NSEvent.doubleClickInterval
            )
            guard isDoubleClick else {
                lastMouseDown = event.timestamp
                window?.performDrag(with: event)
                return
            }
            lastMouseDown = nil
            let setting = UserDefaults.standard.string(forKey: TitleBarDoubleClick.settingKey)
            switch TitleBarDoubleClick.action(setting: setting) {
            case .zoom: window?.performZoom(nil)
            case .minimize: window?.performMiniaturize(nil)
            case .none: break
            }
        }
    }
}

/// The sidebar's top row (SB-01): room for the window buttons, then Hide sidebar, nothing else. Workspaces come from
/// each repository's "+" and ⌘N, and Add repository sits in the footer (SB-06): a "+" here read as "new workspace".
struct SidebarTopBar: View {
    let onToggleSidebar: () -> Void

    /// Where the window buttons end: 16 from the window's edge, 52 wide (WIN-01). AppKit places them; if it puts
    /// them elsewhere once the compact toolbar is measured, this is the number to correct.
    static let windowButtonsEnd: CGFloat = 16 + 52

    /// H, the title bar's height, which does not follow the zoom (WIN-01). From 140 % zoom a 28-point icon button
    /// outgrows it, and the row grows with the button instead of letting it spill into the search field (TOK-02).
    static var height: CGFloat {
        WindowMetrics.titleRowHeight
    }

    var body: some View {
        HStack(spacing: 0) {
            Button("Hide sidebar", systemImage: "sidebar.left", action: onToggleSidebar)
                .buttonStyle(RockyIconButtonStyle())
                .font(.rocky(14))
                .help(PanelToggleText.sidebarTooltip(isVisible: true))
            Spacer(minLength: 0)
        }
        // SB-01: 6 points between the window buttons and Hide sidebar.
        // 8 after the lights, as with the sidebar hidden (WIN-02), so the toggle does not move 2 points between the
        // two states (SB-01 says 6).
        .padding(.leading, Self.windowButtonsEnd + 8)
        .frame(height: Self.height)
        .windowDragBackground()
    }
}
