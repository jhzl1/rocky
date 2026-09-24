import AppKit
import RockyKit
import RockyUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed under `swift run` (no bundle); harmless inside Rocky.app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Zoom In is ⌘+, which a US keyboard types with Shift; ⌘= zooms in too, as in browsers.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "=" else { return event }
            MainActor.assumeIsolated { Zoom.shared.zoomIn() }
            return nil
        }
    }

    /// Stops every agent, terminal and script before quitting, so none keeps running (and using energy) after Rocky.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.stopAllProcesses()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct RockyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = RockyApp.makeModel()

    init() {
        // Overlay scroll bars in every scroll view, whatever System Settings or the mouse ask for: only the knob,
        // shown while scrolling, never the gray track. Set in Rocky's own defaults before any view exists.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    var body: some Scene {
        WindowGroup("Rocky") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .background { CompactTitleBar() }
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                }
        }
        // The first launch, or no saved frame: a roomy window (the screen clamps it). 900 × 560 stays the minimum,
        // what the sidebar, a readable conversation and the right panel need side by side.
        .defaultSize(width: 1440, height: 900)
        // No title bar: the sidebar's top row holds the window buttons and the workspace header sits at the top,
        // like Conductor. "Rocky" stays the window's name in the Window menu. The empty compact toolbar
        // (`CompactTitleBar`) makes the transparent title bar H tall, with the window buttons centered in it (WIN-01).
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            // ⌘N makes a workspace. Without this it would open a second window: the app is a WindowGroup.
            CommandGroup(replacing: .newItem) {
                NewWorkspaceCommand(model: model)
            }
            // The title bar's toolbar only sizes the title bar (WIN-01): nothing in it to show, hide or customize.
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(after: .toolbar) {
                ZoomCommands()
            }
            CommandGroup(after: .sidebar) {
                WorkspaceCommands(model: model)
                Section {
                    SidebarCommand()
                    PullRequestPanelCommand(model: model)
                }
            }
            // Rocky ▸ Settings… (⌘,) opens the settings panel over the window, not a window of its own.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsPresenter.shared.show() }
                    .keyboardShortcut(",", modifiers: .command)
                // The login shell runs once per launch (spec Section 1); this re-reads it after you edit ~/.zshrc.
                Button("Refresh Shell Environment") {
                    Task { await model.refreshEnvironment() }
                }
            }
        }
    }

    @MainActor
    private static func makeModel() -> AppModel {
        do {
            let paths = try RockyPaths.standard()
            return AppModel(store: try RockyStore(path: paths.database.path), paths: paths)
        } catch {
            fatalError("Rocky could not open its database: \(error)")
        }
    }
}

/// WIN-01: an empty toolbar in the compact style, so AppKit makes the title bar H tall (`WindowMetrics.titleBarHeight`)
/// and centers the traffic lights in it; the transparent title bar hides its background. AppKit's toolbar and not a
/// SwiftUI `.toolbar`: SwiftUI builds a toolbar only around an item, and an item would sit over the top bar row, take
/// its clicks and draw a platter on macOS 26 and later. The sidebar's top row and the workspace's top bar stay
/// SwiftUI views under the transparent title bar.
private struct CompactTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowHook {
        WindowHook()
    }

    func updateNSView(_ view: WindowHook, context: Context) {
        view.configureWindow()
    }

    final class WindowHook: NSView {
        private static let toolbarIdentifier = "RockyTitleBar"
        /// The window's frame is saved under this fixed name. SwiftUI's own name spells the content's type, which holds
        /// `(unknown context at $address)` for this private view, an address that changes with every build: no build
        /// found the last one's frame, so Rocky always opened at its minimum size (user report, 2026-09-24).
        private static let frameAutosaveName = "RockyMainWindow"

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        /// Never takes a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Idempotent: runs again on every SwiftUI update and changes only what differs.
        func configureWindow() {
            guard let window else { return }
            if window.frameAutosaveName != Self.frameAutosaveName {
                // Back to the size and place the user left it at, when there is one; else `defaultSize` stands.
                window.setFrameUsingName(Self.frameAutosaveName)
                window.setFrameAutosaveName(Self.frameAutosaveName)
            }
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
                toolbar.allowsUserCustomization = false
                window.toolbar = toolbar
            }
            if window.toolbarStyle != .unifiedCompact { window.toolbarStyle = .unifiedCompact }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        }
    }
}

/// File ▸ New Workspace (⌘N, KBD-01): in the selected workspace's repository, else the first; off without any.
private struct NewWorkspaceCommand: View {
    let model: AppModel

    var body: some View {
        Button("New Workspace") {
            guard let repoId = model.newWorkspaceRepoId else { return }
            Task { await model.createWorkspace(repoId: repoId) }
        }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(model.newWorkspaceRepoId == nil)
    }
}

/// View ▸ Search Workspaces (⌘K) and the workspaces the sidebar lists, ⌘1…⌘9 for the first nine (KBD-01). Menu
/// commands, so they work wherever the focus is. ⌘J, ⌘U, ⇧Tab, ⌘, and the zoom keep their shortcuts.
private struct WorkspaceCommands: View {
    let model: AppModel

    var body: some View {
        Section {
            Button("Search Workspaces") { model.isSearchFocusRequested = true }
                .keyboardShortcut("k", modifiers: .command)
        }
        Section {
            ForEach(Array(model.visibleWorkspaceIds.prefix(9).enumerated()), id: \.element) { index, workspaceId in
                Button(title(of: workspaceId)) { model.selectVisibleWorkspace(number: index + 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }

    private func title(of workspaceId: String) -> String {
        guard let workspace = model.workspace(id: workspaceId) else { return "Workspace" }
        return model.title(for: workspace).text
    }
}

/// View ▸ Show Sidebar / Hide Sidebar (⌃⌘S, macOS's standard shortcut): Rocky's sidebar is its own view, not a
/// `NavigationSplitView`, so SwiftUI adds no such command (user report, 2026-09-23). It writes the state the sidebar's
/// buttons toggle, and `RootView` animates the change. A menu command, so it works from the message box and the
/// terminal too.
private struct SidebarCommand: View {
    @AppStorage(SidebarStorage.visibleKey) private var isVisible = true

    var body: some View {
        Button(PanelToggleText.sidebarMenuTitle(isVisible: isVisible)) { isVisible.toggle() }
            .keyboardShortcut("s", modifiers: [.control, .command])
    }
}

/// View ▸ Show / Hide Pull Request Panel (⌥⌘B, KBD-03): the right panel's open state, which the panel toggle shares
/// (PNL-02). ⌘⇧G was Edit ▸ Find ▸ Find Previous, which won (user report, 2026-09-23). A menu command, so it works from
/// the message box too; it has no Esc of its own, so the conversation's Esc still stops the agent. Off without a
/// selected workspace, where there is no panel.
private struct PullRequestPanelCommand: View {
    let model: AppModel
    @AppStorage(RightPanelStorage.openKey) private var isOpen = true

    var body: some View {
        Button(PanelToggleText.pullRequestPanelMenuTitle(isOpen: isOpen)) { isOpen.toggle() }
            .keyboardShortcut("b", modifiers: [.option, .command])
            .disabled(model.selectedWorkspace == nil)
    }
}

/// View ▸ Zoom In, Zoom Out and Actual Size, with the zoom in use.
private struct ZoomCommands: View {
    private var zoom: Zoom { Zoom.shared }

    var body: some View {
        Section {
            Button("Zoom In") { zoom.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!zoom.canZoomIn)
            Button("Zoom Out") { zoom.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!zoom.canZoomOut)
            Button("Actual Size") { zoom.reset() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoom.isActualSize)
            Button("Zoom: \(Int((zoom.scale * 100).rounded()))%") {}
                .disabled(true)
        }
    }
}
