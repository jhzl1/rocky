import AppKit
import RockyKit
import SwiftUI

/// The window: sidebar panel, hairline divider, workspace. A custom layout instead of NavigationSplitView, whose
/// column divider is drawn black and cannot be restyled. The title bar is hidden, so the sidebar is one
/// full-height panel with the window buttons on it and the workspace header sits at the very top.
public struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 260.0
    /// Rocky's own menus, drawn over the whole window (`MenuHost`).
    @State private var menus = MenuPresenter()

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                VStack(spacing: 0) {
                    SidebarTopBar(onToggleSidebar: toggleSidebar, onAddRepository: addRepository)
                    SidebarView(model: model)
                }
                .frame(width: sidebarWidth)
                .background(Color.rockySidebar)
                SidebarDivider(width: $sidebarWidth)
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.rockyBackground)
                // With the sidebar hidden, the window buttons and Show Sidebar sit over the workspace header.
                .environment(\.titleBarLeadingInset, sidebarVisible ? 0 : 110)
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .topLeading) {
            if !sidebarVisible {
                Button("Show Sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.rocky(14))
                    .padding(.leading, 78)
                    .frame(height: 28)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .preferredColorScheme(.dark)
        // The default font of every view that sets none (sidebar rows, buttons, fields), at Rocky's zoom.
        .font(.rocky(13))
        .overlay(alignment: .bottom) {
            if let busy = model.busyMessage {
                ProgressLabel(text: busy)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
            }
        }
        .overlay { MenuHost(presenter: menus) }
        .environment(menus)
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
            ContentUnavailableView {
                Label {
                    Text("No workspace selected")
                } icon: {
                    RockyLogo(size: 96)
                }
            } description: {
                Text("Add a repository, then create a workspace from its menu.")
            }
        }
    }

    private func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.15)) { sidebarVisible.toggle() }
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
