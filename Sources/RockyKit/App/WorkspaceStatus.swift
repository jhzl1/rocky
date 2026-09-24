import Foundation

/// The color of a workspace's pull request glyph in the sidebar (`ROW-07`), from its stored state.
public enum PullRequestTone: Hashable, Sendable {
    case passed, running, failed, draft

    /// The design's order: a draft, then a failed check or conflicts, then a check running or waiting, else passed.
    public init(_ stored: StoredPullRequest) {
        if stored.state == "DRAFT" {
            self = .draft
        } else if stored.checks.contains(where: { $0.state == .failed }) || stored.headerState == HeaderState.mergeConflicts.rawValue {
            self = .failed
        } else if stored.checks.contains(where: { $0.state == .running || $0.state == .pending }) {
            self = .running
        } else {
            self = .passed
        }
    }
}

/// A workspace's state in the sidebar (ROW-03, ROW-07): one glyph per row; when several apply, the first case wins.
public enum WorkspaceStatus: Equatable, Sendable {
    /// An agent waits on a permission or a question.
    case needsYou
    /// An agent stopped on an error, or the Setup script failed; the text is the row's tooltip.
    case failed(String)
    case working
    /// A turn ended while the workspace was not on screen (ROW-04).
    case unread
    /// The branch has an open or draft pull request (ROW-07), its glyph colored by the checks.
    case pullRequest(tone: PullRequestTone)
    /// Its pull request merged (ROW-07): the merged glyph and a dimmer title.
    case merged
    case idle

    /// `pullRequest` is the workspace's stored pull request state (`PR-07`), which other workspaces and a relaunch
    /// show; nil without one.
    public static func resolve(needsYou: Bool, failure: String?, working: Bool, unread: Bool, pullRequest: StoredPullRequest? = nil) -> WorkspaceStatus {
        if needsYou { return .needsYou }
        if let failure { return .failed(failure) }
        if working { return .working }
        if unread { return .unread }
        if let pullRequest {
            return pullRequest.state == "MERGED" ? .merged : .pullRequest(tone: PullRequestTone(pullRequest))
        }
        return .idle
    }

    /// For a repository folded in the sidebar (SB-04): the most urgent state among its workspaces.
    public static func mostUrgent(_ statuses: [WorkspaceStatus]) -> WorkspaceStatus {
        statuses.min { $0.rank < $1.rank } ?? .idle
    }

    private var rank: Int {
        switch self {
        case .needsYou: 0
        case .failed: 1
        case .working: 2
        case .unread: 3
        case .pullRequest: 4
        case .merged: 5
        case .idle: 6
        }
    }
}
