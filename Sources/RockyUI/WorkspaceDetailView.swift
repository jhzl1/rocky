import RockyKit
import SwiftUI

struct WorkspaceDetailView: View {
    let model: AppModel
    let workspace: Workspace
    @State private var agent: AgentKind
    @State private var starting = false
    @State private var panelSelection: UUID?
    @Environment(\.titleBarLeadingInset) private var titleBarLeadingInset

    init(model: AppModel, workspace: Workspace) {
        self.model = model
        self.workspace = workspace
        // Reopen the agent you used last in this workspace.
        let agent = model.existingChat(workspaceId: workspace.id)?.agent ?? model.lastAgent(workspaceId: workspace.id) ?? .claude
        _agent = State(initialValue: agent)
    }

    /// Read from the model, not kept here: a chat the model stops (for example after a settings change) must show Start again.
    private var chat: ChatSessionModel? {
        model.existingChat(workspaceId: workspace.id)
    }

    private var run: PTYSession? {
        model.existingProcesses(for: workspace.id)?.run
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            // Chat above, terminals and script output below (M2 layout decision). Until something runs in the
            // panel it is only its bar, so the chat keeps the window.
            if model.existingProcesses(for: workspace.id)?.all.isEmpty ?? true {
                VStack(spacing: 0) {
                    chatArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    WorkspacePanelView(model: model, workspace: workspace, selection: $panelSelection)
                }
            } else {
                VSplitView {
                    chatArea
                        .frame(maxWidth: .infinity, minHeight: 200, idealHeight: 520, maxHeight: .infinity)
                    WorkspacePanelView(model: model, workspace: workspace, selection: $panelSelection)
                        .frame(maxWidth: .infinity, minHeight: 140, idealHeight: 240, maxHeight: .infinity)
                }
            }
        }
        // Show the conversation right away; the agent itself starts with the first message.
        .task(id: agent) {
            await model.prepareChat(workspace: workspace, agent: agent)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name).font(.headline)
                Text(workspace.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if let port = workspace.port {
                // String(port): interpolating an Int into Text localizes it as "41,000".
                Text("PORT \(String(port))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help("This workspace owns ports \(String(port))–\(String(port + 9)): $PORT and $CONDUCTOR_PORT are \(String(port)).")
            }
            runButton
            Button("New Conversation", systemImage: "square.and.pencil") {
                Task { await model.newConversation(workspace: workspace, agent: agent) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("New conversation (earlier ones stay saved)")
            AgentSwitcher(selection: $agent)
        }
        .padding()
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
                }
            }
        }
    }

    @ViewBuilder
    private var chatArea: some View {
        if let chat, chat.agent == agent {
            ChatView(chat: chat)
        } else {
            // Agents start only on request: an idle workspace spawns no process (spec Section 1).
            ContentUnavailableView {
                Label {
                    Text("\(agent.displayName) is not running")
                } icon: {
                    AgentIcon(agent: agent, size: 40)
                }
            } actions: {
                Button("Start \(agent.displayName)") { Task { await start() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(starting)
            }
        }
    }

    private func start() async {
        starting = true
        _ = await model.openChat(workspace: workspace, agent: agent)
        starting = false
    }
}
