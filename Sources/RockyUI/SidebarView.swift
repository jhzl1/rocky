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
                                CircularProgress(size: 12)
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
                // A sidebar section is collapsible by default, and its chevron appears only on hover, shifting
                // the repo menu button each time.
                .collapsible(false)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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
}

/// The line between the sidebar and the workspace: a light hairline (the system split view draws a black one),
/// with a wider invisible handle to drag the sidebar's width.
struct SidebarDivider: View {
    @Binding var width: Double
    @State private var widthAtDragStart: Double?
    static let widthRange: ClosedRange<Double> = 200...420

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1)
            .ignoresSafeArea()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = widthAtDragStart ?? width
                                widthAtDragStart = start
                                width = min(max(start + drag.translation.width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
            }
    }
}
