import RockyKit
import SwiftUI

/// A repository's header in the sidebar (SB-03, SB-04): monogram, name and fold chevron, which fold or unfold it on
/// click; while folded, the most urgent state of its workspaces; then "…" on hover and an always visible "+".
struct RepoHeader: View {
    let repo: Repo
    /// Its workspaces in the list: all of them, or the matches while searching.
    let workspaceCount: Int
    let isFolded: Bool
    /// SB-04: shown while folded, nothing when every workspace is idle.
    let foldedStatus: WorkspaceStatus
    let onToggleFold: () -> Void
    let onNewWorkspace: () -> Void
    let onSettings: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false
    @State private var plusHovering = false

    private var menuId: String { "repo-\(repo.id)" }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onToggleFold) {
                HStack(spacing: 8) {
                    monogram
                    Text(repo.name)
                        .font(.rocky(13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    chevron
                    Spacer(minLength: 0)
                    if isFolded, foldedStatus != .idle {
                        WorkspaceStatusGlyph(status: foldedStatus, size: 12)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(RepoHeaderButtonStyle())
            .clickable()
            .accessibilityLabel(spokenLabel)
            MenuButton(id: menuId, placement: .belowTrailing, width: 220) { isOpen in
                SidebarMenuIcon(systemImage: "ellipsis", label: "\(repo.name) actions", isOpen: isOpen)
                    // Shown on hover, and while its menu is open.
                    .opacity(hovering || isOpen ? 1 : 0)
            } content: {
                menuItems
            }
            .help("More")
            Button(action: onNewWorkspace) {
                Label("New workspace in \(repo.name)", systemImage: "plus")
                    // SB-03: `textTertiary` at rest, unlike the other icon buttons.
                    .foregroundStyle(plusHovering ? Theme.textPrimary : Theme.textTertiary)
            }
            .buttonStyle(RockyIconButtonStyle(size: 22))
            .onHover { inside in withAnimation(Theme.Motion.hover) { plusHovering = inside } }
            .help("New workspace")
        }
        .font(.rocky(12))
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: Zoom.shared(28))
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .rockyContextMenu(id: "repo-context-\(repo.id)") { menuItems }
    }

    private var monogram: some View {
        let palette = Theme.repoPalette
        let index = repo.colorIndex ?? RepoMonogram.paletteIndex(repoId: repo.id, paletteCount: palette.count)
        let color = palette[index % palette.count]
        return Text(RepoMonogram.letter(repoName: repo.name))
            .font(.rocky(10, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: Zoom.shared(16), height: Zoom.shared(16))
            .background(color, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }

    /// SB-04: points right while folded and always shows; points down while expanded and shows only on hover. It
    /// turns 90° in 150 ms.
    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.rocky(10, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .rotationEffect(.degrees(isFolded ? 0 : 90))
            .animation(Theme.Motion.state, value: isFolded)
            .opacity(isFolded || hovering ? 1 : 0)
            .accessibilityHidden(true)
    }

    /// The same menu for "…" and a right-click (SB-03).
    @ViewBuilder
    private var menuItems: some View {
        MenuItem(title: "New Workspace", icon: .symbol("plus"), shortcut: "⌘N", action: onNewWorkspace)
        MenuItem(title: "Settings…", icon: .symbol("slider.horizontal.3"), action: onSettings)
        MenuDivider()
        MenuItem(title: "Remove from Rocky", icon: .symbol("trash"), isDestructive: true, action: onRemove)
    }

    /// A11Y-01: "name, collapsed/expanded, n workspaces".
    private var spokenLabel: String {
        let state = isFolded ? "collapsed" : "expanded"
        let count = workspaceCount == 1 ? "1 workspace" : "\(workspaceCount) workspaces"
        return "\(repo.name), \(state), \(count)"
    }
}

/// The header draws its own look; a press does not dim it.
private struct RepoHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
