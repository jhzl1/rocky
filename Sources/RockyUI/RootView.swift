import RockyKit
import SwiftUI

public struct RootView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            Group {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.rockyBackground)
        }
        .toolbarBackground(Color.rockyBackground, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
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
}
