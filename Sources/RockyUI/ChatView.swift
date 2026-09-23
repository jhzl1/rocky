import RockyKit
import SwiftUI

struct ChatView: View {
    let chat: ChatSessionModel
    @State private var draft = ""
    private static let thinkingRowId = "thinking"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chat.items) { item in
                            ChatItemRow(item: item).id(item.id)
                        }
                        if chat.state == .running {
                            ThinkingRow(agent: chat.agent, waitingForPermission: chat.pendingPermission != nil)
                                .id(Self.thinkingRowId)
                        }
                    }
                    .padding()
                }
                .onChange(of: chat.items.last?.text) {
                    if let id = chat.items.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: chat.state) {
                    if chat.state == .running { proxy.scrollTo(Self.thinkingRowId, anchor: .bottom) }
                }
            }
            Divider()
            footer
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
            ProgressView("Starting \(chat.agent.displayName)…").padding()
        case .ready, .running:
            HStack(alignment: .bottom) {
                TextField("Message \(chat.agent.displayName)", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                if chat.state == .running {
                    Button("Stop") { Task { await chat.cancel() } }
                } else {
                    Button("Send", action: send)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
        }
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
                .padding(10)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .agent:
            Text(Self.markdown(item.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thought:
            Text(item.text)
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label {
                Text(item.text) + Text(item.status.map { "  \($0)" } ?? "").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: toolIcon)
            }
            .font(.callout)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var toolIcon: String {
        switch item.status {
        case "completed": "checkmark.circle"
        case "failed": "xmark.circle"
        default: "hammer"
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Shown at the end of the conversation while the agent works on a turn.
struct ThinkingRow: View {
    let agent: AgentKind
    let waitingForPermission: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(waitingForPermission ? "Waiting for your permission…" : "\(agent.displayName) is thinking…")
                .foregroundStyle(.secondary)
        }
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
