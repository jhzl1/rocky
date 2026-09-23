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
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workspace.name)
                                Text(workspace.branch)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Visible from any workspace, so you can see which agents are still working.
                            if model.existingChat(workspaceId: workspace.id)?.state == .running {
                                ProgressView()
                                    .controlSize(.small)
                                    .help("The agent is working")
                            }
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
        .scrollContentBackground(.hidden)
        .background(Color.rockySidebar)
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
            Text("Stops its agent, terminals and scripts, runs the archive script, then deletes the folder \(workspace.path). The branch \(workspace.branch) is kept. Git refuses while there are uncommitted changes.")
        }
        .alert(
            "Archive script failed",
            isPresented: Binding(get: { model.archiveFailure != nil }, set: { if !$0 { model.archiveFailure = nil } }),
            presenting: model.archiveFailure
        ) { failure in
            Button("Remove Anyway", role: .destructive) {
                Task { await model.removeWorkspace(id: failure.workspaceId, skipArchive: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { failure in
            Text("\(failure.message) \(failure.workspaceName) was not removed; the Archive tab shows its output.")
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
