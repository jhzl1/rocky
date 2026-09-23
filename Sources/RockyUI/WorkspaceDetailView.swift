import RockyKit
import SwiftUI

struct WorkspaceDetailView: View {
    let model: AppModel
    let workspace: Workspace
    @State private var agent: AgentKind = .claude
    @State private var starting = false
    @State private var panelSelection: UUID?
    @Environment(\.titleBarLeadingInset) private var titleBarLeadingInset

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
            Divider()
            // Chat above, terminals and script output below (M2 layout decision).
            VSplitView {
                chatArea
                    .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                WorkspacePanelView(model: model, workspace: workspace, selection: $panelSelection)
                    .frame(maxWidth: .infinity, minHeight: 140, idealHeight: 260, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let chat { agent = chat.agent }
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
            Picker("Agent", selection: $agent) {
                ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
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
                Label("\(agent.displayName) is not running", systemImage: "bubble.left.and.bubble.right")
            } actions: {
                Button("Start \(agent.displayName)") { Task { await start() } }
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
