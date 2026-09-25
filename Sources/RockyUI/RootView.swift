import AppKit
import RockyKit
import SwiftUI

/// The window: sidebar panel, hairline divider, workspace. A custom layout instead of NavigationSplitView, whose
/// column divider is drawn black and cannot be restyled. The title bar is transparent (an empty compact toolbar,
/// WIN-01), so the sidebar is one full-height panel with the window buttons on its top row and the workspace's top
/// bar sits at the very top.
public struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage(SidebarStorage.visibleKey) private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 260.0
    /// Rocky's own menus, drawn over the whole window (`MenuHost`).
    @State private var menus = MenuPresenter()
    /// The window's toast (`ToastHost`), fed by the model's `onToast` and by views.
    @State private var toasts = ToastPresenter()
    /// The sidebar list has keyboard focus; the workspace reads it as `sidebarHasKeyboardFocus` (KBD-01).
    @State private var sidebarHasKeyboardFocus = false
    /// Whether any of the window can be seen (`WindowVisibilityReader`): the views' animations and timers and PR-07's
    /// polling run while it can. `appearsActive` says whether the user is looking at Rocky.
    @State private var windowIsVisible = true
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// WIN-02: 16 margin, 52 window buttons, 8 gap, 28 Show sidebar, 12 gap.
    private static let hiddenSidebarInset: CGFloat = 116

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                VStack(spacing: 0) {
                    SidebarTopBar(onToggleSidebar: toggleSidebar)
                    SidebarView(model: model, hasKeyboardFocus: $sidebarHasKeyboardFocus, onAddRepository: addRepository)
                }
                .frame(width: sidebarWidth)
                .background(Color.rockySidebar)
                SidebarDivider(width: $sidebarWidth)
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.rockyBackground)
                // Over the workspace column, not the window: centered under the content it is about.
                .overlay(alignment: .bottom) {
                    if let busy = model.busyMessage {
                        ProgressLabel(text: busy)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .padding()
                    }
                }
                // With the sidebar hidden, the window buttons and Show sidebar sit over the workspace's top bar.
                .environment(\.titleBarLeadingInset, sidebarVisible ? 0 : Self.hiddenSidebarInset)
                .environment(\.sidebarHasKeyboardFocus, sidebarHasKeyboardFocus)
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .topLeading) {
            if !sidebarVisible {
                Button("Show sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                    .buttonStyle(RockyIconButtonStyle())
                    .font(.rocky(14))
                    .help(PanelToggleText.sidebarTooltip(isVisible: false))
                    // WIN-02: 8 points after the window buttons, centered on the title bar's height.
                    .padding(.leading, SidebarTopBar.windowButtonsEnd + 8)
                    .frame(height: SidebarTopBar.height)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        // Showing and hiding the sidebar animate like the right panel (user decision, 2026-09-23), whichever way it
        // is toggled: its buttons, ⌘K, or View ▸ Show Sidebar, which writes the stored value from outside this view,
        // where a `withAnimation` around the toggle did not animate at all. Instant with Reduce Motion.
        .animation(reduceMotion ? nil : Theme.Motion.state, value: sidebarVisible)
        // ⌘K with the sidebar hidden shows it; the sidebar then focuses its search field (KBD-01).
        .onChange(of: model.isSearchFocusRequested) { _, requested in
            if requested, !sidebarVisible { toggleSidebar() }
        }
        // FIL-08: Quick Open lists the selected workspace's files, and a settings panel takes the window's keys, so
        // another workspace (⌘1…⌘9) or a settings panel (⌘,) closes it.
        .onChange(of: model.selectedWorkspaceId) { QuickOpenPresenter.shared.dismiss() }
        .onChange(of: SettingsPresenter.isAnySettingsPanelOpen) { _, isOpen in
            if isOpen { QuickOpenPresenter.shared.dismiss() }
        }
        .preferredColorScheme(.dark)
        // The default font of every view that sets none (sidebar rows, buttons, fields), at Rocky's zoom.
        .font(.rocky(13))
        .background { WindowVisibilityReader { windowIsVisible = $0 } }
        // Menus over the settings modals too: the sound, run mode, Claude instance and GitHub account pickers are
        // menus.
        .overlay { SettingsModal(model: model) }
        .overlay { RepoSettingsModal(model: model) }
        // FIL-08: over the workspace and the settings, under the menus.
        .overlay { QuickOpenHost(model: model) }
        // DLG-02: the mini-modals over everything but the menus and the toast, Settings included.
        .overlay { DialogHost() }
        .overlay { MenuHost(presenter: menus) }
        .overlay { ToastHost(presenter: toasts) }
        .onChange(of: appearsActive, initial: true) { _, active in model.isWindowActive = active }
        .onChange(of: windowIsVisible, initial: true) { _, visible in model.isWindowVisible = visible }
        .onChange(of: model.attentionCount, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        .onAppear {
            model.onAlert = { _ in AlertSound.play() }
            model.onToast = { [toasts = toasts] text in toasts.show(text) }
        }
        .environment(menus)
        .environment(toasts)
        .environment(\.windowIsVisible, windowIsVisible)
        // DLG-01: an error, titled "Something went wrong" where the native alert said "Rocky" (the designer's call,
        // 2026-09-25). Its message can be selected, and Return and Esc both press OK.
        .rockyDialog(item: Binding(get: { model.errorMessage }, set: { model.errorMessage = $0 })) { message in
            Dialog(title: "Something went wrong", message: message, isMessageSelectable: true, buttons: [.primary("OK")])
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let workspace = model.selectedWorkspace {
            WorkspaceDetailView(model: model, workspace: workspace)
                .id(workspace.id)
        } else {
            WelcomeView()
        }
    }

    private func toggleSidebar() {
        sidebarVisible.toggle()
    }

    private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addRepo(at: url) }
    }
}
