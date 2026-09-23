import RockyKit
import SwiftUI

struct WorkspaceDetailView: View {
    let model: AppModel
    let workspace: Workspace
    @State private var agent: AgentKind = .claude
    @State private var chat: ChatSessionModel?
    @State private var starting = false

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
            if let existing = model.existingChat(workspaceId: workspace.id) {
                chat = existing
                agent = existing.agent
            }
        }
    }

    private func start() async {
        starting = true
        chat = await model.openChat(workspace: workspace, agent: agent)
        starting = false
    }
}
