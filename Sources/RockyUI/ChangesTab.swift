import AppKit
import RockyKit
import SwiftUI

/// The Changes tab of the right panel (CHG-02): a 30-point row with the file count, the totals and "⋯", then the
/// files in their Uncommitted and Committed sections (CHG-03), which scroll under that row. The model computes the diff
/// only while this tab shows (GIT-01), so nothing shows until its first reading.
struct ChangesTab: View {
    let model: AppModel
    let workspace: Workspace
    /// GIT-05's confirmation, for one file or for every uncommitted one.
    @State private var discardRequest: DiscardRequest?
    /// GIT-04's commit dialog (DLG-06), opened by "Commit…". It also shows while the model holds a commit for the
    /// workspace (running, or failed until closed), so it comes back with the tab if the tab went away meanwhile.
    @State private var showsCommitSheet = false

    private struct DiscardRequest: Equatable {
        let paths: [String]
        let title: String
        let button: String
    }

    var body: some View {
        let changes = model.changes[workspace.id]
        VStack(spacing: 0) {
            if let changes, !changes.files.isEmpty {
                ChangesHeadRow(
                    workspaceId: workspace.id,
                    changes: changes,
                    refresh: { Task { await model.refreshChanges(workspaceId: workspace.id) } },
                    discardAll: { askToDiscard(changes.uncommitted) }
                )
            }
            // ERR-02: where the action was, under the tab's row.
            if let failure = model.changesFailures[workspace.id] {
                ChangesFailureLine(failure: failure) { model.dismissChangesFailure(workspaceId: workspace.id) }
            }
            ScrollView {
                if let changes {
                    if changes.files.isEmpty {
                        ChangesEmptyState()
                    } else {
                        fileList(changes)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .rockyDialog(item: $discardRequest) { request in
            let model = self.model
            let workspaceId = workspace.id
            return Dialog(
                title: request.title,
                message: "This cannot be undone.",
                buttons: [
                    .cancel(),
                    .destructive(request.button) {
                        Task { await model.discardChanges(workspaceId: workspaceId, paths: request.paths) }
                    },
                ]
            )
        }
        // DLG-06: the commit's large mini-modal.
        .rockyDialog(isPresented: Binding(
            get: { showsCommitSheet || model.commits[workspace.id] != nil },
            set: { shown in if !shown { closeCommitSheet() } }
        )) {
            CommitDialog.make(model: model, workspace: workspace, close: closeCommitSheet)
        }
    }

    /// Cancel, Esc or a commit that worked: the dialog goes, with a failure it showed. A commit still running keeps it.
    private func closeCommitSheet() {
        showsCommitSheet = false
        model.dismissCommit(workspaceId: workspace.id)
    }

    /// CHG-03: Uncommitted first (a file with both kinds of change is there), then Committed. Fixed 28-point rows, so a
    /// lazy stack never guesses a height.
    private func fileList(_ changes: WorkspaceChanges) -> some View {
        let uncommitted = changes.uncommitted
        let committed = changes.committed
        let selected = model.selectedChangedFile(workspaceId: workspace.id)
        return LazyVStack(alignment: .leading, spacing: 0) {
            if !uncommitted.isEmpty {
                // GIT-04: Rocky's own commit, without the agent (M2.7's "Commit and push" asks the agent).
                ChangesSectionHeader(title: "Uncommitted", count: uncommitted.count, commit: { showsCommitSheet = true })
                ForEach(uncommitted) { file in
                    row(file, isSelected: file.path == selected)
                }
            }
            if !committed.isEmpty {
                ChangesSectionHeader(title: "Committed", count: committed.count)
                    .padding(.top, uncommitted.isEmpty ? 0 : 6)
                ForEach(committed) { file in
                    row(file, isSelected: file.path == selected)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func row(_ file: FileDiff, isSelected: Bool) -> some View {
        ChangedFileRow(
            file: file,
            isSelected: isSelected,
            // CHG-03: the click selects the file's diff tab as it was left; Edit opens it on the editor (EDIT-01).
            open: { model.openDiff(workspaceId: workspace.id, path: file.path) },
            edit: { model.openDiff(workspaceId: workspace.id, path: file.path, mode: .edit) },
            discard: { askToDiscard([file]) }
        )
    }

    /// GIT-05: "Discard changes to openapi.ts? This cannot be undone." Only uncommitted files can be discarded.
    private func askToDiscard(_ files: [FileDiff]) {
        let uncommitted = files.filter(\.isUncommitted)
        guard let first = uncommitted.first else { return }
        if uncommitted.count == 1 {
            let name = (first.path as NSString).lastPathComponent
            discardRequest = DiscardRequest(paths: [first.path], title: "Discard changes to \(name)?", button: "Discard Changes")
        } else {
            discardRequest = DiscardRequest(
                paths: uncommitted.map(\.path),
                title: "Discard the uncommitted changes of \(uncommitted.count) files?",
                button: "Discard All"
            )
        }
    }
}

/// CHG-02's 30-point row: "5 files" (12 `textSecondary`), the total `+A −D`, and "⋯" with Refresh and Discard All
/// Uncommitted Changes…. The menu has no icons, so it has no icon column.
private struct ChangesHeadRow: View {
    let workspaceId: String
    let changes: WorkspaceChanges
    let refresh: () -> Void
    let discardAll: () -> Void

    var body: some View {
        let count = changes.files.count
        let hasUncommitted = changes.files.contains(where: \.isUncommitted)
        HStack(spacing: 8) {
            Text("\(count) \(count == 1 ? "file" : "files")")
                .font(.rocky(12))
                .foregroundStyle(Theme.textSecondary)
            DiffStatLabel(stat: changes.stat)
            Spacer(minLength: 0)
            MenuButton(id: "changes-more-\(workspaceId)", placement: .belowTrailing, width: 260) { isOpen in
                SidebarMenuIcon(systemImage: "ellipsis", label: "More", isOpen: isOpen)
            } content: {
                MenuItem(title: "Refresh", action: refresh)
                MenuDivider()
                MenuItem(
                    title: "Discard All Uncommitted Changes…",
                    isDestructive: true,
                    disabledReason: hasUncommitted ? nil : "No uncommitted changes",
                    action: discardAll
                )
            }
            .help("More")
        }
        .font(.rocky(12))
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: Zoom.shared(30))
    }
}

/// CHG-03's section header: "UNCOMMITTED · 3", 10.5 uppercase `textTertiary`, 28 points. The Uncommitted one ends with
/// GIT-04's "Commit…": a filled button, 22 high, 11.5 medium, not uppercase.
private struct ChangesSectionHeader: View {
    let title: String
    let count: Int
    var commit: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(title) · \(count)")
                .textCase(.uppercase)
                .font(.rocky(10.5))
                .tracking(Zoom.shared(10.5 * 0.07))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let commit {
                Button("Commit…", action: commit)
                    .font(.rocky(11.5, weight: .medium))
                    .buttonStyle(RockyFilledButtonStyle(height: 22, horizontalPadding: 8))
                    .help("Commit the uncommitted changes")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Zoom.shared(28))
    }
}

/// CHG-03's row: 28 points, radius 7; the status letter, the file's Material icon (FIL-09, 14 points), the name (13),
/// its folder (11 `textTertiary`, cut at its start), then `+a −d`. On hover, Edit and, for uncommitted files, Discard
/// take its place. Selected, its tab on screen: `fillSelected`. Comments go to a conversation as they are written
/// (CMT-05), so a row counts none.
private struct ChangedFileRow: View {
    let file: FileDiff
    let isSelected: Bool
    let open: () -> Void
    let edit: () -> Void
    let discard: () -> Void
    @State private var hovering = false

    private var canEdit: Bool { file.status != .deleted }

    /// `+a −d` stays while there is no action to take its place.
    private var showsActions: Bool { hovering && (canEdit || file.isUncommitted) }

    private var name: String { (file.path as NSString).lastPathComponent }

    /// "src/api/", with its slash, as the mock prints it; empty at the worktree's root.
    private var folder: String {
        let parent = (file.path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : parent + "/"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                ChangeStatusLetter(status: file.status)
                FileIcon(path: file.path, size: 14)
                Text(verbatim: name)
                    .font(.rocky(13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(verbatim: folder)
                    .font(.rocky(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DiffStatLabel(stat: DiffStat(additions: file.additions, deletions: file.deletions))
                    .opacity(showsActions ? 0 : 1)
            }
            .padding(.horizontal, 8)
            .frame(height: Zoom.shared(28))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .background(
            isSelected ? Theme.fillSelected : hovering ? Theme.fillHover : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(alignment: .trailing) {
            actions
        }
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(file.status.accessibilityName)\(folder.isEmpty ? "" : ", in \(folder)")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, open)
        .accessibilityActions {
            if canEdit { Button("Edit", action: edit) }
            if file.isUncommitted { Button("Discard Changes…", action: discard) }
        }
    }

    /// GIT-05's `arrow.uturn.backward` only for uncommitted files: committed changes are never discarded from Rocky.
    private var actions: some View {
        HStack(spacing: 2) {
            if canEdit {
                Button("Edit", systemImage: "pencil", action: edit)
                    .buttonStyle(RockyIconButtonStyle(size: 22))
                    .help("Edit")
            }
            if file.isUncommitted {
                Button("Discard changes", systemImage: "arrow.uturn.backward", action: discard)
                    .buttonStyle(RockyIconButtonStyle(size: 22))
                    .help("Discard changes…")
            }
        }
        .font(.rocky(12))
        .padding(.trailing, 4)
        .opacity(showsActions ? 1 : 0)
        .allowsHitTesting(showsActions)
        .accessibilityHidden(true)
    }

    private var tooltip: String {
        if let oldPath = file.oldPath { return "\(oldPath) → \(file.path)" }
        return file.path
    }
}

/// CHG-03's empty state.
private struct ChangesEmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("No changes yet")
                .font(.rocky(13))
                .foregroundStyle(Theme.textSecondary)
            Text("Changes the agent makes in this workspace show up here.")
                .font(.rocky(12))
                .foregroundStyle(Theme.textTertiary)
                .lineSpacing(Zoom.shared(3))
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}

/// ERR-02 in the Changes tab: git's last lines (12, `danger`, selectable), with × to hide them.
private struct ChangesFailureLine: View {
    let failure: ChangesFailure
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: failure.message)
                .font(.rocky(12))
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .font(.rocky(10, weight: .semibold))
                .buttonStyle(RockyIconButtonStyle(size: 22))
                .help("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `+A −D` (GIT-03, CHG-02, CHG-03): 11 mono with tabular digits, `+A` in `success` and `−D` in `diffDeletions`,
/// thousands as "2.3k".
struct DiffStatLabel: View {
    let stat: DiffStat

    var body: some View {
        let added = Text(verbatim: "+\(DiffStat.abbreviated(stat.additions))").foregroundStyle(Theme.success)
        let removed = Text(verbatim: "−\(DiffStat.abbreviated(stat.deletions))").foregroundStyle(Theme.diffDeletions)
        Text("\(added) \(removed)")
            .font(.rocky(11, design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("\(stat.additions) lines added, \(stat.deletions) removed")
    }
}

/// CHG-03's status letter: A `success`, M `attention`, D `danger`, R `textSecondary`; 11 mono semibold in a 14-point
/// column. Diff tabs show it in place of the file icon (DIFF-01).
struct ChangeStatusLetter: View {
    let status: FileDiff.Status

    var body: some View {
        Text(verbatim: status.letter)
            .font(.rocky(11, weight: .semibold, design: .monospaced))
            .foregroundStyle(status.letterColor)
            .frame(width: Zoom.shared(14))
            .accessibilityHidden(true)
    }
}

extension FileDiff.Status {
    var letterColor: Color {
        switch self {
        case .added: Theme.success
        case .modified: Theme.attention
        case .deleted: Theme.danger
        case .renamed: Theme.textSecondary
        }
    }

    /// What VoiceOver reads after the file's name.
    var accessibilityName: String {
        switch self {
        case .added: "added"
        case .modified: "modified"
        case .deleted: "deleted"
        case .renamed: "renamed"
        }
    }
}
