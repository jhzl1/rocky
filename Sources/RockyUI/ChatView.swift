import AppKit
import RockyKit
import SwiftUI
import Textual

struct ChatView: View {
    let chat: ChatSessionModel
    /// False while a file tab covers the conversation: the view stays, with its draft, but takes no shortcut.
    var isActive = true
    @State private var composerText = ComposerController()
    @State private var keyMonitor: Any?
    @Environment(\.openFile) private var openFile
    /// The last thing in the scroll view: scrolling to it reaches the very bottom, even while a reply's markdown
    /// is still being laid out.
    private static let bottomId = "bottom"
    /// Like Conductor, long replies read in a centered column instead of across the whole window.
    private static let readingWidth: CGFloat = 820
    /// The conversation's side margin, and the inner padding of the message box and the question card.
    static let columnPadding: CGFloat = 24
    static let boxPadding: CGFloat = 14

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
                            switch row {
                            case .item(let item): ChatItemRow(item: item, isLive: isLive(item)).equatable()
                            case .tools(let tools): ToolGroupRow(tools: tools, isLive: tools.last.map(isLive) ?? false)
                            case .turnFooter(let summary): TurnFooterRow(agent: chat.agent, summary: summary)
                            }
                        }
                        if chat.state == .running {
                            ThinkingRow(startedAt: chat.turnStartedAt)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomId)
                    }
                    .font(.rocky(14))
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
            }
        }
        .onAppear {
            chat.isVisible = true
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKey($0) }
            DispatchQueue.main.async { composerText.focus() }
        }
        .onChange(of: isActive) {
            if isActive { composerText.focus() } else { composerText.resignFocus() }
        }
        .onDisappear {
            chat.isVisible = false
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .sheet(isPresented: Binding(
            get: { chat.pendingPermission != nil },
            set: { if !$0 { chat.answerPermission(optionId: nil) } }
        )) {
            if let request = chat.pendingPermission {
                PermissionSheet(request: request) { chat.answerPermission(optionId: $0) }
            }
        }
    }

    /// The agent's questions, then the message box, floating above the conversation; the conversation fades out
    /// under them.
    private var bottomArea: some View {
        VStack(spacing: 10) {
            if let question = chat.pendingQuestion {
                QuestionCard(agent: chat.agent, request: question) { chat.answerQuestion($0) }
                    .id(question.questions.map(\.id).joined() + question.message)
            }
            footer
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
            }
            .padding(Self.boxPadding)
            .background(Theme.composer, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.composerBorder))
        case .idle, .starting, .ready, .running:
            // The agent may still be starting in the background; a message sent meanwhile waits for it.
            composer
        }
    }

    /// A tool call of the turn in progress: while it is pending it is still running.
    private func isLive(_ item: ChatItem) -> Bool {
        guard chat.state == .running, let start = chat.turnStartedAt else { return false }
        return item.createdAt >= start
    }

    private var canSend: Bool {
        composerText.hasContent && chat.state != .running
    }

    /// A roomy message box laid out like Conductor's: the text with its files inside it as badges, then model and
    /// effort on the left, the + menu and send on the right. Return sends, Shift-Return starts a new line, Shift-Tab
    /// switches plan mode; pasting or dropping images and files puts them in the text.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ComposerEditor(
                controller: composerText,
                zoom: Zoom.shared.scale,
                history: chat.items.filter { $0.kind == .user }.map { MessageHistory.Entry(text: $0.text, files: $0.attachments) },
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
                ModelMenuButton(chat: chat)
                if chat.isPlanMode {
                    PlanModeChip { Task { await chat.setPlanMode(false) } }
                }
                Spacer()
                plusMenu
                if chat.state == .running {
                    ComposerButton(systemImage: "stop.fill", isEnabled: true) { Task { await chat.cancel() } }
                        .help("Stop the agent's turn")
                } else {
                    ComposerButton(systemImage: "arrow.up", isEnabled: canSend, action: send)
                        .help("Send (Return)")
                }
            }
        }
        .padding(Self.boxPadding)
        // Opaque, with a shadow, since it floats over the conversation. The border is drawn inside the shape: a
        // centered stroke falls half a point outside and smears across two pixels on a 1x screen.
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.composerBorder))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        // Files dropped on the box outside its text go in at the insertion point.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            composerText.insert(files: files)
            return !files.isEmpty
        }
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
            if chat.canUsePlanMode {
                MenuItem(title: "Plan mode", icon: .symbol("map"), shortcut: "⇧Tab", isChecked: chat.isPlanMode) {
                    Task { await chat.setPlanMode(!chat.isPlanMode) }
                }
            }
        }
        .help("Attach files or switch plan mode")
    }

    private func send() {
        guard canSend else { return }
        let message = composerText.takeMessage()
        Task { await chat.send(message.text, attachments: message.files) }
    }

    /// ⌘U attaches files. The message box handles its own keys (`ComposerTextView`).
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard isActive, modifiers == .command, event.charactersIgnoringModifiers == "u" else { return event }
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
        .disabled(!isEnabled)
    }
}

struct ChatItemRow: View, Equatable {
    let item: ChatItem
    let isLive: Bool

    var body: some View {
        switch item.kind {
        case .user:
            UserMessageRow(item: item)
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
            .help("Copy the reply")
            .disabled(summary.agentText.isEmpty)
        }
        .font(.rocky(10))
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }
}

struct PermissionSheet: View {
    let request: PermissionRequest
    let answer: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permission needed").font(.rocky(13, weight: .semibold))
            Text(request.title).textSelection(.enabled)
            HStack {
                Button("Cancel") { answer(nil) }
                Spacer()
                ForEach(request.options) { option in
                    if option.kind.hasPrefix("allow") {
                        Button(option.name) { answer(option.id) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(option.name) { answer(option.id) }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}
