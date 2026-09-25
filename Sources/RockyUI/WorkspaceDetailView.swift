import AppKit
import RockyKit
import SwiftTerm
import SwiftUI

struct WorkspaceDetailView: View {
    let model: AppModel
    let workspace: Workspace
    @State private var panelSelection: UUID?
    /// KBD-04: the panel terminal ⌃` gives the keyboard to, until it has it.
    @State private var terminalFocus: TerminalFocusRequest?
    /// The terminal panel folded to its bar; its terminals and scripts keep running.
    @AppStorage(TerminalPanelStorage.collapsedKey) private var panelCollapsed = false
    /// The terminal panel's height while open, bar included (TERM-01), the same for every workspace.
    @AppStorage("terminalPanelHeight") private var panelHeight = 220.0
    /// PNL-01: the right panel, open by default, and its width; both global and kept across launches.
    @AppStorage(RightPanelStorage.openKey) private var rightPanelOpen = true
    @AppStorage(RightPanelStorage.widthKey) private var rightPanelWidth = RightPanelStorage.defaultWidth
    @Environment(\.titleBarLeadingInset) private var titleBarLeadingInset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// TERM-01: the open panel is never shorter than this, bar included.
    private static let minPanelHeight = 140.0
    /// TERM-01: what the chat keeps however tall the panel is dragged.
    private static let minChatHeight = 200.0
    /// What the conversation keeps however wide the right panel is dragged, until the panel is at its 280.
    private static let minConversationWidth = 360.0

    /// Read from the model, not kept here: a chat the model stops (for example after a settings change) must go away.
    private var chat: ChatSessionModel? {
        model.existingChat(workspaceId: workspace.id)
    }

    /// Open: something ran in the panel and it is not folded. Otherwise the panel is only its bar (TERM-04, TERM-05).
    private var isPanelOpen: Bool {
        let hasSessions = !(model.existingProcesses(for: workspace.id)?.all.isEmpty ?? true)
        return hasSessions && !panelCollapsed
    }

    var body: some View {
        // LAY-01: the conversation column (top bar, tabs, conversation, terminal panel), then the right panel at full
        // height, whose header shares the title bar row with the top bar (PNL-01). The divider and the panel come and
        // go together (PNL-02, ⌥⌘B), and the conversation takes the width.
        GeometryReader { proxy in
            let range = rightPanelRange(available: proxy.size.width)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    topBar
                    ConversationTabs(model: model, workspace: workspace)
                    split
                }
                if rightPanelOpen {
                    ColumnDivider(width: $rightPanelWidth, range: range)
                        // Its handle reaches 4 points into the panel, which would otherwise be drawn over it.
                        .zIndex(1)
                    RightPanel(model: model, workspace: workspace)
                        .frame(width: CGFloat(min(max(rightPanelWidth, range.lowerBound), range.upperBound)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(reduceMotion ? nil : Theme.Motion.state, value: rightPanelOpen)
        }
        .task {
            await model.showConversations(workspace: workspace)
        }
        // KBD-04: View ▸ Toggle Terminal (⌃`) reaches the panel's selection and fold through the model.
        .onChange(of: model.terminalToggleRequests[workspace.id]) { _, serial in
            if let serial { toggleTerminal(serial: serial) }
        }
        // A file badge anywhere in the workspace opens its file in a tab here: its diff tab when it is a changed
        // worktree file (DIFF-05), else a file tab.
        .environment(\.openFile, OpenFileAction { [model, workspace] path in
            model.openBadgeFile(workspaceId: workspace.id, path: path)
        })
        // A line chip (CMT-06) opens its file's diff tab at its lines, resolved like a badge's path.
        .environment(\.openLineRange, OpenLineRangeAction { [model, workspace] range in
            model.openLineRange(workspaceId: workspace.id, attachment: range)
        })
    }

    /// One row as tall as the title bar (TB-01), over the conversation column only (LAY-01): repository / branch, then
    /// Open, then the panel toggle (PNL-02) once the right panel is closed; while it is open, the toggle is the panel
    /// header's, at the same spot. Run moved to the terminal panel's bar (LAY-01). It replaces the two-line header: the
    /// path moved into the Open menu, the workspace name into the sidebar row's tooltip. The ports are not shown
    /// anywhere (user decision, 2026-09-23: they read as noise); scripts and terminals still get $PORT.
    private var topBar: some View {
        HStack(spacing: 10) {
            if let repo = model.repo(id: workspace.repoId) {
                Text(repo.name)
                    .font(.rocky(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                // 4 here plus the branch button's own padding of 6 is the row's gap of 10 up to the branch glyph.
                HStack(spacing: 4) {
                    Text(verbatim: "/")
                        .font(.rocky(13))
                        .foregroundStyle(Theme.separatorGlyph)
                        .accessibilityHidden(true)
                    BranchCopyButton(branch: workspace.branch)
                }
                .layoutPriority(1)
            } else {
                BranchCopyButton(branch: workspace.branch)
            }
            Spacer(minLength: 0)
            openMenu
            if !rightPanelOpen {
                RightPanelToggle()
            }
        }
        // With the sidebar hidden, the inset already holds the 16-point margin before the window buttons (WIN-02).
        .padding(.leading, titleBarLeadingInset > 0 ? titleBarLeadingInset : 16)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity)
        // The panel header's height too, so the two tab rows under them line up at every zoom.
        .frame(height: WindowMetrics.titleRowHeight)
        // The row is where the title bar was: drag the window from its empty space.
        .windowDragBackground()
    }

    /// TB-03's split button: the default app (OPN-02) on the left, the Open menu behind the chevron.
    private var openMenu: some View {
        OpenSplitButton(model: model, workspaceId: workspace.id, worktreePath: workspace.path, panelSelection: $panelSelection)
    }

    /// Chat above, terminals and script output below (M2 layout decision), in one layout whatever the panel's state
    /// (TERM-01). `VSplitView` drew its own divider and was swapped for a `VStack` while the panel was folded or
    /// empty, which lost the height and could not animate. The chat takes what the panel leaves.
    private var split: some View {
        GeometryReader { proxy in
            let range = panelHeightRange(available: proxy.size.height)
            let openHeight = CGFloat(min(max(panelHeight, range.lowerBound), range.upperBound))
            VStack(spacing: 0) {
                chatArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PanelDivider(height: $panelHeight, range: range, isResizable: isPanelOpen)
                    // Its handle reaches 4 points into the panel bar, which would otherwise be drawn over it.
                    .zIndex(1)
                WorkspacePanelView(
                    model: model,
                    workspace: workspace,
                    selection: $panelSelection,
                    isCollapsed: $panelCollapsed,
                    openHeight: openHeight,
                    focusRequest: $terminalFocus
                )
                .frame(height: isPanelOpen ? openHeight : WorkspacePanelView.barHeight, alignment: .top)
                .clipped()
            }
            // TERM-05: folding and unfolding animate the height, instantly with Reduce Motion. Switching workspaces
            // never animates it: each workspace gets a new view (`.id(workspace.id)` in RootView), and a drag changes
            // the height without changing this value.
            .animation(reduceMotion ? nil : Theme.Motion.state, value: isPanelOpen)
        }
    }

    /// KBD-04, VS Code's Toggle Terminal (M2.8 Decision 11). A terminal of the panel with the keyboard: the panel folds
    /// and the keyboard goes back to the selected tab, the conversation's message box or the file or diff tab's editor.
    /// Otherwise the panel unfolds on a terminal, which takes the keyboard: the selected tab if it is a terminal, else
    /// the first terminal tab, else a new "Terminal N" (TERM-07), which may first wait for the repository account's
    /// token (ENV-01). Setup and Run are scripts: never picked. The fold is TERM-05's, which ⌘J toggles too.
    private func toggleTerminal(serial: Int) {
        let window = NSApp.keyWindow
        if let window, Self.panelTerminalHasKeyboard(in: window) {
            terminalFocus = nil
            panelCollapsed = true
            // After the fold has taken the terminal out of the window.
            DispatchQueue.main.async { giveKeyboardBack(in: window) }
            return
        }
        let processes = model.existingProcesses(for: workspace.id)
        let terminals = processes?.terminals ?? []
        let shown = WorkspacePanelView.shownSession(among: processes?.all ?? [], selection: panelSelection)
        if let chosen = terminals.first(where: { $0.id == shown?.id }) ?? terminals.first {
            focusTerminal(chosen.id, serial: serial)
            return
        }
        let workspaceId = workspace.id
        Task {
            guard let opened = await model.openTerminal(workspaceId: workspaceId) else { return }
            focusTerminal(opened.id, serial: serial)
        }
    }

    private func focusTerminal(_ sessionId: UUID, serial: Int) {
        panelSelection = sessionId
        panelCollapsed = false
        terminalFocus = TerminalFocusRequest(sessionId: sessionId, serial: serial)
    }

    /// A terminal of the bottom panel is the first responder. The embedded terminal of Claude Code's terminal commands
    /// (CMD-08) is the conversation's, not the panel's.
    private static func panelTerminalHasKeyboard(in window: NSWindow) -> Bool {
        guard let terminal = window.firstResponder as? TerminalView else { return false }
        return terminal.identifier != .embeddedTerminal
    }

    /// The selected tab takes the keyboard again: the conversation's message box, else the editor a file or diff tab
    /// shows. A diff tab without its editor (Diff mode) leaves it with the window.
    private func giveKeyboardBack(in window: NSWindow) {
        let showsConversation = model.selectedFiles[workspace.id] == nil && model.selectedDiffTabs[workspace.id] == nil
        if showsConversation, let conversationId = model.selectedConversationIds[workspace.id],
           let composer = ConversationComposers.controller(conversationId: conversationId) {
            composer.focus()
        } else if !CodeEditor.focusShownEditor(in: window) {
            window.makeFirstResponder(nil)
        }
    }

    /// PNL-01's widths for the right panel in a row `available` points wide: 280 to 480, less when the conversation
    /// would get under `minConversationWidth`, never under 280. Like the terminal panel's heights, they do not zoom.
    private func rightPanelRange(available: CGFloat) -> ClosedRange<Double> {
        let widths = RightPanelStorage.widthRange
        let upper = min(widths.upperBound, Double(available) - 1 - Self.minConversationWidth)
        return widths.lowerBound...max(widths.lowerBound, upper)
    }

    /// The open panel's heights in a split `available` points tall: at least `minPanelHeight`, and at most what
    /// leaves the chat `minChatHeight` above the divider's line. The panel's minimum wins in a very short window.
    private func panelHeightRange(available: CGFloat) -> ClosedRange<Double> {
        let upper = Double(available) - Self.minChatHeight - 1
        return Self.minPanelHeight...max(Self.minPanelHeight, upper)
    }

    /// The selected conversation, or the file or diff tab on top of it. The conversation stays underneath those tabs, so
    /// its draft and scroll position are there when you come back.
    private var chatArea: some View {
        let file = model.selectedFiles[workspace.id]
        let diff = model.selectedDiffTabs[workspace.id]
        let showsChat = file == nil && diff == nil
        return ZStack {
            if let chat, let conversationId = model.selectedConversationIds[workspace.id] {
                ChatView(
                    chat: chat,
                    model: model,
                    workspaceId: workspace.id,
                    conversationId: conversationId,
                    isActive: showsChat,
                    commands: model.commands(for: chat),
                    terminal: EmbeddedTerminalHost(model: model, conversationId: conversationId),
                    lineComment: { [model, workspace] range, comment, files in
                        await model.lineComment(for: range, comment: comment, files: files, workspaceId: workspace.id)
                    }
                )
                    // A new view per conversation, so switching tabs does not carry a draft or a scroll position over.
                    .id(ObjectIdentifier(chat))
                    .opacity(showsChat ? 1 : 0)
                    .allowsHitTesting(showsChat)
            } else if showsChat {
                ProgressLabel(text: "Opening the conversation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let diff {
                // A new view per file, so one tab's expanded runs and scroll position never carry over to another. A
                // preview from the tree leaves the keyboard in the tree, so its arrows keep browsing (FIL-05).
                DiffTabView(model: model, workspace: workspace, path: diff, takesFocus: model.previewTabs[workspace.id] != diff)
                    .id(diff)
                    .background(Color.rockyBackground)
            } else if let file {
                FileTabView(model: model, workspaceId: workspace.id, path: file)
                    .id(file)
                    .background(Color.rockyBackground)
            }
        }
    }
}

/// The workspace's tabs, like Conductor's (TAB-01): its conversations (agent logo and title), then the files opened
/// from a badge (type icon and name), then its diff tabs (DIFF-01: status letter and name); the selected one
/// underlined, and a + for a new conversation with the default agent (CNV-01, CNV-02). A 34-point row with the hairline
/// at its bottom, under the selected tab's underline. A file or diff tab whose editor has unsaved edits shows DIFF-01's
/// dot and asks before it closes (EDIT-02), in the words Rocky uses when it quits with unsaved edits
/// (`UnsavedChangesPrompt`).
struct ConversationTabs: View {
    let model: AppModel
    let workspace: Workspace
    /// The tab whose close asks "Save changes to …?".
    @State private var closing: ClosingTab?
    /// The conversations the strip has drawn, from the moment the workspace's tabs are loaded: one that joins later
    /// (a "+", the workspace's first) enters with M2.5's entrance (CNV-01). nil until then, so the tabs already there
    /// when the workspace is shown never play it.
    @State private var drawnConversationIds: Set<String>?

    private struct ClosingTab: Equatable {
        enum Kind {
            case file, diff
        }

        let kind: Kind
        /// The tab's own path: absolute for a file tab, worktree-relative for a diff tab.
        let path: String
        /// Its file, which `editor.path` keys in `AppModel.editors`.
        let editor: UnsavedEditor

        var editorPath: String { editor.path }
    }

    private func editorPath(ofDiff path: String) -> String {
        AppModel.editorPath(worktree: workspace.path, relativePath: path)
    }

    /// EDIT-02's close: at once without unsaved edits, else after Save / Don't Save / Cancel.
    private func close(_ kind: ClosingTab.Kind, path: String) {
        let key = kind == .diff ? editorPath(ofDiff: path) : path
        guard let editor = model.unsavedEditors(workspaceId: workspace.id).first(where: { $0.path == key }) else {
            finishClosing(kind, path: path)
            return
        }
        closing = ClosingTab(kind: kind, path: path, editor: editor)
    }

    private func finishClosing(_ kind: ClosingTab.Kind, path: String) {
        switch kind {
        case .file: model.closeFile(workspaceId: workspace.id, path: path)
        case .diff: model.closeDiff(workspaceId: workspace.id, path: path)
        }
    }

    /// Save, then close; a save the file's change on disk stopped shows the tab instead, with its conflict banner.
    private func saveAndClose(_ tab: ClosingTab) {
        let model = self.model
        let workspaceId = workspace.id
        Task {
            if await model.saveEditor(workspaceId: workspaceId, path: tab.editorPath) {
                finishClosing(tab.kind, path: tab.path)
            } else if tab.kind == .diff {
                model.showDiff(workspaceId: workspaceId, path: tab.path)
            } else {
                model.showFile(workspaceId: workspaceId, path: tab.path)
            }
        }
    }

    var body: some View {
        let open = model.conversations[workspace.id] ?? []
        let selectedId = model.selectedConversationIds[workspace.id]
        let files = model.openFiles[workspace.id] ?? []
        let selectedFile = model.selectedFiles[workspace.id]
        let diffs = model.diffTabs[workspace.id] ?? []
        let selectedDiff = model.selectedDiffTabs[workspace.id]
        let preview = model.previewTabs[workspace.id]
        let changes = model.changes[workspace.id]
        TabStripLayout {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(open) { record in
                        let agent = AgentKind(rawValue: record.agent) ?? .claude
                        WorkspaceTab(
                            title: record.title ?? "New conversation",
                            isSelected: record.id == selectedId && selectedFile == nil && selectedDiff == nil,
                            onSelect: { Task { await model.showConversation(workspace: workspace, conversationId: record.id) } },
                            onClose: { Task { await model.closeConversation(workspace: workspace, conversationId: record.id) } }
                        ) {
                            // A running conversation shows the spinner in place of its logo (MOT-01, 12 points).
                            if model.chat(conversationId: record.id)?.state == .running {
                                CircularProgress(size: 12)
                            } else {
                                AgentIcon(agent: agent, size: 12)
                            }
                        }
                        .help(record.title ?? "New conversation")
                        .modifier(Entrance(isNew: drawnConversationIds.map { !$0.contains(record.id) } ?? false) {
                            drawnConversationIds?.insert(record.id)
                        })
                    }
                    ForEach(files, id: \.self) { path in
                        let kind = FileKind(path: path)
                        WorkspaceTab(
                            title: URL(fileURLWithPath: path).lastPathComponent,
                            isSelected: path == selectedFile,
                            isDirty: model.isEditorDirty(workspaceId: workspace.id, path: path),
                            onSelect: { model.showFile(workspaceId: workspace.id, path: path) },
                            onClose: { close(.file, path: path) }
                        ) {
                            // FIL-09: a file's Material icon at 12 points; a folder keeps the blue folder.
                            if kind == .folder {
                                Image(systemName: kind.symbol)
                                    .font(.rocky(11))
                                    .foregroundStyle(kind.color)
                            } else {
                                FileIcon(path: path, size: 12)
                            }
                        }
                        .help(path)
                    }
                    ForEach(diffs, id: \.self) { path in
                        let isPreview = path == preview
                        WorkspaceTab(
                            title: (path as NSString).lastPathComponent,
                            isSelected: path == selectedDiff,
                            isDirty: model.isEditorDirty(workspaceId: workspace.id, path: editorPath(ofDiff: path)),
                            isPreview: isPreview,
                            onSelect: { model.showDiff(workspaceId: workspace.id, path: path) },
                            // FIL-05: a double-click on the preview tab keeps it.
                            onDoubleClick: isPreview ? { model.keepPreview(workspaceId: workspace.id) } : nil,
                            onClose: { close(.diff, path: path) }
                        ) {
                            DiffTabIcon(status: changes?.file(at: path)?.status, path: path)
                        }
                        .help(path)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            // CNV-01: one click makes the conversation, with the default agent (CNV-02), adds its tab at the end and
            // selects it; its new `ChatView` takes the keyboard for the message box. No right-click menu: the model
            // menu's rail picks the agent, switching an empty conversation in place (AGM-01, AGM-02; the bridge went,
            // user decision, 2026-09-25).
            Button("New conversation", systemImage: "plus") {
                Task { await model.newConversation(workspace: workspace) }
            }
            .buttonStyle(RockyIconButtonStyle())
            .help("New conversation")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Zoom.shared(34))
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .onChange(of: model.conversations[workspace.id]?.map(\.id), initial: true) { _, ids in
            if drawnConversationIds == nil, let ids { drawnConversationIds = Set(ids) }
        }
        // DLG-01: Don't Save alone at the left (⌘D), then Cancel and Save, the default.
        .rockyDialog(item: $closing) { tab in
            Dialog(
                title: UnsavedChangesPrompt.title(for: [tab.editor], quitting: false),
                message: UnsavedChangesPrompt.message(for: [tab.editor]),
                buttons: [
                    .dontSave { finishClosing(tab.kind, path: tab.path) },
                    .cancel(),
                    .primary(UnsavedChangesPrompt.saveTitle(count: 1)) { saveAndClose(tab) },
                ]
            )
        }
    }
}

/// One tab of the workspace (TAB-01): an icon, the title (truncated past 240 points), and an × that always takes its
/// space, so hovering never shifts the tabs. `textSecondary` at rest, `textPrimary` on hover and while selected; the
/// selected tab has a 2-point underline on the row's hairline. A tab with unsaved edits shows a 7-point dot in the ×'s
/// place until it is hovered (DIFF-01). A preview tab's title is in italics (FIL-05). One tap handler reads the click
/// count (`NSEvent.clickCount`): a count-2 gesture beside it would hold every single click for the double-click
/// interval.
struct WorkspaceTab<Icon: View>: View {
    let title: String
    let isSelected: Bool
    var isDirty = false
    var isPreview = false
    let onSelect: () -> Void
    /// The second click of a double-click, after `onSelect` ran for both.
    var onDoubleClick: (() -> Void)?
    let onClose: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false

    private var isLit: Bool {
        hovering || isSelected
    }

    /// The × shows while the tab is lit, except that the dirty dot keeps its place until the pointer is on the tab.
    private var showsClose: Bool {
        isDirty ? hovering : isLit
    }

    var body: some View {
        HStack(spacing: 4) {
            TabWidthCap(maxWidth: Zoom.shared(240)) {
                HStack(spacing: 7) {
                    icon()
                    Text(title)
                        .italic(isPreview)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 10)
            }
            Button("Close", systemImage: "xmark", action: onClose)
                .font(.rocky(10))
                .buttonStyle(RockyIconButtonStyle(size: 16))
                .opacity(showsClose ? 1 : 0)
                .allowsHitTesting(showsClose)
                .help("Close the tab")
                .overlay {
                    if isDirty && !hovering {
                        Circle()
                            .fill(Theme.textSecondary)
                            .frame(width: Zoom.shared(7), height: Zoom.shared(7))
                            .accessibilityLabel("Unsaved edits")
                    }
                }
        }
        .font(.rocky(12.5))
        .foregroundStyle(isLit ? Theme.textPrimary : Theme.textSecondary)
        // 6 after the ×: its 16-point box already leaves 3 around the glyph, as in the design's mock.
        .padding(.trailing, 6)
        .frame(height: Zoom.shared(34))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Theme.textPrimary : Color.clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
            if let onDoubleClick, (NSApp.currentEvent?.clickCount ?? 1) >= 2 { onDoubleClick() }
        }
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .clickable()
    }
}

/// OPN-01's opener: the worktree folder from the Open menu, or one file (`FIL-06`'s file too large for Rocky), opened
/// by the app itself, so Rocky spawns nothing and no CLI needs to be on the PATH. A failure shows in the toast.
@MainActor
enum ExternalEditorOpener {
    static func open(_ url: URL, in editor: ExternalEditor, app: URL, toasts: ToastPresenter?) {
        open(url, in: editor, app: app) { toasts?.show($0) }
    }

    /// The same, with the failure's text handed to `toast`: ⌘O's menu command has no `ToastPresenter` and shows it
    /// through `AppModel.onToast`.
    static func open(_ url: URL, in editor: ExternalEditor, app: URL, toast: @escaping @MainActor @Sendable (String) -> Void) {
        let name = editor.displayName
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { @Sendable _, error in
            guard let error else { return }
            let message = "Couldn’t open in \(name): \(error.localizedDescription)"
            Task { @MainActor in toast(message) }
        }
    }
}

/// Finder or an installed editor (`OPN-01`, `OPN-02`), with its bundle on this Mac, for its icon and for opening a
/// worktree or a file in it. Looked up each time it is needed (the split button drawing, the menu opening, a click, ⌘O,
/// the path chip), never cached and never polled, so an editor installed or removed while Rocky runs shows up at the
/// next use.
@MainActor
public struct InstalledApp {
    public let app: OpenApp
    /// The app's bundle; nil only for Finder, if Launch Services cannot find it.
    let bundleURL: URL?

    /// The Open menu's apps: Finder, then the installed editors in `OPN-01`'s order.
    static func all() -> [InstalledApp] {
        let finder = InstalledApp(
            app: .finder,
            bundleURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: OpenApp.finderBundleIdentifier)
        )
        let editors = ExternalEditor.installed { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        return [finder] + editors.map { InstalledApp(app: .editor($0.editor), bundleURL: $0.app) }
    }

    /// The default app (`OPN-02`) for the stored bundle identifier, among `apps` or the apps installed now.
    public static func defaultApp(stored: String?) -> InstalledApp {
        defaultApp(stored: stored, among: all())
    }

    static func defaultApp(stored: String?, among apps: [InstalledApp]) -> InstalledApp {
        let editors = apps.compactMap { entry -> ExternalEditor? in
            if case .editor(let editor) = entry.app { return editor }
            return nil
        }
        let resolved = DefaultOpenApp.resolve(stored: stored, installed: editors)
        return apps.first { $0.app == resolved } ?? InstalledApp(app: .finder, bundleURL: nil)
    }

    /// The app's own icon, as the Open menu draws it (`OPN-01`).
    var icon: NSImage? {
        bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Opens the worktree folder: a Finder window on it, or the editor's window on it as a project (`OPN-01`).
    public func openFolder(_ url: URL, toast: @escaping @MainActor @Sendable (String) -> Void) {
        switch app {
        case .finder:
            _ = NSWorkspace.shared.open(url)
        case .editor(let editor):
            guard let bundleURL else { return }
            ExternalEditorOpener.open(url, in: editor, app: bundleURL, toast: toast)
        }
    }

    /// Opens one file as it is on disk (`DIFF-01`'s path chip): an editor opens it, and Finder reveals it.
    func openFile(_ url: URL, toast: @escaping @MainActor @Sendable (String) -> Void) {
        switch app {
        case .finder:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .editor(let editor):
            guard let bundleURL else { return }
            ExternalEditorOpener.open(url, in: editor, app: bundleURL, toast: toast)
        }
    }
}

/// The tabs' scroll view, then the "+" right after the last tab. When the tabs do not fit, they scroll and the "+"
/// stays at the row's end. Two subviews, in that order. The scroll view gets exactly its tabs' width, capped by the
/// room the "+" leaves, which a stack cannot give a view that takes any width it is offered.
private struct TabStripLayout: Layout {
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        // Unlimited along its axis, a scroll view reports its content's width.
        let tabs = subviews[0].sizeThatFits(ProposedViewSize(width: nil, height: proposal.height))
        let plus = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? (tabs.width + spacing + plus.width)
        return CGSize(width: width, height: max(tabs.height, plus.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let plus = subviews[1].sizeThatFits(.unspecified)
        let idealTabs = subviews[0].sizeThatFits(ProposedViewSize(width: nil, height: bounds.height)).width
        let tabsWidth = max(0, min(idealTabs, bounds.width - spacing - plus.width))
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: tabsWidth, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + tabsWidth + spacing, y: bounds.midY),
            anchor: .leading,
            proposal: .unspecified
        )
    }
}

/// Caps its content's width even under an unlimited proposal, which is what a horizontal scroll view gives its
/// content, so a long title truncates (TAB-01). `frame(maxWidth:)` there only clamps the size it reports, and the
/// text would still draw at full width over the next tab.
private struct TabWidthCap: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(proposal.width ?? .infinity, maxWidth)
        return content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// TB-03: the Open split button. Its left part shows the default app's icon (OPN-02) and opens the worktree in it, as
/// ⌘O does; the chevron opens the menu: Finder and the installed editors (OPN-01), each as its app's icon and name, the
/// default one with "⌘O", then New Terminal and Copy Path. No path header and no "Open in", as in Conductor (user
/// request, 2026-09-24: "solo mostrar el logo del app y el nombre"). Picking Finder or an editor opens the worktree
/// there and makes it the default; New Terminal and Copy Path leave the default as it is. The default is looked up
/// when the button draws and again on each click, and the menu's apps when it opens: never at rest.
private struct OpenSplitButton: View {
    let model: AppModel
    let workspaceId: String
    let worktreePath: String
    @Binding var panelSelection: UUID?
    @AppStorage(DefaultOpenApp.storageKey) private var storedDefault: String?
    @AppStorage(TerminalPanelStorage.collapsedKey) private var panelCollapsed = false
    @Environment(ToastPresenter.self) private var toasts: ToastPresenter?

    private var worktree: URL {
        URL(fileURLWithPath: worktreePath, isDirectory: true)
    }

    private var toast: @MainActor @Sendable (String) -> Void {
        { [toasts] in toasts?.show($0) }
    }

    var body: some View {
        let current = InstalledApp.defaultApp(stored: storedDefault)
        HStack(spacing: 0) {
            Button {
                InstalledApp.defaultApp(stored: storedDefault).openFolder(worktree, toast: toast)
            } label: {
                OpenAppIcon(app: current)
            }
            .buttonStyle(OpenSplitMainStyle())
            .help("Open in \(current.app.displayName) (⌘O)")
            .accessibilityLabel("Open in \(current.app.displayName)")
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1, height: Zoom.shared(16))
            MenuButton(id: "open-\(workspaceId)", placement: .belowTrailing, width: 200) { isOpen in
                OpenSplitChevron(isOpen: isOpen)
            } content: {
                menu
            }
            .help("Open in Finder, an editor or Terminal")
        }
        .frame(height: Zoom.shared(28))
        .background(Theme.fillControl)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
        .fixedSize()
    }

    @ViewBuilder
    private var menu: some View {
        let apps = InstalledApp.all()
        let current = InstalledApp.defaultApp(stored: storedDefault, among: apps)
        ForEach(Array(apps.enumerated()), id: \.offset) { _, entry in
            MenuItem(
                title: entry.app.displayName,
                icon: entry.icon.map(MenuIcon.image) ?? .symbol("folder"),
                shortcut: entry.app == current.app ? "⌘O" : nil
            ) {
                storedDefault = entry.app.bundleIdentifier
                entry.openFolder(worktree, toast: toast)
            }
        }
        MenuDivider()
        MenuItem(title: "New Terminal", icon: .symbol("terminal")) {
            // TERM-07: a new "Terminal N", selected, with the panel unfolded. The first one may wait for the
            // repository account's token (ENV-01).
            Task {
                panelSelection = await model.openTerminal(workspaceId: workspaceId)?.id
                panelCollapsed = false
            }
        }
        MenuItem(title: "Copy Path", icon: .symbol("doc.on.doc")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(worktreePath, forType: .string)
        }
    }
}

/// An app's own icon at 16 points, as the Open menu draws it; a folder symbol if Finder's bundle was not found.
private struct OpenAppIcon: View {
    let app: InstalledApp

    var body: some View {
        if let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: Zoom.shared(16), height: Zoom.shared(16))
        } else {
            Image(systemName: "folder")
                .font(.rocky(13))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// TB-03's left part: 30 wide, `fillHover` on hover and `fillPressed` pressed, under the split button's clip.
private struct OpenSplitMainStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OpenSplitMain(configuration: configuration)
    }

    private struct OpenSplitMain: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: Zoom.shared(30), height: Zoom.shared(28))
                .background(configuration.isPressed ? Theme.fillPressed : hovering ? Theme.fillHover : .clear)
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
                .clickable()
        }
    }
}

/// TB-03's right part, the label of its `MenuButton`: 22 wide, `chevron.down` 9 semibold in `textSecondary`,
/// `fillHover` on hover, and `fillSelected` while the menu is open.
private struct OpenSplitChevron: View {
    let isOpen: Bool
    @State private var hovering = false

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.rocky(9, weight: .semibold))
            .foregroundStyle(hovering || isOpen ? Theme.textPrimary : Theme.textSecondary)
            .frame(width: Zoom.shared(22), height: Zoom.shared(28))
            .background(isOpen ? Theme.fillSelected : hovering ? Theme.fillHover : .clear)
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
            .accessibilityLabel("Open in…")
    }
}

/// The branch in the top bar (TB-02): its glyph and name; a click copies the name and the label reads "Copied" in
/// the accent for 1.2 seconds.
private struct BranchCopyButton: View {
    let branch: String
    @State private var copied = false
    @State private var endCopied: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.rocky(13))
                    .foregroundStyle(Theme.textTertiary)
                Text(copied ? "Copied" : branch)
                    .font(.rocky(12, design: .monospaced))
                    .foregroundStyle(copied ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(BranchCopyButtonStyle())
        .help("Copy the branch name")
        .accessibilityLabel("Branch \(branch)")
        .accessibilityHint("Copies the branch name")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(branch, forType: .string)
        copied = true
        endCopied?.cancel()
        endCopied = Task {
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// TB-02: 24 points high, padding 6, radius 5; no fill at rest, `fillIconHover` on hover, `fillPressed` pressed.
private struct BranchCopyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BranchCopyButtonBody(configuration: configuration)
    }

    private struct BranchCopyButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .frame(height: Zoom.shared(24))
                .background(
                    configuration.isPressed ? Theme.fillPressed : hovering ? Theme.fillIconHover : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
                .clickable()
        }
    }
}
