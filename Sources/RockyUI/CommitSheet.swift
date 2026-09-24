import RockyKit
import SwiftUI

/// GIT-04's sheet, opened from "Commit…" in the Changes tab's Uncommitted header: a macOS sheet, which slides from the
/// top of the window, 500 wide on `panel`. "Commit changes"; the uncommitted files (status letter and path,
/// read-only); the subject, prefilled with the workspace's title, with a 72-character counter that turns `attention`
/// past 72; an optional description; then "git add -A, then git commit", Cancel and Commit (⌘Return, off with an empty
/// subject). While git runs: "Running git commit…" and what git and the hooks write. On failure the sheet stays open
/// with that output and git's exit status (ERR-02). The state lives in the model (`AppModel.commits`), so the sheet
/// comes back as it was if its tab went away meanwhile.
struct CommitSheet: View {
    let model: AppModel
    let workspace: Workspace
    /// Closes the sheet: Cancel, Esc, or a commit that worked.
    let close: () -> Void
    @State private var subject: String
    @State private var description: String
    @FocusState private var focus: Field?

    private enum Field {
        case subject, description
    }

    /// Git's convention for a subject line; past it the counter turns `attention`, and the commit still goes.
    static let subjectLimit = 72

    init(model: AppModel, workspace: Workspace, close: @escaping () -> Void) {
        self.model = model
        self.workspace = workspace
        self.close = close
        // A sheet that comes back (its commit running or failed) shows the message it was given.
        let progress = model.commits[workspace.id]
        let title = model.title(for: workspace)
        _subject = State(initialValue: progress?.subject ?? (title.isFallback ? "" : title.text))
        _description = State(initialValue: progress?.description ?? "")
    }

    var body: some View {
        let progress = model.commits[workspace.id]
        let isRunning = progress?.isRunning == true
        let isEmpty = subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Commit changes")
                    .font(.rocky(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                CommitSheetFiles(files: model.changes[workspace.id]?.uncommitted ?? [])
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Subject")
                    TextField("Subject", text: $subject, prompt: Text(""))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.rocky(13))
                        .foregroundStyle(Theme.textPrimary)
                        .focused($focus, equals: .subject)
                        .modifier(CommitFieldBox(isFocused: focus == .subject))
                }
                Text(verbatim: "\(subject.count) / \(Self.subjectLimit)")
                    .font(.rocky(11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(subject.count > Self.subjectLimit ? Theme.attention : Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, -4)
                    .accessibilityLabel("\(subject.count) of \(Self.subjectLimit) characters")
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Description (optional)")
                    TextEditor(text: $description)
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
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)
            HStack(spacing: 8) {
                Text("git add -A, then git commit")
                    .font(.rocky(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // Esc is Cancel's; while git runs neither closes the sheet, as the commit cannot be taken back halfway.
                Button("Cancel", action: close)
                    .font(.rocky(12.5))
                    .buttonStyle(RockyTextButtonStyle(height: 26))
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRunning)
                Button("Commit", action: commit)
                    .font(.rocky(12.5, weight: .medium))
                    .buttonStyle(RockyPrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isEmpty || isRunning)
                    .help("Commit (⌘Return)")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .frame(width: Zoom.shared(500))
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isRunning)
        // After the sheet is in its window, or the focus does not take.
        .task { focus = .subject }
    }

    /// "Subject", "Description (optional)": 12 `textSecondary`.
    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.rocky(12))
            .foregroundStyle(Theme.textSecondary)
            .accessibilityHidden(true)
    }

    private func commit() {
        let model = self.model
        let workspaceId = workspace.id
        let subject = self.subject
        let description = self.description
        Task {
            if await model.commitChanges(workspaceId: workspaceId, subject: subject, description: description) {
                close()
            }
        }
    }
}

/// The mock's text fields in a sheet: black at 20 % under a `hairline` border, radius 6, 7 × 10 padding; the border
/// turns `accent` at 55 % while the field has the keyboard.
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
