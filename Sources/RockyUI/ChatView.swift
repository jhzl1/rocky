import AppKit
import RockyKit
import SwiftTerm
import SwiftUI
import Textual

struct ChatView: View {
    let chat: ChatSessionModel
    /// For the conversation's model menu (`AGM-01`…`AGM-07`), which reaches its chat through the model, and for a
    /// draft a pick moved here (`AppModel.takePendingDraft`).
    let model: AppModel
    let workspaceId: String
    let conversationId: String
    /// False while a file tab covers the conversation: the view stays, with its draft, but takes no shortcut.
    var isActive = true
    /// The slash commands the message box offers, `AppModel.commands(for:)`: the conversation's own list, or the last
    /// one of its repository and agent until its own arrives (`confirmed` false).
    var commands: [SlashCommand] = []
    var commandsConfirmed = false
    /// The conversation's embedded terminal, for Claude Code's terminal commands (CMD-08).
    let terminal: EmbeddedTerminalHost
    /// A message sent with a line chip, as its comment again, its block read from the lines as they are now
    /// (`AppModel.lineComment(for:comment:files:workspaceId:)`, CMT-05 Resend).
    let lineComment: @MainActor (LineRangeAttachment, String, [URL]) async -> LineComment
    @State private var composerText = ComposerController()
    /// CMD-08's strip over the message box. In this view only, as in Conductor: nothing is stored.
    @State private var terminalCommand: TerminalCommandState?
    /// Rows that have already been seen (MOT-02): the whole history when the conversation opens, so it shows at once,
    /// then each new row as it enters. Only rows whose key is not here fade in.
    @State private var settledKeys: Set<String>
    @State private var keyMonitor: Any?
    /// `isActive` for the key monitor: its closure keeps the view as it was when it appeared.
    @State private var liveActive = LiveFlag()
    /// Bumped once after the conversation is laid out (`selectionRefresh`).
    @State private var selectionRefresh = 0
    @Environment(\.openFile) private var openFile
    @Environment(MenuPresenter.self) private var menus: MenuPresenter?
    /// The sidebar list has the keyboard: a workspace chosen with ↑/↓ must not take it into its message box, or the
    /// next ↑ would browse the message history instead of the list (KBD-01).
    @Environment(\.sidebarHasKeyboardFocus) private var sidebarHasKeyboardFocus
    /// The last thing in the scroll view: scrolling to it reaches the very bottom, even while a reply's markdown
    /// is still being laid out.
    private static let bottomId = "bottom"
    /// Like Conductor, long replies read in a centered column instead of across the whole window.
    private static let readingWidth: CGFloat = 820
    /// The conversation's side margin, and the inner padding of the message box and the question card.
    static let columnPadding: CGFloat = 24
    static let boxPadding: CGFloat = 14

    init(
        chat: ChatSessionModel,
        model: AppModel,
        workspaceId: String,
        conversationId: String,
        isActive: Bool = true,
        commands: (commands: [SlashCommand], confirmed: Bool) = ([], false),
        terminal: EmbeddedTerminalHost,
        lineComment: @escaping @MainActor (LineRangeAttachment, String, [URL]) async -> LineComment
    ) {
        self.chat = chat
        self.model = model
        self.workspaceId = workspaceId
        self.conversationId = conversationId
        self.isActive = isActive
        self.commands = commands.commands
        self.commandsConfirmed = commands.confirmed
        self.terminal = terminal
        self.lineComment = lineComment
        // Before the first frame: a conversation that opens (or a tab or workspace switched to) never animates.
        _settledKeys = State(initialValue: Set(ChatLayout.rows(chat.items).map(\.entranceKey)))
    }

    var body: some View {
        let rows = ChatLayout.rows(chat.items)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: a lazy stack guesses the height of the rows it has not drawn, so the scroll bar
                    // grew and shrank while scrolling as each reply got measured. Rows that did not change skip
                    // their body (`equatable()`), so a long conversation stays cheap while a reply streams.
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(rows) { row in
                            Group {
                                switch row {
                                case .item(let item): ChatItemRow(item: item, isLive: isLive(item), command: sentCommand(item)).equatable()
                                case .tools(let tools): ToolGroupRow(tools: tools, isLive: tools.last.map(isLive) ?? false)
                                case .turnFooter(let summary): TurnFooterRow(agent: chat.agent, summary: summary)
                                }
                            }
                            .modifier(Entrance(isNew: !settledKeys.contains(row.entranceKey)) {
                                settledKeys.insert(row.entranceKey)
                            })
                        }
                        if chat.state == .running {
                            WorkingRow(startedAt: chat.turnStartedAt)
                                .modifier(Entrance(isNew: true) {})
                        }
                        // Where they will be sent: after the turn in progress, as one group with one caption (user
                        // decisions, 2026-09-23).
                        if !chat.queue.isEmpty {
                            VStack(alignment: .trailing, spacing: 8) {
                                ForEach(chat.queue) { message in
                                    QueuedMessageRow(
                                        message: message,
                                        isAgentWorking: chat.state == .running,
                                        canEdit: !composerText.hasContent && !composerText.hasLineChip,
                                        onSendNow: { Task { await chat.sendQueuedNow(id: message.id) } },
                                        onEdit: { edit(message) },
                                        onDelete: { chat.removeQueued(id: message.id) }
                                    )
                                    .modifier(Entrance(isNew: true) {})
                                }
                                QueueCaption(count: chat.queue.count, isHeld: chat.isQueueHeld)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomId)
                    }
                    .font(.rocky(14))
                    // Textual's selection overlays take their hit areas when SwiftUI updates them. A conversation
                    // opened while the window was already key kept stale ones: nothing could be selected until the
                    // window lost and regained focus, which updates every view (user report, 2026-09-24). One
                    // environment change once the rows are laid out does the same.
                    .environment(\.selectionRefresh, selectionRefresh)
                    .padding(.horizontal, Self.columnPadding)
                    .padding(.vertical, 20)
                    .frame(maxWidth: Zoom.shared(Self.readingWidth))
                    .frame(maxWidth: .infinity)
                }
                // The message box floats over the end of the conversation, which scrolls under it, as in Conductor.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomArea
                }
                // Stay pinned to the bottom while the content grows.
                .defaultScrollAnchor(.bottom)
                .onChange(of: chat.items.count) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                .onChange(of: chat.items.last?.text) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                .onChange(of: chat.state) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                .onChange(of: chat.queue.count) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            }
        }
        .onAppear {
            chat.isVisible = true
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                selectionRefresh += 1
            }
            liveActive.value = isActive
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKey($0) }
            ConversationComposers.register(composerText, conversationId: conversationId)
            // AGM-02, AGM-03: the draft a pick in the model menu moved here, taken once (M2.8 Decision 1). After this
            // update, once the message box's text view exists.
            let draft = model.takePendingDraft(conversationId: conversationId)
            let focuses = !sidebarHasKeyboardFocus
            if draft != nil || focuses {
                DispatchQueue.main.async {
                    if let draft { composerText.load(text: draft.text, files: draft.files, lineRange: draft.lineRange) }
                    // A mini-modal on screen, such as the permission request this view shows as it appears, keeps the
                    // keyboard: the message box behind it takes none (DLG-03).
                    if focuses, !DialogPresenter.shared.isShowing { composerText.focus() }
                }
            }
            restoreTerminalCommand()
        }
        // CMD-08: the process ending by itself finishes the command; the terminal stays open until Done or ×.
        .onChange(of: terminal.session?.state) { _, state in
            if let state, !state.isRunning, terminalCommand?.stage == .running { terminalCommand?.stage = .done }
        }
        .onChange(of: isActive) {
            liveActive.value = isActive
            if isActive { composerText.focus() } else { composerText.resignFocus() }
        }
        .onChange(of: commands, initial: true) { composerText.setCommands(commands, confirmed: commandsConfirmed) }
        .onChange(of: commandsConfirmed) { composerText.setCommands(commands, confirmed: commandsConfirmed) }
        .onDisappear {
            chat.isVisible = false
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            ConversationComposers.unregister(composerText, conversationId: conversationId)
        }
        // DLG-06: the agent's permission request, while this conversation is on screen, as the sheet was. Its answer
        // goes to the agent; Cancel, Esc and a click outside answer no option.
        .rockyDialog(item: Binding(
            get: { chat.pendingPermission },
            set: { if $0 == nil { chat.answerPermission(optionId: nil) } }
        )) { [chat] request in
            PermissionDialog.make(request: request, agent: chat.agent) { chat.answerPermission(optionId: $0) }
        }
    }

    /// The agent's questions, then the embedded terminal (CMD-08) and the message box, floating above the
    /// conversation; the conversation fades out under them.
    private var bottomArea: some View {
        VStack(spacing: 10) {
            if let question = chat.pendingQuestion {
                QuestionCard(agent: chat.agent, request: question) { chat.answerQuestion($0) }
                    .id(question.questions.map(\.id).joined() + question.message)
            }
            VStack(spacing: 8) {
                if let session = terminal.session, let command = terminalCommand?.command {
                    EmbeddedTerminalView(session: session, command: command, onDone: finishTerminalCommand, onClose: stopTerminalCommand)
                        .id(session.id)
                        // It enters like a chat row (MOT-02).
                        .modifier(Entrance(isNew: true) {})
                }
                footer
            }
        }
        // The boxes reach 14 points (their inner padding) past the conversation's column on each side, so the text
        // typed in them lines up with the conversation's text.
        .padding(.horizontal, Self.columnPadding - Self.boxPadding)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: Zoom.shared(Self.readingWidth))
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                stops: [.init(color: Color.rockyBackground.opacity(0), location: 0), .init(color: Color.rockyBackground.opacity(0.9), location: 0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var footer: some View {
        switch chat.state {
        case .stopped(let reason):
            HStack {
                Text(reason).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Restart") { Task { await chat.start() } }
                    .buttonStyle(RockyFilledButtonStyle())
            }
            .padding(Self.boxPadding)
            .background(Theme.composer, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.composerBorder))
        case .idle, .starting, .ready, .running:
            // The agent may still be starting in the background; a message sent meanwhile waits for it.
            composer
        }
    }

    /// The command a user message runs, for its chip (CMD-06): only a name the conversation's list has now.
    private func sentCommand(_ item: ChatItem) -> String? {
        guard item.kind == .user else { return nil }
        return SlashCommand.invoked(by: item.text, among: commands)?.name
    }

    /// A tool call of the turn in progress: while it is pending it is still running.
    private func isLive(_ item: ChatItem) -> Bool {
        guard chat.state == .running, let start = chat.turnStartedAt else { return false }
        return item.createdAt >= start
    }

    /// While the agent works, sending queues the message instead.
    private var canSend: Bool {
        composerText.hasContent
    }

    /// A roomy message box laid out like Conductor's: the text with its files inside it as badges, then model and
    /// effort on the left, the + menu and send on the right. Return sends, Shift-Return starts a new line, Shift-Tab
    /// switches plan mode; pasting or dropping images and files puts them in the text.
    private var composer: some View {
        VStack(spacing: 0) {
            // CMD-08: the strip joins the top of the box, over a hairline, inside the same fill and border.
            if let terminalCommand {
                TerminalCommandStrip(
                    state: terminalCommand,
                    canRefresh: chat.state != .running,
                    onOpen: openTerminalCommand,
                    onRefresh: refreshAgent,
                    onDismiss: dismissTerminalCommand
                )
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            composerBody
        }
        // Opaque, with a shadow, since it floats over the conversation. The border is drawn inside the shape: a
        // centered stroke falls half a point outside and smears across two pixels on a 1x screen.
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.composerBorder))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        // The slash command popup: as wide as the box, its bottom 8 points above the box's top edge (CMD-01).
        .overlay(alignment: .top) {
            SlashCommandPopup(popup: composerText.popup, agent: chat.agent) { composerText.chooseRow($0) }
                .alignmentGuide(.top) { $0[.bottom] + 8 }
        }
        // Files dropped on the box outside its text go in at the insertion point.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            composerText.insert(files: files)
            return !files.isEmpty
        }
    }

    private var composerBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ComposerEditor(
                controller: composerText,
                zoom: Zoom.shared.scale,
                // CMT-05 History: a line comment comes back with its chip.
                history: MessageHistory.entries(from: chat.items),
                onSubmit: send,
                onBacktab: { Task { await chat.setPlanMode(!chat.isPlanMode) } },
                openFile: openFile
            )
            .frame(height: composerText.height)
            .overlay(alignment: .topLeading) {
                if composerText.isEmpty {
                    Text("Ask \(chat.agent.displayName) to make changes…")
                        .font(.rocky(14))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                ModelMenuButton(model: model, workspaceId: workspaceId, conversationId: conversationId, chat: chat)
                if chat.isPlanMode {
                    PlanModeChip { Task { await chat.setPlanMode(false) } }
                }
                Spacer()
                plusMenu
                if chat.state == .running {
                    ComposerButton(systemImage: "stop.fill", isEnabled: true) { Task { await chat.cancel() } }
                        .help("Stop the agent's turn (Esc)")
                }
                if chat.state != .running || composerText.hasContent {
                    ComposerButton(systemImage: "arrow.up", isEnabled: canSend, action: send)
                        .help(chat.state == .running ? "Queue (Return): sent when the agent's turn ends" : "Send (Return)")
                }
            }
        }
        .padding(Self.boxPadding)
    }

    /// The + next to Send, like Conductor's: attach files, and plan mode when the agent has one.
    private var plusMenu: some View {
        MenuButton(id: "composer-\(ObjectIdentifier(chat))", placement: .aboveTrailing, width: 250) { isOpen in
            Image(systemName: "plus")
                .font(.rocky(15))
                .frame(width: Zoom.shared(28), height: Zoom.shared(28))
                .background(Color.white.opacity(isOpen ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        } content: {
            MenuItem(title: "Add attachment", icon: .symbol("paperclip"), shortcut: "⌘U", action: chooseAttachments)
            // CMD-07: where to find the agent's commands.
            MenuItem(title: "Commands", icon: .symbol("slash.circle"), shortcut: "/") { composerText.startCommand() }
            if chat.canUsePlanMode {
                MenuItem(title: "Plan mode", icon: .symbol("map"), shortcut: "⇧Tab", isChecked: chat.isPlanMode) {
                    Task { await chat.setPlanMode(!chat.isPlanMode) }
                }
            }
        }
        .help("Attach files, run one of the agent's commands or switch plan mode")
    }

    private func send() {
        guard canSend else { return }
        // AGM-07: sending closes the conversation's model menu, which a pick leaves open (M2.8 Decision 6).
        let modelMenu = ModelMenuButton.menuId(conversationId: conversationId)
        if menus?.isOpen(modelMenu) == true { menus?.dismiss() }
        // The box empties, files included, also for a terminal command.
        let message = composerText.takeMessage()
        // CMT-05 Resend: with its chip, the message is a line comment again. Its text is the comment, never a command.
        if let range = message.lineRange {
            resend(range, comment: message.text, files: message.files)
            return
        }
        // CMD-08: one of Claude Code's terminal commands never reaches the agent, idle, starting or working, and is
        // never queued; the strip offers the embedded terminal instead. A pick in the popup comes through here too.
        if let command = chat.terminalCommand(in: message.text) {
            offerTerminal(for: command)
            return
        }
        // While the agent works, the message waits for its turn to end (like Conductor's queue).
        if chat.state == .running {
            chat.enqueue(message.text, attachments: message.files)
        } else {
            Task { await chat.send(message.text, attachments: message.files) }
        }
    }

    /// CMT-05 Resend: the comment goes as the comment box's do, its block built now from the chip's lines; while the
    /// agent works it waits in the queue with its chip (`ChatSessionModel.send(_:)`).
    private func resend(_ range: LineRangeAttachment, comment: String, files: [URL]) {
        let chat = self.chat
        let build = lineComment
        Task {
            let built = await build(range, comment, files)
            await chat.send(built)
        }
    }

    // MARK: Terminal commands (CMD-08)

    /// The strip, pending, for `command`. A terminal another command left open closes: one per conversation.
    private func offerTerminal(for command: TerminalOnlyCommand) {
        terminalCommand = TerminalCommandState(command: command, stage: .pending)
        if terminal.session != nil { Task { await terminal.close() } }
    }

    /// Open terminal: the command runs in the embedded terminal. Back to pending when it could not start (Rocky's
    /// Claude Code is not installed; `AppModel.errorMessage` says so).
    private func openTerminalCommand() {
        guard let state = terminalCommand, state.stage == .pending else { return }
        terminalCommand?.stage = .running
        Task {
            let session = await terminal.open(state.command)
            if session == nil, terminalCommand == TerminalCommandState(command: state.command, stage: .running) {
                terminalCommand?.stage = .pending
            }
        }
    }

    /// Done: stops the command if it still runs, closes the terminal, and the strip offers Refresh.
    private func finishTerminalCommand() {
        terminalCommand?.stage = .done
        closeTerminal()
    }

    /// × on the terminal: stops and closes it, and the strip offers it again.
    private func stopTerminalCommand() {
        terminalCommand?.stage = .pending
        closeTerminal()
    }

    /// × on the strip: it goes, with the terminal if one is open.
    private func dismissTerminalCommand() {
        terminalCommand = nil
        closeTerminal()
    }

    /// Refresh: the agent restarts and resumes its session, so it rereads the configuration the command changed and
    /// announces a new command list. There is no "Configuration refreshed." toast yet (no toast system before M2.7).
    private func refreshAgent() {
        guard chat.state != .running else { return }
        terminalCommand = nil
        Task { await chat.restart() }
    }

    private func closeTerminal() {
        if terminal.session != nil { Task { await terminal.close() } }
        composerText.focus()
    }

    /// A terminal still open when the view comes back (another tab or workspace was shown meanwhile) gets its strip
    /// again, from the command its process runs.
    private func restoreTerminalCommand() {
        guard terminalCommand == nil, let session = terminal.session,
              let command = TerminalOnlyCommand.invoked(by: session.command.arguments.first ?? "", agent: chat.agent) else { return }
        terminalCommand = TerminalCommandState(command: command, stage: session.state.isRunning ? .running : .done)
    }

    /// Takes a queued message back into the empty message box. A line comment comes back with its chip, as ↑ brings
    /// one, and without the code it was queued with: the next Send reads the lines again (CMT-05 Running, designer's
    /// update, 2026-09-25).
    private func edit(_ message: QueuedMessage) {
        guard !composerText.hasContent, !composerText.hasLineChip, chat.removeQueued(id: message.id) != nil else { return }
        composerText.load(text: message.text, files: message.attachments.map(\.path), lineRange: message.lineComment?.range)
        composerText.focus()
    }

    /// Esc stops the agent's turn, as in Claude Code; ⌘U attaches files. The message box handles its own keys
    /// (`ComposerTextView`).
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // A mini-modal (a permission request, a confirmation, an error, the commit, DLG-01) keeps every key while it
        // shows, Esc included, which cancels it before it could stop the turn (DLG-03), and ⌘U attaches nothing behind
        // it. Quick Open takes Esc and the arrows while it shows, and ⌘U attaches nothing behind it (FIL-08). Their
        // state is read from their presenters, references, at the key's time.
        if DialogPresenter.shared.isShowing || QuickOpenPresenter.shared.isShown { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard liveActive.value, let window = event.window, window.isKeyWindow else { return event }
        // A file picker types in a window of its own, and so does the app-modal alert of quitting with unsaved edits
        // once the window was closed (DLG-05): their keys are their own, Esc included, and ⌘U attaches nothing behind
        // them.
        if window.sheetParent != nil || NSApp.modalWindow != nil { return event }
        // A terminal with the keyboard gets every key, Esc included: the embedded terminal (CMD-08), whose Claude Code
        // screens use Esc to go back or quit, and the panel's terminals, where Esc belongs to the shell's programs.
        // Neither may stop the agent's turn.
        if window.firstResponder is TerminalView { return event }
        // The code editor with the keyboard, its find bar included, gets its keys too: Esc closes the find bar there
        // and never stops the agent's turn (EDIT-01).
        if CodeEditor.hasKeyboard(in: window) { return event }
        // The All files filter with the keyboard gets its keys too: its Esc clears the query, then leaves the field,
        // and never stops the agent's turn (FIL-04). Its focus is read through a reference, at the key's time.
        if FileFilterFocus.hasKeyboard(in: window) { return event }
        // A diff's comment box with the keyboard gets its keys too: its Esc closes it, or asks first with text (CMT-02).
        // KBD-02's order for Esc: an open menu, a mini-modal, the settings, the comment box, the filter, then the turn.
        if CommentComposerFocus.hasKeyboard(in: window) { return event }
        // An open menu, the settings, a repository's settings and the slash command popup keep Esc for closing
        // themselves (CMD-03). The popup's state is read from the controller, a reference, at the key's time.
        if event.keyCode == 53, modifiers.isEmpty, chat.state == .running, menus?.open == nil,
           !SettingsPresenter.shared.isPresented, !RepoSettingsPresenter.shared.isPresented, window.attachedSheet == nil,
           !composerText.popup.isOpen {
            Task { await chat.cancel() }
            return nil
        }
        guard modifiers == .command, event.charactersIgnoringModifiers == "u" else { return event }
        // After the key event: the open panel runs its own event loop.
        DispatchQueue.main.async { chooseAttachments() }
        return nil
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        composerText.insert(files: panel.urls)
        composerText.focus()
    }
}

/// A value a key monitor reads at the time of the key, not when the monitor was added.
@MainActor
private final class LiveFlag {
    var value = true
}

/// A new chat row fading in while it rises 6 points, 220 ms (MOT-02); with Reduce Motion it only fades, 150 ms.
/// `settle` records the row as seen as the animation starts, so it never plays twice for that row, even when a lone
/// tool call becomes a group. The embedded terminal (CMD-08) and a new conversation's tab (CNV-01) enter the same way.
struct Entrance: ViewModifier {
    let isNew: Bool
    let settle: () -> Void
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isNew: Bool, settle: @escaping () -> Void) {
        self.isNew = isNew
        self.settle = settle
        _shown = State(initialValue: !isNew)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 6)
            .onAppear {
                guard !shown else { return }
                settle()
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Theme.Motion.enter) { shown = true }
            }
    }
}

/// Shown next to the model while plan mode is on; clicking it leaves plan mode.
struct PlanModeChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "map")
                Text("Plan")
            }
            .font(.rocky(12))
            .foregroundStyle(Theme.plan)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.plan.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .help("Plan mode: the agent plans and asks before changing anything. Click or press ⇧Tab to leave it.")
    }
}

/// Send and Stop in the message box: a rounded square like Conductor's, white when it can be pressed.
struct ComposerButton: View {
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.rocky(13, weight: .bold))
                .frame(width: Zoom.shared(28), height: Zoom.shared(28))
                .foregroundStyle(isEnabled ? Color.black : Color.secondary)
                .background(isEnabled ? Color.white : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .clickable()
        .disabled(!isEnabled)
    }
}

struct ChatItemRow: View, Equatable {
    let item: ChatItem
    let isLive: Bool
    /// A user message's command, drawn as a chip (CMD-06).
    var command: String?

    var body: some View {
        switch item.kind {
        case .user:
            UserMessageRow(item: item, command: command)
        case .agent:
            // Headings, lists, highlighted code blocks and tables, styled like Conductor's replies.
            StructuredText(item.text, parser: RockyMarkdownParser(zoom: Zoom.shared.scale))
                .textual.structuredTextStyle(RockyMarkdownStyle())
                .textual.textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thought:
            ThoughtRow(item: item)
        case .tool:
            ToolCallRow(item: item, isLive: isLive)
        case .interrupted:
            InterruptedRow(text: item.text)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}

/// Under each finished reply: the agent, how long the turn took, when it ended, and a Copy button.
struct TurnFooterRow: View {
    let agent: AgentKind
    let summary: TurnSummary
    @State private var copied = false

    private var duration: String {
        let seconds = max(0, summary.completedAt.timeIntervalSince(summary.startedAt))
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }

    var body: some View {
        HStack(spacing: 8) {
            AgentIcon(agent: agent, size: 12)
            Text("\(agent.displayName) · \(duration) · \(summary.completedAt.formatted(date: .omitted, time: .shortened))")
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary.agentText, forType: .string)
                copied = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .clickable()
            .help("Copy the reply")
            .disabled(summary.agentText.isEmpty)
        }
        .font(.rocky(10))
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }
}

/// DLG-06's permission request, the large mini-modal, 460 wide: the agent's mark and "Permission needed", the request's
/// title in a mono block, and the buttons in `PermissionRequest.buttons`' order: Cancel and the rejects at the left, then
/// at the right Always Allow and Allow, which Return presses.
@MainActor
enum PermissionDialog {
    /// `answer` gets the option's id, or nil for Cancel.
    static func make(request: PermissionRequest, agent: AgentKind, answer: @escaping @MainActor (String?) -> Void) -> Dialog {
        Dialog(
            title: "Permission needed",
            agent: agent,
            width: 460,
            content: { AnyView(PermissionRequestBlock(text: request.title)) },
            buttons: request.buttons.map { button in
                DialogAction(title: button.option?.name ?? "Cancel", role: button.role, isLeading: button.isLeading) {
                    answer(button.option?.id)
                }
            }
        )
    }
}

/// The request's title, what the agent wants to run or change: 12.5 mono on `fillControl`, radius 8, padding 10,
/// selectable, up to ten lines, then it scrolls (DLG-06).
private struct PermissionRequestBlock: View {
    let text: String

    private static var tenLines: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: Zoom.shared(12.5), weight: .regular)
        return ceil(font.ascender - font.descender + font.leading) * 10
    }

    var body: some View {
        FittingScrollView(maxHeight: Self.tenLines + 20) {
            Text(text)
                .font(.rocky(12.5, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Theme.fillControl, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension EnvironmentValues {
    /// Changes once after a conversation appears, so Textual's selection overlays update (`ChatView`).
    @Entry var selectionRefresh = 0
}
