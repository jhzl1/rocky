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

/// WSC-02, WSC-06: where a workspace whose worktree does not exist yet stands. Kept in memory only (`AppModel.creations`).
public enum WorkspaceCreation: Equatable, Sendable {
    /// WSC-04: git runs: the fetch, then the checkout.
    case creating
    /// WSC-06: git failed, or there was no base to create from: git's message.
    case failed(String)
}

/// WSC-07: where a workspace being removed stands, from its confirmation until it leaves or comes back. Kept in memory
/// only (`AppModel.removals`).
public enum WorkspaceRemoval: Equatable, Sendable {
    /// Its archive script runs, visibly: the workspace stays on screen, its agents stopped and its message box off.
    case archiving
    /// Off screen: nothing reads it any more, and git removes its worktree, then the branch rule and the store run.
    case removing
}

/// A workspace's state in the sidebar (ROW-03, ROW-07): one glyph per row; when several apply, the first case wins.
/// The texts are the row's tooltip.
public enum WorkspaceStatus: Equatable, Sendable {
    /// WSC-07: its archive script runs (`archivingText`), or git removes it (`removingText`); nothing else can apply.
    case removing(String)
    /// WSC-02: git makes its worktree (`creatingText`); nothing else can apply yet.
    case creating(String)
    /// WSC-06: its worktree could not be made (`creationFailedText`).
    case creationFailed(String)
    /// An agent waits on a permission or a question.
    case needsYou
    /// An agent stopped on an error, or the Setup script failed; the text is the row's tooltip.
    case failed(String)
    case working
    /// WSC-02, WSC-05: its Setup tab runs the post-checkout hook or the Setup script (`settingUpText`).
    case settingUp(String)
    /// A turn ended while the workspace was not on screen (ROW-04).
    case unread
    /// The branch has an open or draft pull request (ROW-07), its glyph colored by the checks.
    case pullRequest(tone: PullRequestTone)
    /// Its pull request merged (ROW-07): the merged glyph and a dimmer title.
    case merged
    case idle

    /// `pullRequest` is the workspace's stored pull request state (`PR-07`), which other workspaces and a relaunch
    /// show; nil without one. `removing`, `creating`, `creationFailure` and `settingUp` are their states' tooltips
    /// (WSC-02, WSC-07).
    public static func resolve(
        removing: String? = nil,
        creating: String? = nil,
        creationFailure: String? = nil,
        needsYou: Bool,
        failure: String?,
        working: Bool,
        settingUp: String? = nil,
        unread: Bool,
        pullRequest: StoredPullRequest? = nil
    ) -> WorkspaceStatus {
        if let removing { return .removing(removing) }
        if let creating { return .creating(creating) }
        if let creationFailure { return .creationFailed(creationFailure) }
        if needsYou { return .needsYou }
        if let failure { return .failed(failure) }
        if working { return .working }
        if let settingUp { return .settingUp(settingUp) }
        if unread { return .unread }
        if let pullRequest {
            return pullRequest.state == "MERGED" ? .merged : .pullRequest(tone: PullRequestTone(pullRequest))
        }
        return .idle
    }

    /// WSC-07: "Running manila's archive script", while the workspace is still on screen.
    public static func archivingText(name: String) -> String {
        "Running \(name)'s archive script"
    }

    /// WSC-07: "Removing manila…", while git removes the worktree off screen.
    public static func removingText(name: String) -> String {
        "Removing \(name)…"
    }

    /// WSC-02: "Creating lima: fetching origin and checking out rocky/lima".
    public static func creatingText(name: String, branch: String) -> String {
        "Creating \(name): fetching origin and checking out \(branch)"
    }

    /// WSC-02: "Couldn't create lima: " and git's first line that says what went wrong: its first "fatal:" or "error:"
    /// line, since `worktree add` writes "Preparing worktree (new branch 'rocky/lima')" before it; else its last line.
    public static func creationFailedText(name: String, message: String) -> String {
        let lines = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let reason = lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.last ?? message
        return "Couldn't create \(name): \(reason)"
    }

    /// WSC-02: "Setting up lima: the post-checkout hook", or "…: the Setup script"; the name alone while the step is
    /// not known yet (the hook is still being looked for).
    public static func settingUpText(name: String, step: SetupSteps.Step?) -> String {
        switch step {
        case .hook: "Setting up \(name): the post-checkout hook"
        case .script: "Setting up \(name): the Setup script"
        case nil: "Setting up \(name)"
        }
    }

    /// For a repository folded in the sidebar (SB-04): the most urgent state among its workspaces.
    public static func mostUrgent(_ statuses: [WorkspaceStatus]) -> WorkspaceStatus {
        statuses.min { $0.rank < $1.rank } ?? .idle
    }

    private var rank: Int {
        switch self {
        case .removing: 0
        case .creating: 1
        case .creationFailed: 2
        case .needsYou: 3
        case .failed: 4
        case .working: 5
        case .settingUp: 6
        case .unread: 7
        case .pullRequest: 8
        case .merged: 9
        case .idle: 10
        }
    }
}
