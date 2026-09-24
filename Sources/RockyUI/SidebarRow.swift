import AppKit
import RockyKit
import SwiftUI

/// A workspace in the sidebar (ROW-01): one 28-point line with the status glyph, the task title and a trailing slot
/// that holds, in order of precedence, the hover actions (ROW-05), the ⌘ hint (KBD-01) and the diff stats (GIT-03).
/// The branch and the workspace name are in the tooltip; the branch also leads the top bar.
struct SidebarRow: View {
    let workspace: Workspace
    let title: String
    /// The workspace name stands in for a task title (ROW-02), so it is drawn dimmer.
    let titleIsFallback: Bool
    let status: WorkspaceStatus
    let isSelected: Bool
    /// The list has keyboard focus and this is its selected row: the focus ring shows, and so do the hover actions
    /// (ROW-05, KBD-01).
    let hasKeyboardFocus: Bool
    /// "⌘1"…"⌘9" while ⌘ is held (KBD-01).
    let shortcutHint: String?
    /// ⌘ is held: GIT-03's stats hide for every row, also the rows past the ninth, which have no hint.
    let isCommandHeld: Bool
    /// GIT-03's `+A −D` against the workspace's base; nil until git has read it, hidden while it is empty.
    let diffStat: DiffStat?
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false
    @Environment(MenuPresenter.self) private var presenter: MenuPresenter?

    /// Remove workspace and More: two 22-point buttons 2 apart.
    private static let actionsWidth: CGFloat = 22 + 2 + 22

    private var moreMenuId: String { "workspace-more-\(workspace.id)" }

    /// Also while its More menu is open, so the button that opened it does not fade out from under the menu.
    private var showsActions: Bool {
        hovering || hasKeyboardFocus || presenter?.isOpen(moreMenuId) == true
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                WorkspaceStatusGlyph(status: status, size: 14)
                    .frame(width: Zoom.shared(16), height: Zoom.shared(16))
                Text(title)
                    .font(.rocky(13))
                    // ROW-07: a merged workspace's title steps back.
                    .foregroundStyle(status == .merged ? Theme.textTertiary : titleIsFallback ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let shortcutHint, !showsActions {
                    Text(shortcutHint)
                        .font(.rocky(11))
                        .foregroundStyle(Theme.textTertiary)
                } else if let diffStat, !diffStat.isEmpty, !showsActions, !isCommandHeld {
                    DiffStatLabel(stat: diffStat)
                }
            }
            .padding(.leading, 24)
            // The hover actions sit 4 from the right edge; the title stops 8 before them.
            .padding(.trailing, showsActions ? 4 + Zoom.shared(Self.actionsWidth) + 8 : 8)
            .frame(height: Zoom.shared(28))
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .clickable()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Remove Workspace…", onRemove)
        .accessibilityAction(named: "Open in Finder", openInFinder)
        .accessibilityAction(named: "Copy Branch Name", copyBranch)
        .overlay(alignment: .trailing) {
            actions
        }
        .background(
            isSelected ? Theme.fillSelected : hovering ? Theme.fillHover : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            // KBD-01: keyboard focus only, 2 points inside the row's radius.
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(hasKeyboardFocus ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .help(tooltip)
        .rockyContextMenu(id: "workspace-\(workspace.id)") { menuItems }
    }

    /// ROW-05: they replace the trailing slot and fade in 120 ms.
    private var actions: some View {
        HStack(spacing: 2) {
            Button(action: onRemove) {
                Label("Remove workspace", systemImage: "archivebox")
            }
            .buttonStyle(RockyIconButtonStyle(size: 22))
            .help("Remove workspace…")
            MenuButton(id: moreMenuId, placement: .belowTrailing, width: 220) { isOpen in
                SidebarMenuIcon(systemImage: "ellipsis", label: "More actions", isOpen: isOpen)
            } content: {
                menuItems
            }
            .help("More")
        }
        .font(.rocky(12))
        .padding(.trailing, 4)
        .opacity(showsActions ? 1 : 0)
        .allowsHitTesting(showsActions)
        .accessibilityHidden(!showsActions)
        .animation(Theme.Motion.hover, value: showsActions)
    }

    /// The same menu for More and a right-click (ROW-05).
    @ViewBuilder
    private var menuItems: some View {
        MenuItem(title: "Open in Finder", icon: .symbol("folder"), action: openInFinder)
        MenuItem(title: "Copy Branch Name", icon: .symbol("doc.on.doc"), action: copyBranch)
        MenuDivider()
        MenuItem(title: "Remove Workspace…", icon: .symbol("archivebox"), isDestructive: true, action: onRemove)
    }

    /// The title and the state, then the stats when there are some (A11Y-01, GIT-03).
    private var accessibilityLabel: String {
        var label = "\(title), \(status.accessibilityName)"
        if let diffStat, !diffStat.isEmpty {
            label += ", \(diffStat.additions) lines added, \(diffStat.deletions) removed"
        }
        return label
    }

    /// Title; "branch · workspace name" (the name is otherwise only in the path); the failure in the error state
    /// (ROW-01).
    private var tooltip: String {
        var lines = [title, "\(workspace.branch) · \(workspace.name)"]
        if case .failed(let message) = status { lines.append(message) }
        return lines.joined(separator: "\n")
    }

    private func openInFinder() {
        _ = NSWorkspace.shared.open(URL(fileURLWithPath: workspace.path, isDirectory: true))
    }

    private func copyBranch() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(workspace.branch, forType: .string)
    }
}

/// The row's own look is drawn by `SidebarRow`: no pressed dimming (CUR-02 gives rows only hover and selection).
private struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// A workspace's state as one glyph (ROW-03, ROW-07): 14 points in a row, 12 in a folded repository's header (SB-04).
/// The state is carried by the shape as well as the color: dot with a halo, triangle, spinner, dot, pull request,
/// merge, branch (A11Y-01). The pull request glyphs are the SF Symbols the top bar's toggle (PNL-02) uses.
struct WorkspaceStatusGlyph: View {
    let status: WorkspaceStatus
    var size: CGFloat = 14

    var body: some View {
        switch status {
        case .needsYou:
            // An 8-point dot with a 3-point halo at 20 %.
            Circle()
                .fill(Theme.attention.opacity(0.2))
                .frame(width: Zoom.shared(14), height: Zoom.shared(14))
                .overlay {
                    Circle().fill(Theme.attention).frame(width: Zoom.shared(8), height: Zoom.shared(8))
                }
        case .failed:
            symbol("exclamationmark.triangle", color: Theme.danger)
        case .working:
            CircularProgress(size: size, tint: Theme.textPrimary)
        case .unread:
            Circle()
                .fill(Theme.accent)
                .frame(width: Zoom.shared(7), height: Zoom.shared(7))
        case .pullRequest(let tone):
            GitGlyph(kind: .pullRequest, size: size, color: tone.color)
        case .merged:
            GitGlyph(kind: .merge, size: size, color: Theme.merged)
        case .idle:
            GitGlyph(kind: .branch, size: size, color: Theme.textTertiary)
        }
    }

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: Zoom.shared(size), height: Zoom.shared(size))
    }
}

/// The label of an icon button that opens a Rocky menu (`MenuButton` draws a plain button, so the look is here):
/// `RockyIconButtonStyle`'s colors and fills, lit while its menu is open.
struct SidebarMenuIcon: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 22
    let isOpen: Bool
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(hovering || isOpen ? Theme.textPrimary : Theme.textSecondary)
            .frame(width: Zoom.shared(size), height: Zoom.shared(size))
            .background(
                isOpen ? Theme.fillPressed : hovering ? Theme.fillIconHover : Color.clear,
                in: RoundedRectangle(cornerRadius: size >= 28 ? 6 : size >= 22 ? 5 : 4)
            )
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
            .accessibilityLabel(label)
    }
}

extension WorkspaceStatus {
    /// What VoiceOver reads after a row's title (A11Y-01).
    var accessibilityName: String {
        switch self {
        case .needsYou: "Needs you"
        case .failed: "Error"
        case .working: "Working"
        case .unread: "Unread reply"
        case .pullRequest: "Pull request"
        case .merged: "Merged"
        case .idle: "Idle"
        }
    }
}

extension PullRequestTone {
    /// ROW-07: the glyph's color by the checks.
    var color: Color {
        switch self {
        case .passed: Theme.success
        case .running: Theme.attention
        case .failed: Theme.danger
        case .draft: Theme.textSecondary
        }
    }
}

/// The design's own git glyphs (ROW-03, ROW-07), drawn as template images so they take the state's color: a branch
/// (two commits and a fork), a pull request (two commits and a line coming back) and a merge (three joined commits).
/// SF Symbols' `arrow.triangle.branch`, `.pull` and `.merge` read alike at 14 points, so the rows differed only in
/// color (user report, 2026-09-24).
struct GitGlyph: View {
    enum Kind: String {
        case branch = "git-branch"
        case pullRequest = "git-pull-request"
        case merge = "git-merge"
    }

    let kind: Kind
    var size: CGFloat = 14
    var color: Color = Theme.textTertiary

    var body: some View {
        Image(nsImage: Self.image(for: kind))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(color)
            .frame(width: Zoom.shared(size), height: Zoom.shared(size))
            .accessibilityHidden(true)
    }

    private static var images: [Kind: NSImage] = [:]

    private static func image(for kind: Kind) -> NSImage {
        if let image = images[kind] { return image }
        let url = Bundle.module.url(forResource: kind.rawValue, withExtension: "svg", subdirectory: "Icons")
        let image = url.flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
            ?? NSImage()
        image.isTemplate = true
        images[kind] = image
        return image
    }
}
