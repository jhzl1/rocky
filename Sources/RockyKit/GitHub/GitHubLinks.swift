import Foundation

/// An issue's or a pull request's state, as the picker's state glyph (`GHL-02`) and the attachment's "State" line
/// (`GHL-04`) name it.
public enum GitHubItemState: String, Sendable, Equatable {
    case open, closed, merged

    /// GitHub's `OPEN`, `CLOSED` and `MERGED`; anything else reads as closed, which the picker draws like a merged one.
    init(graphQL value: String) {
        self = Self(rawValue: value.lowercased()) ?? .closed
    }
}

/// A row of the picker's Issues tab (`GHL-02`, `KIT-14`).
public struct IssueSummary: Equatable, Sendable, Identifiable {
    public let number: Int
    public let title: String
    public let state: GitHubItemState

    public var id: Int { number }

    public init(number: Int, title: String, state: GitHubItemState) {
        self.number = number
        self.title = title
        self.state = state
    }
}

/// A row of the picker's Pull requests tab (`GHL-02`, `KIT-14`), with what switching to it needs (`GHL-05`).
public struct PullRequestSummary: Equatable, Sendable, Identifiable {
    public let number: Int
    public let title: String
    public let state: GitHubItemState
    public let isDraft: Bool
    public let headRefName: String
    public let baseRefName: String
    /// Its head is in another repository, a fork: Rocky does not switch to it (`OUT-50`).
    public let isCrossRepository: Bool
    /// The head's repository, "owner/name"; nil when GitHub no longer has it (a deleted fork).
    public let headRepository: String?

    public var id: Int { number }

    public init(
        number: Int,
        title: String,
        state: GitHubItemState,
        isDraft: Bool,
        headRefName: String,
        baseRefName: String,
        isCrossRepository: Bool,
        headRepository: String?
    ) {
        self.number = number
        self.title = title
        self.state = state
        self.isDraft = isDraft
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.isCrossRepository = isCrossRepository
        self.headRepository = headRepository
    }
}

/// One comment of an issue or of a pull request's conversation (`GHL-04`).
public struct GitHubComment: Equatable, Sendable {
    public let author: String
    public let createdAt: Date
    public let body: String

    public init(author: String, createdAt: Date, body: String) {
        self.author = author
        self.createdAt = createdAt
        self.body = body
    }
}

/// An issue or a pull request in full, as its attachment shows it (`GHL-04`, `GHL-05`): what GitHub shows, never a
/// token.
public struct GitHubIssue: Equatable, Sendable {
    /// What only a pull request has.
    public struct PullRequestDetails: Equatable, Sendable {
        public let headRefName: String
        public let baseRefName: String
        public let isDraft: Bool
        public let isCrossRepository: Bool

        public init(headRefName: String, baseRefName: String, isDraft: Bool, isCrossRepository: Bool) {
            self.headRefName = headRefName
            self.baseRefName = baseRefName
            self.isDraft = isDraft
            self.isCrossRepository = isCrossRepository
        }
    }

    public let number: Int
    public let title: String
    public let url: URL
    public let state: GitHubItemState
    /// An issue's `stateReason`, lowercased with spaces ("completed", "not planned"); nil for a pull request.
    public let stateReason: String?
    /// The author's login; "ghost" for a deleted account, as GitHub shows it.
    public let author: String
    public let createdAt: Date
    /// The first 20.
    public let labels: [String]
    /// The first 10 logins.
    public let assignees: [String]
    public let body: String
    /// The first 100, oldest first.
    public let comments: [GitHubComment]
    /// Every comment GitHub has, `comments` included.
    public let totalComments: Int
    /// nil for an issue.
    public let pullRequest: PullRequestDetails?

    public init(
        number: Int,
        title: String,
        url: URL,
        state: GitHubItemState,
        stateReason: String? = nil,
        author: String,
        createdAt: Date,
        labels: [String] = [],
        assignees: [String] = [],
        body: String,
        comments: [GitHubComment] = [],
        totalComments: Int? = nil,
        pullRequest: PullRequestDetails? = nil
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.stateReason = stateReason
        self.author = author
        self.createdAt = createdAt
        self.labels = labels
        self.assignees = assignees
        self.body = body
        self.comments = comments
        self.totalComments = totalComments ?? comments.count
        self.pullRequest = pullRequest
    }
}

/// `GHL-03`'s search text.
public enum GitHubLinkSearch {
    public enum Kind: Sendable {
        case issue, pullRequest

        var qualifier: String {
            switch self {
            case .issue: "is:issue"
            case .pullRequest: "is:pr"
            }
        }
    }

    /// The number a text asks for directly: "212" or "#212", spaces around allowed. nil for anything else, and for
    /// a number GraphQL's 32-bit `Int` cannot carry.
    public static func number(in text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let number = Int(digits), number > 0, number <= Int(Int32.max) else { return nil }
        return number
    }

    /// GitHub's search query for the repository's open issues or pull requests matching `text`:
    /// "repo:owner/name is:issue is:open text". A number is searched without its "#", which GitHub's search would read
    /// as punctuation.
    public static func query(repository: GitHubRepository, kind: Kind, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = number(in: trimmed).map(String.init) ?? trimmed
        return "repo:\(repository.owner)/\(repository.name) \(kind.qualifier) is:open \(words)"
    }
}

/// Whether the message box's "+" can link GitHub in a workspace (`GHL-01`), from `ACC-01`'s lookups and a `canRead`
/// of the account it would use (Decision 3), resolved once per repository and launch.
public enum GitHubLinkState: Equatable, Sendable {
    case available
    /// The item's tooltip.
    case unavailable(String)

    public static let noRemote = "This repository has no GitHub remote"
    public static let noAccount = "Add a GitHub account that can read this repository in Settings"
}

/// Why a link did not happen (`GHL-05`'s refusals), in the words the picker shows. Never carries a token: git's text is
/// `GitBranchError`'s, already cleaned.
public enum GitHubLinkError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// `GitHubLinkState.unavailable`'s reason.
    case unavailable(String)
    case uncommittedChanges
    case commitsOfItsOwn
    case unsavedEdits
    /// The branch the workspace is already on.
    case currentBranch(String)
    /// A branch another worktree holds, which git refuses: its `BranchLinks.holderLabel`.
    case checkedOut(String)
    /// A pull request from a fork (`OUT-50`).
    case fromFork
    /// git's own message, for the toast (`GHL-05`'s "After").
    case git(String)

    /// `GHL-05`'s notice over the Pull requests and Branches tabs while the workspace has something of its own.
    public static let changesNotice = "This workspace has changes of its own. Switching needs one with none: create a workspace for it."

    /// One of `changesNotice`'s causes.
    public var isChangesOfItsOwn: Bool {
        switch self {
        case .uncommittedChanges, .commitsOfItsOwn, .unsavedEdits: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .unavailable(let reason): reason
        case .uncommittedChanges: "This workspace has uncommitted changes. Switching needs one with none: create a workspace for it."
        case .commitsOfItsOwn: "This workspace has commits of its own. Switching needs one with none: create a workspace for it."
        case .unsavedEdits: "This workspace has files with unsaved edits. Switching needs one with none: create a workspace for it."
        case .currentBranch(let branch): "This workspace is already on \(branch)."
        case .checkedOut(let place): "Checked out in \(place)"
        case .fromFork: "From a fork: Rocky doesn't switch to pull requests from forks."
        case .git(let message): message
        }
    }

    public var errorDescription: String? { description }

    /// A request the caller cancelled (newer typing, the picker closing, Decision 2): dropped, never shown.
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }

    /// What the picker says for a failure (`GHL-02`'s "Couldn't load issues: reason", a refusal, a failed fetch):
    /// GitHub's own message where it has one, else `ERR-01`'s label.
    public static func text(for error: Error) -> String {
        switch error {
        case let error as GitHubLinkError: return error.description
        case GitHubError.notFound: return "GitHub has no such item, or this account can't see it."
        default:
            let panel = PanelError(error)
            return panel.detail ?? panel.label
        }
    }
}

/// What `AppModel.switchWorktree` switches a workspace to (Decision 5).
public enum WorktreeSwitchTarget: Equatable, Sendable {
    /// A local branch, or one only on origin.
    case branch(BranchRef)
    /// A pull request of the repository, by number: its head branch, fetched first.
    case pullRequest(Int)
}

/// What `AppModel.switchWorktree` did.
public struct WorktreeSwitch: Equatable, Sendable {
    /// The workspace's branch now.
    public let branch: String
    /// The workspace's base now: a pull request's `origin/<baseRefName>`, else the one it had.
    public let baseRef: String?
    /// The workspace's own empty branch, deleted; nil when there was none to delete.
    public let deletedBranch: String?
    /// The pull request switched to, as fetched for the switch; its attachment is written from it.
    public let pullRequest: GitHubIssue?

    public init(branch: String, baseRef: String?, deletedBranch: String?, pullRequest: GitHubIssue?) {
        self.branch = branch
        self.baseRef = baseRef
        self.deletedBranch = deletedBranch
        self.pullRequest = pullRequest
    }
}
