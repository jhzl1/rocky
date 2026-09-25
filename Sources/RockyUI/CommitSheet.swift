import RockyKit
import SwiftUI

/// GIT-04's commit, opened from "Commit…" in the Changes tab's Uncommitted header: DLG-06's large mini-modal, 500 wide,
/// where it was a macOS sheet (user decision, 2026-09-25). "Commit changes"; the uncommitted files (status letter and
/// path, read-only); the subject, prefilled with the workspace's title, with a 72-character counter that turns
/// `attention` past 72; an optional description; then "git add -A, then git commit", Cancel and Commit (⌘Return, off
/// with an empty subject; Return in a field types a line). While git runs: "Running git commit…" and what git and the
/// hooks write, and neither Cancel, Esc nor a click outside closes it, as the commit cannot be taken back halfway. On
/// failure it stays open with that output and git's exit status (ERR-02). The state lives in the model
/// (`AppModel.commits`), so the dialog comes back as it was if its tab went away meanwhile.
@MainActor
enum CommitDialog {
    /// Git's convention for a subject line; past it the counter turns `attention`, and the commit still goes.
    static let subjectLimit = 72

    /// `close` runs once a commit worked; Cancel closes it through the call site's binding.
    static func make(model: AppModel, workspace: Workspace, close: @escaping @MainActor () -> Void) -> Dialog {
        // A dialog that comes back (its commit running or failed) shows the message it was given.
        let progress = model.commits[workspace.id]
        let title = model.title(for: workspace)
        let draft = CommitDraft(subject: progress?.subject ?? (title.isFallback ? "" : title.text), description: progress?.description ?? "")
        let workspaceId = workspace.id
        let isRunning = { model.commits[workspaceId]?.isRunning == true }
        return Dialog(
            title: "Commit changes",
            width: 500,
            content: { AnyView(CommitDialogBody(model: model, workspace: workspace, draft: draft)) },
            footnote: "git add -A, then git commit",
            hasTextFields: true,
            buttons: [
                .cancel(isEnabled: { !isRunning() }),
                DialogAction(
                    title: "Commit",
                    role: .primary,
                    help: "Commit (⌘Return)",
                    isEnabled: { !draft.isEmpty && !isRunning() },
                    dismisses: false
                ) {
                    let subject = draft.subject
                    let description = draft.description
                    Task {
                        if await model.commitChanges(workspaceId: workspaceId, subject: subject, description: description) {
                            close()
                        }
                    }
                },
            ]
        )
    }
}

/// The message being written, a reference: the dialog's fields edit it, and its Commit button reads it, live.
@MainActor
@Observable
final class CommitDraft {
    var subject: String
    var description: String

    init(subject: String, description: String) {
        self.subject = subject
        self.description = description
    }

    var isEmpty: Bool {
        subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The commit dialog's body, under its title: the files, the subject and its counter, the description, and git's output.
private struct CommitDialogBody: View {
    let model: AppModel
    let workspace: Workspace
    @Bindable var draft: CommitDraft
    @FocusState private var focus: Field?

    private enum Field {
        case subject, description
    }

    var body: some View {
        let progress = model.commits[workspace.id]
        let limit = CommitDialog.subjectLimit
        VStack(alignment: .leading, spacing: 12) {
            CommitSheetFiles(files: model.changes[workspace.id]?.uncommitted ?? [])
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Subject")
                TextField("Subject", text: $draft.subject, prompt: Text(""))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.rocky(13))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focus, equals: .subject)
                    .modifier(CommitFieldBox(isFocused: focus == .subject))
            }
            Text(verbatim: "\(draft.subject.count) / \(limit)")
                .font(.rocky(11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(draft.subject.count > limit ? Theme.attention : Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, -4)
                .accessibilityLabel("\(draft.subject.count) of \(limit) characters")
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Description (optional)")
                TextEditor(text: $draft.description)
                    .font(.rocky(13))
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .description)
                    .frame(height: Zoom.shared(64))
                    .modifier(CommitFieldBox(isFocused: focus == .description, horizontalPadding: 5, verticalPadding: 6))
                    .accessibilityLabel("Description")
            }
            if let progress {
                CommitOutputView(progress: progress)
            }
        }
        // After the dialog is in its window, or the focus does not take.
        .task { focus = .subject }
    }

    /// "Subject", "Description (optional)": 12 `textSecondary`.
    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.rocky(12))
            .foregroundStyle(Theme.textSecondary)
            .accessibilityHidden(true)
    }
}

/// The mock's text fields in the commit dialog: black at 20 % under a `hairline` border, radius 6, 7 × 10 padding; the
/// border turns `accent` at 55 % while the field has the keyboard.
private struct CommitFieldBox: ViewModifier {
    let isFocused: Bool
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 7

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Theme.accent.opacity(0.55) : Theme.hairline)
            }
    }
}

/// The files the commit takes, read-only: the status letter and the path (12.5), in a `hairline` box that scrolls past
/// 120 points. The model's current list, so a file the agent adds meanwhile shows too: `git add -A` takes it.
private struct CommitSheetFiles: View {
    let files: [FileDiff]

    private static let rowHeight: CGFloat = 20
    private static let maxHeight: CGFloat = 120

    var body: some View {
        let height = min(Zoom.shared(Self.maxHeight), CGFloat(files.count) * Zoom.shared(Self.rowHeight) + Zoom.shared(8))
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(files) { file in
                    HStack(spacing: 8) {
                        ChangeStatusLetter(status: file.status)
                        Text(verbatim: file.path)
                            .font(.rocky(12.5))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Zoom.shared(Self.rowHeight))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(file.path), \(file.status.accessibilityName)")
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: height)
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline)
        }
    }
}

/// While the commit runs, the spinner and "Running git commit…"; after a failure, git's exit status in `danger`
/// (ERR-02). Under either, what git and the hooks wrote, 11.5 mono, kept at its end as it grows, selectable.
private struct CommitOutputView: View {
    let progress: CommitProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure = progress.failure {
                Text(verbatim: failure)
                    .font(.rocky(12.5, weight: .medium))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                HStack(spacing: 8) {
                    CircularProgress(size: 12)
                    ShimmerText("Running git commit…")
                        .font(.rocky(12.5))
                }
            }
            if !progress.lines.isEmpty {
                ScrollView {
                    Text(verbatim: progress.lines.joined(separator: "\n"))
                        .font(.rocky(11.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: Zoom.shared(140))
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline)
                }
            }
        }
    }
}
