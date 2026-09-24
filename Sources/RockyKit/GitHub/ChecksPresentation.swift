import Foundation

/// One row of `GST-01`'s Git status, in the table's order. The Checks tab draws them; which rows show is decided here.
public struct GitStatusRow: Equatable, Sendable {
    /// The row's dot.
    public enum Tone: Sendable {
        case danger, attention, muted, success, merged
    }

    /// The row's ghost action; `none` for a row that only informs.
    public enum Action: Sendable {
        case none, resolveConflicts, resolveIncompatible, commitAndPush, pull, push, pullFromBase, createPR,
             readyForReview, addAllComments, merge
    }

    public var text: String
    public var tone: Tone
    public var action: Action

    public init(text: String, tone: Tone, action: Action = .none) {
        self.text = text
        self.tone = tone
        self.action = action
    }

    /// `GST-01`'s rows for the branch. A merged pull request shows only "Merged into <base>"; with none of the rows,
    /// "Up to date with <base>". Incompatible hides behind and ahead, so Pull means behind only and Push ahead only
    /// (Open question 4). `baseBehindBy` is GitHub's compare (`PR-01`), `base` the name every row says.
    public static func rows(pr: PullRequestInfo?, local: LocalGitStatus?, baseBehindBy: Int?, base: String) -> [GitStatusRow] {
        if let pr, pr.isMerged {
            return [GitStatusRow(text: "Merged into \(base)", tone: .merged)]
        }
        var rows: [GitStatusRow] = []
        if let pr, pr.mergeable == "CONFLICTING" || pr.mergeStateStatus == "DIRTY" {
            rows.append(GitStatusRow(text: "Merge conflicts detected", tone: .danger, action: .resolveConflicts))
        }
        if let local {
            if local.isIncompatible {
                rows.append(GitStatusRow(text: "Incompatible with remote", tone: .danger, action: .resolveIncompatible))
            }
            if local.uncommitted > 0 {
                let noun = local.uncommitted == 1 ? "uncommitted change" : "uncommitted changes"
                rows.append(GitStatusRow(text: "\(local.uncommitted) \(noun)", tone: .attention, action: .commitAndPush))
            }
            if !local.isIncompatible, local.behind > 0 {
                rows.append(GitStatusRow(text: "\(PullRequestHeader.commits(local.behind)) behind remote", tone: .attention, action: .pull))
            }
            if !local.isIncompatible, local.ahead > 0 {
                rows.append(GitStatusRow(text: "\(PullRequestHeader.commits(local.ahead)) ahead of remote", tone: .attention, action: .push))
            }
        }
        if let baseBehindBy, baseBehindBy > 0 {
            rows.append(GitStatusRow(text: "\(PullRequestHeader.commits(baseBehindBy)) behind \(base)", tone: .attention, action: .pullFromBase))
        }
        guard let pr else {
            rows.append(GitStatusRow(text: "No PR open", tone: .muted, action: .createPR))
            return rows
        }
        if pr.isDraft {
            rows.append(GitStatusRow(text: "PR is in draft", tone: .muted, action: .readyForReview))
        }
        if pr.reviewDecision == "REVIEW_REQUIRED", !pr.isDraft, pr.mergeStateStatus == "BLOCKED" {
            rows.append(GitStatusRow(text: "Waiting for PR review", tone: .muted))
        }
        if pr.reviewDecision == "CHANGES_REQUESTED" {
            rows.append(GitStatusRow(text: "PR changes requested", tone: .danger, action: .addAllComments))
        }
        if PullRequestHeader.state(pr: pr, local: local, agentWorking: false) == .readyToMerge {
            rows.append(GitStatusRow(text: "Ready to merge", tone: .success, action: .merge))
        }
        if rows.isEmpty {
            rows.append(GitStatusRow(text: "Up to date with \(base)", tone: .success))
        }
        return rows
    }
}

/// `DEP-01`'s icon for a deployment, and the word its tooltip says.
public enum DeploymentStatus: Sendable {
    case deployed, failed, deploying, queued, inactive

    /// A deployment status's state, or a deployment's own state when it has no status yet: its success is ACTIVE.
    public init(state: String) {
        switch state {
        case "SUCCESS", "ACTIVE": self = .deployed
        case "FAILURE", "ERROR": self = .failed
        case "IN_PROGRESS": self = .deploying
        case "QUEUED", "PENDING", "WAITING": self = .queued
        default: self = .inactive
        }
    }

    public var word: String {
        switch self {
        case .deployed: "Deployed"
        case .failed: "Failed"
        case .deploying: "Deploying"
        case .queued: "Queued"
        case .inactive: "Inactive"
        }
    }
}

extension PullRequestDeployment {
    public var status: DeploymentStatus {
        DeploymentStatus(state: state)
    }

    /// `DEP-01`: Vercel's mark for a `.vercel.app` URL, GitHub's for the rest.
    public var isVercel: Bool {
        url?.host?.lowercased().hasSuffix(".vercel.app") == true
    }

    /// The `.vercel.app` URL's slug ("celes-web-git-invoice"), else the environment ("Preview").
    public var displayName: String {
        if let host = url?.host?.lowercased(), host.hasSuffix(".vercel.app") {
            let slug = host.dropLast(".vercel.app".count)
            if !slug.isEmpty, !slug.contains(".") { return String(slug) }
        }
        return environment
    }
}

extension PullRequestCheck {
    /// `CHK-01`: Vercel's mark when the URL mentions Vercel, else GitHub's.
    public var isVercel: Bool {
        url?.absoluteString.localizedCaseInsensitiveContains("vercel") == true
    }
}

extension PullRequestInfo {
    /// Open question 6: "View checks" opens the pull request's checks page.
    public var checksURL: URL {
        url.appendingPathComponent("checks")
    }

    /// `CHK-02`: the workflow runs of the failed check runs, each once, in the checks' order. Status contexts of other
    /// CI systems have none, so Re-run leaves them alone.
    public var failedWorkflowRunIds: [Int] {
        var seen: Set<Int> = []
        return checks
            .filter { $0.state == .failed && $0.checkRunId != nil }
            .compactMap(\.workflowRunId)
            .filter { seen.insert($0).inserted }
    }
}

extension MergeMethod {
    /// `PR-05`'s button: "Squash", "Merge", "Rebase".
    public var buttonTitle: String {
        switch self {
        case .squash: "Squash"
        case .rebase: "Rebase"
        case .merge: "Merge"
        }
    }

    /// The button during `PR-05`'s 4-second confirmation.
    public var confirmTitle: String {
        "Confirm \(buttonTitle.lowercased())"
    }

    /// The method's menu item.
    public var menuTitle: String {
        switch self {
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        case .merge: "Create a merge commit"
        }
    }

    /// The menu item's second line, naming the base.
    public func menuDetail(base: String) -> String {
        switch self {
        case .squash: "Combine all commits into one commit on \(base)"
        case .rebase: "Replay each commit onto \(base), no merge commit"
        case .merge: "Keep every commit and add a merge commit"
        }
    }

    /// The button's tooltip: "Squash and merge into development".
    public func tooltip(base: String) -> String {
        "\(menuTitle) into \(base)"
    }
}

extension PendingComment {
    /// `REV-01`'s location column: "src/ocr/retry.ts:42" for a thread ("README.md" on the whole file), "review" for a
    /// review body, else the comment's first 50 characters on one line.
    public var rowLocation: String {
        switch kind {
        case .thread:
            guard let path else { return "" }
            return line.map { "\(path):\($0)" } ?? path
        case .review:
            return "review"
        case .conversation:
            let oneLine = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return String(oneLine.prefix(50))
        }
    }

    /// The avatar's initials (Rocky loads no remote images): the login's first two characters, uppercased.
    public var initials: String {
        String(author.prefix(2)).uppercased()
    }
}

/// `PR-07`'s footer times: "12s ago", "5m ago", "2h ago", "3d ago"; never less than a second.
public enum RelativeAge {
    public static func text(since date: Date, now: Date) -> String {
        let seconds = max(1, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

/// The pull request the header's pill names (`HDR-03`). The top bar's toggle, which also showed whether it was merged
/// and its checks, is a plain panel toggle since LAY-01 (`PNL-02`).
public struct PullRequestReference: Equatable, Sendable {
    public var number: Int
    public var url: URL

    public init(number: Int, url: URL) {
        self.number = number
        self.url = url
    }
}

extension PullRequestPanelState {
    /// This launch's snapshot, else the stored state (`PR-07`), so the header's pill (`HDR-03`) names the pull request
    /// before the first refresh. nil once a snapshot says the branch has none.
    public var shownPullRequest: PullRequestReference? {
        if let snapshot {
            return snapshot.pullRequest.map {
                PullRequestReference(number: $0.number, url: $0.url)
            }
        }
        return stored.map {
            PullRequestReference(number: $0.number, url: $0.url)
        }
    }

    /// `PR-07`'s footer: "jhzl1 · Updated 12s ago", "jhzl1 · No pull request", offline "jhzl1 · No internet connection
    /// · updated 5m ago". The login is the repository's account (`ACC-01`); before the first refresh, only it shows.
    public func footerText(now: Date) -> String {
        var parts: [String] = []
        if let login { parts.append(login) }
        if error == .offline {
            parts.append("No internet connection")
            if let updatedAt { parts.append("updated \(RelativeAge.text(since: updatedAt, now: now))") }
        } else if let snapshot {
            if snapshot.pullRequest == nil {
                parts.append("No pull request")
            } else if let updatedAt {
                parts.append("Updated \(RelativeAge.text(since: updatedAt, now: now))")
            }
        }
        return parts.joined(separator: " · ")
    }
}
