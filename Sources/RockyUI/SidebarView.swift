import AppKit
import RockyKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var settingsRepo: Repo?
    @State private var workspaceToRemove: Workspace?

    var body: some View {
        List(selection: $model.selectedWorkspaceId) {
            ForEach(model.repos) { repo in
                Section {
                    ForEach(model.workspaces[repo.id] ?? []) { workspace in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.name)
                            Text(workspace.branch)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(workspace.id)
                        .contextMenu {
                            Button("Remove Workspace…", role: .destructive) { workspaceToRemove = workspace }
                        }
                    }
                } header: {
                    header(for: repo)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .toolbar {
            ToolbarItem {
                Button("Add Repository", systemImage: "plus", action: addRepository)
            }
        }
        .sheet(item: $settingsRepo) { repo in
            RepoSettingsView(model: model, repo: repo)
        }
        .confirmationDialog(
            "Remove \(workspaceToRemove?.name ?? "")?",
            isPresented: Binding(get: { workspaceToRemove != nil }, set: { if !$0 { workspaceToRemove = nil } }),
            presenting: workspaceToRemove
        ) { workspace in
            Button("Remove Worktree", role: .destructive) {
                Task { await model.removeWorkspace(id: workspace.id) }
            }
        } message: { workspace in
            Text("Deletes the folder \(workspace.path). The branch \(workspace.branch) is kept. Git refuses while there are uncommitted changes.")
        }
    }

    private func header(for repo: Repo) -> some View {
        HStack {
            Text(repo.name)
            Spacer()
            Menu {
                Button("New Workspace") { Task { await model.createWorkspace(repoId: repo.id) } }
                Button("Settings…") { settingsRepo = repo }
                Divider()
                Button("Remove from Rocky", role: .destructive) { Task { await model.removeRepo(id: repo.id) } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            // The icon is the whole button; the default chevron read as a second control.
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addRepo(at: url) }
    }
}
