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

    /// Asks about unsaved edits first (EDIT-02), then stops every agent, terminal and script before quitting, so none
    /// keeps running (and using energy) after Rocky. With the window, the question is Rocky's own mini-modal on it, and
    /// its answer replies later (DLG-05); with no window, the native alert. Save All that cannot save a file (it changed
    /// on disk, or the write failed) cancels the quit and shows that file's tab, with its banner.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        // A second Quit while the prompt waits (Rocky ▸ Quit, clicked): the prompt already holds this quit.
        if DialogPresenter.shared.isAskingToQuit { return .terminateCancel }
        let unsaved = model.unsavedEditors()
        if unsaved.isEmpty {
            quit(saving: [])
            return .terminateLater
        }
        let asked = DialogPresenter.shared.askToQuit(unsaved: unsaved) { [weak self] answer in
            self?.answerQuitPrompt(answer, unsaved: unsaved)
        }
        if asked { return .terminateLater }
        let answer = Self.askAboutUnsavedEdits(unsaved)
        if answer == .cancel { return .terminateCancel }
        quit(saving: answer == .saveAll ? unsaved : [])
        return .terminateLater
    }

    /// DLG-05: the mini-modal's answer, while AppKit waits for the reply.
    private func answerQuitPrompt(_ answer: UnsavedEditsAnswer, unsaved: [UnsavedEditor]) {
        switch answer {
        case .saveAll: quit(saving: unsaved)
        case .dontSave: quit(saving: [])
        case .cancel: NSApp.reply(toApplicationShouldTerminate: false)
        }
    }

    /// Saves `saving` first, then stops every process and lets Rocky quit. A file that cannot be saved cancels the quit
    /// and shows its tab.
    private func quit(saving: [UnsavedEditor]) {
        guard let model else {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        Task {
            if !saving.isEmpty, let first = await model.saveEditors(saving).first {
                model.showUnsavedEditor(first)
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            await model.stopAllProcesses()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// The unsaved edits prompt with no window (⌘W closes the window, not Rocky), the one native dialog left (DLG-05):
    /// an app-modal alert in the words of a tab's (`UnsavedChangesPrompt`), the files, then Save All, Cancel and Don't
    /// Save.
    private static func askAboutUnsavedEdits(_ unsaved: [UnsavedEditor]) -> UnsavedEditsAnswer {
        let alert = NSAlert()
        alert.messageText = UnsavedChangesPrompt.title(for: unsaved, quitting: true)
        alert.informativeText = UnsavedChangesPrompt.message(for: unsaved)
        // AppKit's order: the first button is the default (Return), then Cancel (Esc), then Don't Save (⌘D).
        alert.addButton(withTitle: UnsavedChangesPrompt.saveTitle(count: unsaved.count))
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        dontSave.hasDestructiveAction = true
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .saveAll
        case .alertThirdButtonReturn: return .dontSave
        default: return .cancel
        }
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
            CommandGroup(after: .newItem) {
                OpenInDefaultAppCommand(model: model)
            }
            // After the group that holds Close (⌘W), which stays.
            CommandGroup(after: .saveItem) {
                SaveCommand(model: model)
            }
            // ⌘P is Go to File, Quick Open (FIL-08) as in Zed and VS Code, in place of Page Setup and Print…, which Rocky
            // has no use for (user decision, 2026-09-24); the editor's Go to Line sits under it (KBD-02).
            CommandGroup(replacing: .printItem) {
                GoToFileCommand(model: model)
                GoToLineCommand()
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
                    ChangesTabCommand(model: model)
                    TerminalToggleCommand(model: model)
                }
                Section {
                    ChangedFileCommands(model: model)
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

/// File ▸ Open in <app> (⌘O, OPN-02): the selected workspace's worktree in the default app, as the Open split button's
/// left part does (TB-03). The title follows the default ("Open in Zed", "Open in Finder"), looked up when the menu bar
/// reads it and again when it runs. ⌘O was free: the app is a `WindowGroup` with no documents, so File has no Open….
/// A failure shows in the window's toast, through the model. Off without a selected workspace.
private struct OpenInDefaultAppCommand: View {
    let model: AppModel
    @AppStorage(DefaultOpenApp.storageKey) private var storedDefault: String?

    var body: some View {
        Button("Open in \(InstalledApp.defaultApp(stored: storedDefault).app.displayName)") {
            guard let workspace = model.selectedWorkspace else { return }
            let worktree = URL(fileURLWithPath: workspace.path, isDirectory: true)
            InstalledApp.defaultApp(stored: storedDefault).openFolder(worktree) { [model] in model.onToast?($0) }
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(model.selectedWorkspace == nil)
    }
}

/// File ▸ Save (⌘S, EDIT-02, KBD-02): the file on screen, while it has unsaved edits, as its header's Save. The one owner
/// of ⌘S in the window: off while the settings or a repository's settings are open, whose own Save has it.
private struct SaveCommand: View {
    let model: AppModel

    private var canSave: Bool {
        guard let workspaceId = model.selectedWorkspaceId, !SettingsPresenter.isAnySettingsPanelOpen else { return false }
        return model.canSaveVisibleEditor(workspaceId: workspaceId)
    }

    var body: some View {
        Button("Save") {
            guard let workspaceId = model.selectedWorkspaceId else { return }
            Task { await model.saveVisibleEditor(workspaceId: workspaceId) }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!canSave)
    }
}

/// File ▸ Go to File… (⌘P, FIL-08, KBD-02): Quick Open over the window for the selected workspace, or, while it shows,
/// closed. It leaves the right panel as it is, open or closed. A menu command, so it works from the message box, the
/// editor and the terminal too; off without a selected workspace, and while the settings or a repository's settings
/// are open, as Save is.
private struct GoToFileCommand: View {
    let model: AppModel

    var body: some View {
        Button("Go to File…") {
            guard let workspaceId = model.selectedWorkspaceId else { return }
            QuickOpenPresenter.shared.toggle(for: workspaceId, model: model)
        }
        .keyboardShortcut("p", modifiers: .command)
        .disabled(model.selectedWorkspace == nil || SettingsPresenter.isAnySettingsPanelOpen)
    }
}

/// File ▸ Go to Line… (⌘L, EDIT-01, KBD-02): the go-to-line field of the editor on screen, which publishes it
/// (`EditorGoToLineAction`), so it works while the editor does not have the keyboard (a preview tab); off while no
/// editor shows. With the keyboard, the editor's text view takes ⌘L before the menu, to the same effect.
private struct GoToLineCommand: View {
    @FocusedValue(\.editorGoToLine) private var goToLine

    var body: some View {
        Button("Go to Line…") { goToLine?.run() }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(goToLine == nil)
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

/// View ▸ Show Changes / Hide Changes (⌘⇧C, CHG-01): the right panel on its Changes tab, or, pressed while that tab
/// shows, the panel hidden. It writes the open state the panel toggle and ⌥⌘B share. A menu command, so it works from
/// the message box and the terminal too; off without a selected workspace.
private struct ChangesTabCommand: View {
    let model: AppModel
    @AppStorage(RightPanelStorage.openKey) private var isOpen = true

    private var showsChanges: Bool {
        guard let workspaceId = model.selectedWorkspaceId else { return false }
        return isOpen && model.rightPanelTab(workspaceId: workspaceId) == .changes
    }

    var body: some View {
        Button(showsChanges ? "Hide Changes" : "Show Changes") {
            guard let workspaceId = model.selectedWorkspaceId else { return }
            if showsChanges {
                isOpen = false
            } else {
                model.rightPanelTabs[workspaceId] = .changes
                isOpen = true
            }
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(model.selectedWorkspace == nil)
    }
}

/// View ▸ Toggle Terminal (⌃`, KBD-04), VS Code's pair to ⌘J's Toggle Panel (user request, 2026-09-25): from a terminal
/// of the panel it folds the panel and gives the keyboard back to the selected tab; from anywhere else it unfolds the
/// panel on a terminal and gives it the keyboard. The panel's selection and fold are the workspace view's, so the
/// command only asks, through the model (M2.8 Decision 11). A menu command, so it reaches a terminal with the keyboard
/// before the shell does, as ⌘J does; the shell no longer gets ⌃` (NUL), which ⌃Space still sends. Off without a
/// selected workspace.
private struct TerminalToggleCommand: View {
    let model: AppModel

    var body: some View {
        Button("Toggle Terminal") {
            guard let workspaceId = model.selectedWorkspaceId else { return }
            model.requestTerminalToggle(workspaceId: workspaceId)
        }
        .keyboardShortcut("`", modifiers: .control)
        .disabled(model.selectedWorkspace == nil)
    }
}

/// View ▸ Next Changed File / Previous Changed File (⌥⌘↓ / ⌥⌘↑, CHG-03): the file after or before the one on screen
/// in the Changes tab's order. Off while the selected workspace has no changes read.
private struct ChangedFileCommands: View {
    let model: AppModel

    private var hasChanges: Bool {
        guard let workspaceId = model.selectedWorkspaceId else { return false }
        return model.changes[workspaceId]?.files.isEmpty == false
    }

    var body: some View {
        Button("Next Changed File") { step(1) }
            .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            .disabled(!hasChanges)
        Button("Previous Changed File") { step(-1) }
            .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            .disabled(!hasChanges)
    }

    private func step(_ step: Int) {
        guard let workspaceId = model.selectedWorkspaceId else { return }
        model.showAdjacentChangedFile(workspaceId: workspaceId, step: step)
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
