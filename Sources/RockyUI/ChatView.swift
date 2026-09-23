import AppKit
import RockyKit
import SwiftUI
import Textual

struct ChatView: View {
    let chat: ChatSessionModel
    @State private var draft = ""
    private static let thinkingRowId = "thinking"
    /// Like Conductor, long replies read in a centered column instead of across the whole window.
    private static let readingWidth: CGFloat = 820

    var body: some View {
        let rows = ChatLayout.rows(chat.items)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(rows) { row in
                            switch row {
                            case .item(let item): ChatItemRow(item: item)
                            case .tools(let tools): ToolGroupRow(tools: tools)
                            case .turnFooter(let summary): TurnFooterRow(agent: chat.agent, summary: summary)
                            }
                        }
                        if chat.state == .running {
                            ThinkingRow(agent: chat.agent, waitingForPermission: chat.pendingPermission != nil)
                                .id(Self.thinkingRowId)
                        }
                    }
                    .font(.system(size: 14))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: Self.readingWidth)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: chat.items.last?.text) {
                    if let id = ChatLayout.rows(chat.items).last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: chat.state) {
                    if chat.state == .running { proxy.scrollTo(Self.thinkingRowId, anchor: .bottom) }
                }
            }
            footer
                .frame(maxWidth: Self.readingWidth)
                .frame(maxWidth: .infinity)
        }
        .onAppear { chat.isVisible = true }
        .onDisappear { chat.isVisible = false }
        .sheet(isPresented: Binding(
            get: { chat.pendingPermission != nil },
            set: { if !$0 { chat.answerPermission(optionId: nil) } }
        )) {
            if let request = chat.pendingPermission {
                PermissionSheet(request: request) { chat.answerPermission(optionId: $0) }
            }
        }
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
            .padding()
        case .idle, .starting:
            ProgressLabel(text: "Starting \(chat.agent.displayName)…").padding()
        case .ready, .running:
            composer
        }
    }

    /// A roomy message box like Conductor's: Return sends, Shift-Return starts a new line.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Ask \(chat.agent.displayName) to make changes…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(2...10)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    draft.append("\n")
                    return .handled
                }
                .onSubmit(send)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    AgentIcon(agent: chat.agent, size: 13)
                    Text(chat.agent.displayName)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                if chat.state == .running {
                    Button("Stop", systemImage: "stop.fill") { Task { await chat.cancel() } }
                        .help("Stop the agent's turn")
                } else {
                    Button("Send", systemImage: "arrow.up", action: send)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .clipShape(Circle())
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send (Return)")
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1)))
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, chat.state == .ready else { return }
        draft = ""
        Task { await chat.send(text) }
    }
}

struct ChatItemRow: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            Text(item.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 620, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .agent:
            // Headings, lists, highlighted code blocks and tables, styled like Conductor's replies.
            StructuredText(markdown: item.text)
                .textual.structuredTextStyle(RockyMarkdownStyle())
                .textual.textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thought:
            Text(item.text)
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ToolCallRow(item: item)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}

struct ToolCallRow: View {
    let item: ChatItem

    var body: some View {
        Label {
            Text(item.text) + Text(item.status.map { "  \($0)" } ?? "").foregroundStyle(.secondary)
        } icon: {
            Image(systemName: icon)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var icon: String {
        switch item.status {
        case "completed": "checkmark.circle"
        case "failed": "xmark.circle"
        default: "hammer"
        }
    }
}

/// Consecutive tool calls folded into one line, like Conductor's "2 tool calls"; click to see each one.
struct ToolGroupRow: View {
    let tools: [ChatItem]
    @State private var expanded = false

    private var title: String {
        let failed = tools.filter { $0.status == "failed" }.count
        return "\(tools.count) tool calls" + (failed > 0 ? " · \(failed) failed" : "")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tools) { ToolCallRow(item: $0) }
            }
            .padding(.top, 6)
        } label: {
            Label(title, systemImage: "hammer")
                .font(.callout)
                .foregroundStyle(.secondary)
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
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }
}

/// Shown at the end of the conversation while the agent works on a turn.
struct ThinkingRow: View {
    let agent: AgentKind
    let waitingForPermission: Bool

    var body: some View {
        ProgressLabel(text: waitingForPermission ? "Waiting for your permission…" : "\(agent.displayName) is thinking…")
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PermissionSheet: View {
    let request: PermissionRequest
    let answer: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permission needed").font(.headline)
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
