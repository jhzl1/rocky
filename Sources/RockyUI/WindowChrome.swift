import SwiftUI

// The window has no title bar (`.windowStyle(.hiddenTitleBar)`): the sidebar's top row holds the window
// buttons, and the workspace header sits at the very top. These helpers stand in for what the title bar did.

extension EnvironmentValues {
    /// Room the workspace header leaves on its left for the window buttons while the sidebar is hidden.
    @Entry var titleBarLeadingInset: CGFloat = 0
}

extension View {
    /// Lets the user drag the window from this view's empty background, as they would from a title bar.
    func windowDragBackground() -> some View {
        background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
    }
}

/// The sidebar's top row: space for the window buttons, then Hide Sidebar and Add Repository.
struct SidebarTopBar: View {
    let onToggleSidebar: () -> Void
    let onAddRepository: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button("Hide Sidebar", systemImage: "sidebar.left", action: onToggleSidebar)
            Spacer()
            Button("Add Repository", systemImage: "plus", action: onAddRepository)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.rocky(14))
        // The window buttons take the first ~76 points; the row is as tall as the hidden title bar.
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .frame(height: 28)
        .windowDragBackground()
    }
}
