import RockyKit
import SwiftUI

struct WorkspaceDetailView: View {
    let model: AppModel
    let workspace: Workspace
    @State private var agent: AgentKind = .claude
    @State private var starting = false

    /// Read from the model, not kept here: a chat the model stops (for example after a settings change) must show Start again.
    private var chat: ChatSessionModel? {
        model.existingChat(workspaceId: workspace.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name).font(.headline)
                    Text(workspace.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Picker("Agent", selection: $agent) {
                    ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding()
            Divider()
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
        .onAppear {
            if let chat { agent = chat.agent }
        }
    }

    private func start() async {
        starting = true
        _ = await model.openChat(workspace: workspace, agent: agent)
        starting = false
    }
}
