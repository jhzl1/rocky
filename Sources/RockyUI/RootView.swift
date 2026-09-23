import AppKit
import RockyKit
import SwiftUI

/// The window: sidebar panel, hairline divider, workspace. A custom layout instead of NavigationSplitView, whose
/// column divider is drawn black and cannot be restyled. Both backgrounds run under the transparent title bar,
/// so the sidebar reads as one full-height panel with the window buttons on it.
public struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 260.0

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(model: model)
                    .frame(width: sidebarWidth)
                    .background(Color.rockySidebar.ignoresSafeArea())
                SidebarDivider(width: $sidebarWidth)
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.rockyBackground.ignoresSafeArea())
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Toggle Sidebar", systemImage: "sidebar.left") {
                    withAnimation(.easeOut(duration: 0.15)) { sidebarVisible.toggle() }
                }
                Button("Add Repository", systemImage: "plus", action: addRepository)
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if let busy = model.busyMessage {
                ProgressView(busy)
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
            }
        }
        .alert(
            "Rocky",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let workspace = model.selectedWorkspace {
            WorkspaceDetailView(model: model, workspace: workspace)
                .id(workspace.id)
        } else {
            ContentUnavailableView(
                "No workspace selected",
                systemImage: "square.stack.3d.up",
                description: Text("Add a repository, then create a workspace from its menu.")
            )
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
