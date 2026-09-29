import Foundation

/// Files the message box attaches that Rocky wrote itself: a pasted image, a linked issue (`GHL-04`), a pull request
/// or a branch (`GHL-05`). Each goes in a folder of its own under `~/Library/Caches/Rocky/Pasted`, so two never
/// overwrite each other, and keeps the name its badge shows.
public enum PastedFiles {
    /// `~/Library/Caches/Rocky/Pasted`; nil when macOS gives no caches folder.
    public static func standardFolder() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Rocky/Pasted", isDirectory: true)
    }

    /// Writes `data` as `<folder>/<UUID>/<name>`. Blocking: call it off the main actor.
    public static func write(_ data: Data, named name: String, in folder: URL) throws -> URL {
        let own = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = own.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
}

/// `GHL-04`'s and `GHL-05`'s attachments (Decision 4, `KIT-14`): the exact Markdown of an issue, a pull request and a
/// branch, their file names, and what a file name or its first line says. The name's prefix is what the badge's mark
/// comes from (`[GITHUB]-`, `[GITHUB]-PR-`, `[BRANCH]-`), so the transcript and ↑'s history show it too; the first line
/// is the badge's tooltip and, for an issue, the workspace's name (`GHL-06`).
public enum LinkAttachments {
    /// What a file Rocky wrote for a link is, from its name alone.
    public enum Kind: Equatable, Sendable {
        case issue(Int)
        case pullRequest(Int)
        case branch
    }

    public static let issuePrefix = "[GITHUB]-"
    public static let pullRequestPrefix = "[GITHUB]-PR-"
    public static let branchPrefix = "[BRANCH]-"

    /// `[GITHUB]-154.md` is issue 154, `[GITHUB]-PR-131.md` pull request 131, `[BRANCH]-….md` a branch; any other
    /// name is no link. Only the last path component counts.
    public static func kind(ofPath path: String) -> Kind? {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".md") else { return nil }
        let stem = name.dropLast(".md".count)
        if stem.hasPrefix(pullRequestPrefix), let number = number(stem.dropFirst(pullRequestPrefix.count)) {
            return .pullRequest(number)
        }
        if stem.hasPrefix(issuePrefix), let number = number(stem.dropFirst(issuePrefix.count)) {
            return .issue(number)
        }
        if stem.hasPrefix(branchPrefix), stem.count > branchPrefix.count { return .branch }
        return nil
    }

    private static func number(_ digits: Substring) -> Int? {
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    // MARK: Documents

    /// `GHL-04`'s issue: `[GITHUB]-<n>.md`.
    public static func issue(_ issue: GitHubIssue) -> (fileName: String, markdown: String) {
        ("\(issuePrefix)\(issue.number).md", document(issue))
    }

    /// `GHL-05`'s pull request: `[GITHUB]-PR-<n>.md`, `GHL-04`'s format with its branch and whether it is a draft.
    public static func pullRequest(_ pullRequest: GitHubIssue) -> (fileName: String, markdown: String) {
        ("\(pullRequestPrefix)\(pullRequest.number).md", document(pullRequest))
    }

    /// `GHL-05`'s branch: `[BRANCH]-<name>.md`, "/" as "-", with its upstream and `commits`, the last ones `base` lacks
    /// (`GitBranchService.commits`), newest first, of `total` in all.
    public static func branch(
        name: String,
        upstream: String?,
        base: String,
        commits: [String],
        total: Int
    ) -> (fileName: String, markdown: String) {
        var lines = ["# \(name)", "", "- Upstream: \(upstream ?? "none")", "- Base: \(base)", "", "## Commits not in \(base) (\(total))", ""]
        if commits.isEmpty {
            lines.append("None: the branch has no commits of its own.")
        } else {
            lines += commits.map { "- \($0)" }
            let more = total - commits.count
            if more > 0 { lines += ["", "…and \(more) older \(more == 1 ? "commit" : "commits")."] }
        }
        return ("\(branchPrefix)\(name.replacingOccurrences(of: "/", with: "-")).md", lines.joined(separator: "\n") + "\n")
    }

    /// `GHL-04`'s format, for an issue and for a pull request. Lists with nothing in them are left out; a body GitHub
    /// wrote with CRLF line ends reads with LF.
    private static func document(_ item: GitHubIssue) -> String {
        var lines = ["# #\(item.number) \(item.title)", "", "- URL: \(item.url.absoluteString)", "- State: \(stateText(item))"]
        if let pullRequest = item.pullRequest {
            lines.append("- Branch: \(pullRequest.headRefName) → \(pullRequest.baseRefName)")
            if pullRequest.isDraft { lines.append("- Draft: yes") }
        }
        lines.append("- Author: @\(item.author), opened \(day(item.createdAt))")
        if !item.labels.isEmpty { lines.append("- Labels: \(item.labels.joined(separator: ", "))") }
        if !item.assignees.isEmpty { lines.append("- Assignees: \(item.assignees.map { "@\($0)" }.joined(separator: ", "))") }
        let body = cleaned(item.body)
        lines += ["", "## Description", "", body.isEmpty ? "No description provided." : body]
        if item.totalComments > 0 {
            lines += ["", "## Comments (\(item.totalComments))"]
            for comment in item.comments {
                lines += ["", "### @\(comment.author), \(day(comment.createdAt))", "", cleaned(comment.body)]
            }
            let more = item.totalComments - item.comments.count
            if more > 0 {
                lines += ["", "…and \(more) more \(more == 1 ? "comment" : "comments") on GitHub: \(item.url.absoluteString)"]
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "open", "merged", "closed", or a closed issue with its reason: "closed (not planned)".
    private static func stateText(_ item: GitHubIssue) -> String {
        guard item.state == .closed, let reason = item.stateReason, !reason.isEmpty else { return item.state.rawValue }
        return "closed (\(reason))"
    }

    /// The day in UTC, "2026-09-20", so the file reads the same wherever it is written.
    private static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    private static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Reading them back

    /// `GHL-06`: the number and title of a document's first line, "# #154 Refresh the button styles"; nil for text
    /// that does not start with one.
    public static func heading(of markdown: String) -> (number: Int, title: String)? {
        guard let line = firstLine(of: markdown), line.hasPrefix("# #") else { return nil }
        let rest = line.dropFirst(3)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard let number = Int(digits), rest.dropFirst(digits.count).first == " " else { return nil }
        let title = rest.dropFirst(digits.count + 1).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (number, title)
    }

    /// The badge's tooltip (Decision 4): a document's first line without its "# ", "#154 Refresh the button styles"
    /// or "feat/button-styles".
    public static func title(of markdown: String) -> String? {
        guard let line = firstLine(of: markdown), line.hasPrefix("# ") else { return nil }
        let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// `GHL-06`: "#212 Search ignores filters…", the name the first issue among a message's `attachments` gives its
    /// workspace, read from that file's first line; nil without an issue, or when its file is gone or holds no heading.
    /// Blocking: call it off the main actor.
    public static func issueTitle(attachments: [String]) -> String? {
        guard let path = firstIssue(in: attachments),
              let heading = heading(of: firstBytes(of: URL(fileURLWithPath: path))) else { return nil }
        return "#\(heading.number) \(heading.title)"
    }

    /// The first attachment that is an issue's file.
    public static func firstIssue(in attachments: [String]) -> String? {
        attachments.first { path in
            guard case .issue = kind(ofPath: path) else { return false }
            return true
        }
    }

    /// The tooltip of a file Rocky wrote for a link (`title(of:)`), read from the file. Blocking: it reads the file's
    /// first kilobyte.
    public static func title(ofFileAt url: URL) -> String? {
        title(of: firstBytes(of: url))
    }

    /// Writes a document where a pasted image goes (`PastedFiles`). Blocking.
    public static func write(_ document: (fileName: String, markdown: String), in folder: URL) throws -> URL {
        try PastedFiles.write(Data(document.markdown.utf8), named: document.fileName, in: folder)
    }

    private static func firstLine(of text: String) -> String? {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Enough of the file for its first line: a title is far shorter.
    private static func firstBytes(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 1024)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
