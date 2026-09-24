import RockyKit
import SwiftUI

struct WorkspaceDetailView: View {
    let model: AppModel
    let workspace: Workspace
    @State private var panelSelection: UUID?
    /// The terminal panel folded to its bar; its terminals and scripts keep running.
    @AppStorage("terminalPanelCollapsed") private var panelCollapsed = false
    @Environment(\.titleBarLeadingInset) private var titleBarLeadingInset

    /// Read from the model, not kept here: a chat the model stops (for example after a settings change) must go away.
    private var chat: ChatSessionModel? {
        model.existingChat(workspaceId: workspace.id)
    }

    private var run: PTYSession? {
        model.existingProcesses(for: workspace.id)?.run
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ConversationTabs(model: model, workspace: workspace)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            // Chat above, terminals and script output below (M2 layout decision). Until something runs in the
            // panel, and while it is folded, it is only its bar, so the chat keeps the window.
            if model.existingProcesses(for: workspace.id)?.all.isEmpty ?? true || panelCollapsed {
                VStack(spacing: 0) {
                    chatArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    WorkspacePanelView(model: model, workspace: workspace, selection: $panelSelection, isCollapsed: $panelCollapsed)
                }
            } else {
                VSplitView {
                    chatArea
                        .frame(maxWidth: .infinity, minHeight: 200, idealHeight: 520, maxHeight: .infinity)
                    WorkspacePanelView(model: model, workspace: workspace, selection: $panelSelection, isCollapsed: $panelCollapsed)
                        .frame(maxWidth: .infinity, minHeight: 140, idealHeight: 240, maxHeight: .infinity)
                }
            }
        }
        .task {
            await model.showConversations(workspace: workspace)
        }
        // A file badge anywhere in the workspace opens its file in a tab here.
        .environment(\.openFile, OpenFileAction { [model, workspace] path in
            model.openFile(workspaceId: workspace.id, path: path)
        })
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name).font(.rocky(13, weight: .semibold))
                Text(workspace.path)
                    .font(.rocky(10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if let port = workspace.port {
                // String(port): interpolating an Int into Text localizes it as "41,000".
                Text("PORT \(String(port))")
                    .font(.rocky(10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("This workspace owns ports \(String(port))–\(String(port + 9)): $PORT and $ROCKY_PORT are \(String(port)).")
            }
            runButton
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .padding(.leading, titleBarLeadingInset)
        // The header is where the title bar was: drag the window from its empty space.
        .windowDragBackground()
    }

    @ViewBuilder
    private var runButton: some View {
        if let run, run.state.isRunning {
            Button("Stop", systemImage: "stop.fill") {
                Task { await model.stopRun(workspaceId: workspace.id) }
            }
        } else {
            Button("Run", systemImage: "play.fill") {
                Task {
                    await model.startRun(workspaceId: workspace.id)
                    panelSelection = run?.id
                    panelCollapsed = false
                }
            }
        }
    }

    /// The selected conversation, or the file tab on top of it. The conversation stays underneath a file tab, so its
    /// draft and scroll position are there when you come back.
    private var chatArea: some View {
        let file = model.selectedFiles[workspace.id]
        return ZStack {
            if let chat {
                ChatView(chat: chat, isActive: file == nil)
                    // A new view per conversation, so switching tabs does not carry a draft or a scroll position over.
                    .id(ObjectIdentifier(chat))
                    .opacity(file == nil ? 1 : 0)
                    .allowsHitTesting(file == nil)
            } else if file == nil {
                ProgressLabel(text: "Opening the conversation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let file {
                FileTabView(path: file)
                    .background(Color.rockyBackground)
            }
        }
    }
}

/// The workspace's tabs, like Conductor's: its conversations (agent logo and title), then the files opened from a
/// badge (type icon and name); the selected one underlined, and a + for a new Claude Code or OpenCode conversation.
struct ConversationTabs: View {
    let model: AppModel
    let workspace: Workspace

    var body: some View {
        let open = model.conversations[workspace.id] ?? []
        let selectedId = model.selectedConversationIds[workspace.id]
        let files = model.openFiles[workspace.id] ?? []
        let selectedFile = model.selectedFiles[workspace.id]
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(open) { record in
                        let agent = AgentKind(rawValue: record.agent) ?? .claude
                        WorkspaceTab(
                            title: record.title ?? "New conversation",
                            isSelected: record.id == selectedId && selectedFile == nil,
                            onSelect: { Task { await model.showConversation(workspace: workspace, conversationId: record.id) } },
                            onClose: { Task { await model.closeConversation(workspace: workspace, conversationId: record.id) } }
                        ) {
                            if model.chat(conversationId: record.id)?.state == .running {
                                CircularProgress(size: 11)
                            } else {
                                AgentIcon(agent: agent, size: 12)
                            }
                        }
                        .help(record.title ?? "New conversation")
                    }
                    ForEach(files, id: \.self) { path in
                        let kind = FileKind(path: path)
                        WorkspaceTab(
                            title: URL(fileURLWithPath: path).lastPathComponent,
                            isSelected: path == selectedFile,
                            onSelect: { model.showFile(workspaceId: workspace.id, path: path) },
                            onClose: { model.closeFile(workspaceId: workspace.id, path: path) }
                        ) {
                            Image(systemName: kind.symbol)
                                .font(.rocky(11))
                                .foregroundStyle(kind.color)
                        }
                        .help(path)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            MenuButton(id: "new-conversation-\(workspace.id)", placement: .belowLeading, width: 280) { isOpen in
                Image(systemName: "plus")
                    .frame(width: Zoom.shared(28), height: Zoom.shared(28))
                    .background(Color.white.opacity(isOpen ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            } content: {
                ForEach(AgentKind.allCases) { agent in
                    MenuItem(title: "New \(agent.displayName) conversation", icon: .agent(agent)) {
                        Task { await model.newConversation(workspace: workspace, agent: agent) }
                    }
                }
            }
            .fixedSize()
            .help("New conversation")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }
}

/// One tab of the workspace: an icon, the title, and an × that always takes its space, so hovering never shifts
/// the tabs.
struct WorkspaceTab<Icon: View>: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            icon()
            Text(title)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.rocky(10))
                .opacity(hovering || isSelected ? 1 : 0)
                .help("Close the tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Color.primary : Color.clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}
