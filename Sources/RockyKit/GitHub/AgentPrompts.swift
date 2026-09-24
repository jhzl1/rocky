import Foundation

/// The prompts the panel's agent actions send to the workspace's selected conversation (`AGT-00`), as if the user
/// typed them. Each has its requirement's exact text; `base` is the base branch's name (`development`), which the
/// requirements' examples show.
enum AgentPrompts {
    /// `AGT-01`. "Create draft PR" is the same text with `--draft`.
    static func createPullRequest(base: String, draft: Bool) -> String {
        let command = draft ? "gh pr create --base \(base) --draft" : "gh pr create --base \(base)"
        return "Create a pull request for this branch. First commit any uncommitted changes and push with "
            + "`git push -u origin HEAD`. Then run `\(command)` with a title under 80 characters and a description of "
            + "at most five sentences. If the repository has a pull request template, fill it in."
    }

    /// `AGT-02`.
    static func commitAndPush() -> String {
        "Commit and push all changes."
    }

    /// `AGT-03`. `notes` are the checks without a log, one line each (`checkNote`), after a blank line.
    static func fixFailingChecks(notes: [String]) -> String {
        let request = "Fix the failing CI actions. I've attached the failure logs."
        guard !notes.isEmpty else { return request }
        return request + "\n\n" + notes.joined(separator: "\n")
    }

    /// One of `AGT-03`'s lines for a check without a log: "<check name>: <annotation message>" for a job that never
    /// started, "<check name>: <url>" for another CI system. Kept on one line.
    static func checkNote(name: String, detail: String) -> String {
        let flat = detail.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "\(name): \(flat)"
    }

    /// `AGT-04`, by the worktree's `git config pull.rebase`.
    static func resolveConflicts(base: String, rebase: Bool) -> String {
        rebase
            ? "Rebase your branch onto the remote branch (origin/\(base)) and resolve the conflicts. Then push with `git push --force-with-lease`."
            : "Merge the remote branch (origin/\(base)) into your branch and resolve the conflicts. Then commit and push your changes."
    }

    /// `AGT-06`.
    static func resolveIncompatibility() -> String {
        "Resolve branch incompatibility with remote."
    }

    /// `AGT-05`: numbered items, each quoted with "> " on every line; a thread's replies follow its first comment as
    /// "> login: text" (Open question 8).
    static func reviewComments(number: Int, comments: [PendingComment]) -> String {
        var sections = ["Review comments on pull request #\(number):"]
        for (index, comment) in comments.enumerated() {
            var lines = ["\(index + 1). \(heading(of: comment))"]
            lines += quoted(comment.body)
            for reply in comment.replies {
                lines += quoted("\(reply.author): \(reply.body)")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        sections.append("Address each comment and say what you changed for each number.")
        return sections.joined(separator: "\n\n")
    }

    /// `GST-02`'s first step: uncommitted changes go to the agent before the base comes in.
    static func commitThenBringInBase(base: String) -> String {
        "Commit your changes, then bring in origin/\(base) and push."
    }

    /// `GST-02`'s diverged step, by the worktree's `git config pull.rebase`. Rocky never merges or force-pushes itself.
    static func bringInBase(base: String, rebase: Bool) -> String {
        rebase
            ? "Rebase this branch onto origin/\(base). Then push --force-with-lease."
            : "Merge origin/\(base) into this branch. Then push."
    }

    /// "ana on src/ocr/retry.ts, line 42", "ana on src/ocr/retry.ts" for a comment on the whole file,
    /// "ana (conversation)", "ana (review)".
    private static func heading(of comment: PendingComment) -> String {
        switch comment.kind {
        case .conversation:
            return "\(comment.author) (conversation)"
        case .review:
            return "\(comment.author) (review)"
        case .thread:
            guard let path = comment.path else { return comment.author }
            guard let line = comment.line else { return "\(comment.author) on \(path)" }
            return "\(comment.author) on \(path), line \(line)"
        }
    }

    /// Every line of `text` after "> ". GitHub's bodies end lines with "\r\n", one `Character` that `isNewline`.
    private static func quoted(_ text: String) -> [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { "> \($0)" }
    }
}
