import Foundation

/// GitHub's `PullRequestMergeMethod`, declared in `PR-05`'s order: squash, rebase, merge.
public enum MergeMethod: String, Codable, Sendable, CaseIterable {
    case squash = "SQUASH"
    case rebase = "REBASE"
    case merge = "MERGE"
}

/// The repository fields of `PR-01`'s query.
public struct RepositorySettings: Equatable, Sendable {
    public var id: String
    public var squashMergeAllowed: Bool
    public var rebaseMergeAllowed: Bool
    public var mergeCommitAllowed: Bool
    /// GitHub's last method this viewer used on the repository, else the repository's default.
    public var viewerDefaultMergeMethod: MergeMethod?
    /// `defaultBranchRef.name`: the base of a workspace that has no `baseRef` (Open question 9).
    public var defaultBranchName: String?

    public init(
        id: String,
        squashMergeAllowed: Bool = true,
        rebaseMergeAllowed: Bool = true,
        mergeCommitAllowed: Bool = true,
        viewerDefaultMergeMethod: MergeMethod? = nil,
        defaultBranchName: String? = nil
    ) {
        self.id = id
        self.squashMergeAllowed = squashMergeAllowed
        self.rebaseMergeAllowed = rebaseMergeAllowed
        self.mergeCommitAllowed = mergeCommitAllowed
        self.viewerDefaultMergeMethod = viewerDefaultMergeMethod
        self.defaultBranchName = defaultBranchName
    }
}

/// `PR-05`'s Kit: which methods the merge button offers and which one it starts on.
public enum MergeMethods {
    /// The methods the repository allows, in the order squash, rebase, merge.
    public static func available(repository: RepositorySettings) -> [MergeMethod] {
        MergeMethod.allCases.filter { method in
            switch method {
            case .squash: return repository.squashMergeAllowed
            case .rebase: return repository.rebaseMergeAllowed
            case .merge: return repository.mergeCommitAllowed
            }
        }
    }

    /// The viewer's default when the repository allows it, else the first allowed. GitHub always allows at least
    /// one method; with none, the viewer's default or squash.
    public static func initial(available: [MergeMethod], viewerDefault: MergeMethod?) -> MergeMethod {
        if let viewerDefault, available.contains(viewerDefault) { return viewerDefault }
        return available.first ?? viewerDefault ?? .squash
    }
}

/// A check's state, with `CHK-01`'s sets. `pending` is not yet running (queued, requested, waiting, expected):
/// `HDR-02` counts it, and `CHK-01` draws it as its "anything else" dot.
public enum CheckState: String, Codable, Sendable {
    case running, failed, passed, pending, other

    /// `CHK-01`'s five failures. ERROR only comes from a status context, the others from a check run.
    static let failures: Set<String> = ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"]
    static let passes: Set<String> = ["SUCCESS", "NEUTRAL", "SKIPPED"]

    /// A `CheckRun`: IN_PROGRESS runs; anything else not COMPLETED is pending; a completed one by its conclusion.
    /// STARTUP_FAILURE and STALE are in none of `CHK-01`'s sets, so they are `other`.
    public static func checkRun(status: String?, conclusion: String?) -> CheckState {
        switch status {
        case "IN_PROGRESS": return .running
        case "COMPLETED": break
        default: return .pending
        }
        guard let conclusion else { return .other }
        if failures.contains(conclusion) { return .failed }
        if passes.contains(conclusion) { return .passed }
        return .other
    }

    /// A `StatusContext` (another CI system): PENDING and EXPECTED are pending.
    public static func statusContext(state: String?) -> CheckState {
        guard let state else { return .other }
        if state == "PENDING" || state == "EXPECTED" { return .pending }
        if failures.contains(state) { return .failed }
        if passes.contains(state) { return .passed }
        return .other
    }
}

/// One entry of the last commit's `statusCheckRollup`: a GitHub check run or another system's status context.
public struct PullRequestCheck: Codable, Equatable, Sendable {
    public var name: String
    public var state: CheckState
    public var startedAt: Date?
    public var completedAt: Date?
    /// `detailsUrl` of a check run, `targetUrl` of a status context.
    public var url: URL?
    /// The check run's `databaseId`, which for GitHub Actions is the job id (`AGT-03`'s log and annotations). nil for
    /// a status context.
    public var checkRunId: Int?
    /// `checkSuite.workflowRun.databaseId` (`CHK-02`'s re-run). nil for a status context and for checks outside
    /// GitHub Actions.
    public var workflowRunId: Int?

    public init(
        name: String,
        state: CheckState,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        url: URL? = nil,
        checkRunId: Int? = nil,
        workflowRunId: Int? = nil
    ) {
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.url = url
        self.checkRunId = checkRunId
        self.workflowRunId = workflowRunId
    }
}

/// One deployment of the pull request's last commit (`DEP-01`).
public struct PullRequestDeployment: Equatable, Sendable {
    public var environment: String
    /// `latestStatus.state` (SUCCESS, FAILURE, ERROR, IN_PROGRESS, QUEUED, PENDING, WAITING, INACTIVE), else the
    /// deployment's own state when it has no status yet.
    public var state: String
    /// `latestStatus.environmentUrl`.
    public var url: URL?

    public init(environment: String, state: String, url: URL? = nil) {
        self.environment = environment
        self.state = state
        self.url = url
    }
}

/// The pull request fields of `PR-01`'s query, for the branch's newest open or merged pull request.
public struct PullRequestInfo: Equatable, Sendable {
    public var id: String
    public var number: Int
    public var url: URL
    public var title: String
    public var body: String
    public var isDraft: Bool
    public var isMerged: Bool
    public var mergedAt: Date?
    public var baseRefName: String
    public var headRefName: String
    /// The head commit on GitHub; `GST-01` fetches the branch when `refs/remotes/origin/<branch>` differs from it.
    public var headRefOid: String
    /// MERGEABLE, CONFLICTING or UNKNOWN.
    public var mergeable: String?
    /// CLEAN, UNSTABLE, HAS_HOOKS, BLOCKED, BEHIND, DIRTY or UNKNOWN (`HDR-02`).
    public var mergeStateStatus: String?
    /// APPROVED, CHANGES_REQUESTED or REVIEW_REQUIRED.
    public var reviewDecision: String?
    /// `reviewRequests.totalCount`: reviewers asked and not yet answered.
    public var reviewRequestCount: Int
    public var canBeRebased: Bool
    public var autoMergeEnabled: Bool
    /// `mergeQueueEntry.state` (QUEUED, AWAITING_CHECKS, MERGEABLE, UNMERGEABLE, LOCKED); nil outside a queue.
    public var mergeQueueState: String?
    public var checks: [PullRequestCheck]
    public var deployments: [PullRequestDeployment]

    public init(
        id: String,
        number: Int,
        url: URL,
        title: String = "",
        body: String = "",
        isDraft: Bool = false,
        isMerged: Bool = false,
        mergedAt: Date? = nil,
        baseRefName: String,
        headRefName: String,
        headRefOid: String = "",
        mergeable: String? = nil,
        mergeStateStatus: String? = nil,
        reviewDecision: String? = nil,
        reviewRequestCount: Int = 0,
        canBeRebased: Bool = true,
        autoMergeEnabled: Bool = false,
        mergeQueueState: String? = nil,
        checks: [PullRequestCheck] = [],
        deployments: [PullRequestDeployment] = []
    ) {
        self.id = id
        self.number = number
        self.url = url
        self.title = title
        self.body = body
        self.isDraft = isDraft
        self.isMerged = isMerged
        self.mergedAt = mergedAt
        self.baseRefName = baseRefName
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.reviewDecision = reviewDecision
        self.reviewRequestCount = reviewRequestCount
        self.canBeRebased = canBeRebased
        self.autoMergeEnabled = autoMergeEnabled
        self.mergeQueueState = mergeQueueState
        self.checks = checks
        self.deployments = deployments
    }

    /// `CHK-01`'s order: failed first, then running, then the API's order.
    public var orderedChecks: [PullRequestCheck] {
        checks.filter { $0.state == .failed } + checks.filter { $0.state == .running }
            + checks.filter { $0.state != .failed && $0.state != .running }
    }

    /// `DEP-01`'s dedupe: the first of each environment in the newest-first list.
    public var latestDeployments: [PullRequestDeployment] {
        var seen: Set<String> = []
        return deployments.filter { seen.insert($0.environment).inserted }
    }
}

/// One refresh of the panel (`PR-01`).
public struct PullRequestSnapshot: Equatable, Sendable {
    public var repository: RepositorySettings
    /// nil: the branch has no open or merged pull request (a closed one falls back to create PR, `HDR-02`).
    public var pullRequest: PullRequestInfo?
    /// GraphQL `compare` of the base with the branch: commits the branch has that the base does not. nil when the
    /// branch is not on GitHub yet.
    public var baseAheadBy: Int?
    /// Commits of the base the branch does not have: `GST-01`'s "N commits behind development".
    public var baseBehindBy: Int?

    public init(repository: RepositorySettings, pullRequest: PullRequestInfo?, baseAheadBy: Int? = nil, baseBehindBy: Int? = nil) {
        self.repository = repository
        self.pullRequest = pullRequest
        self.baseAheadBy = baseAheadBy
        self.baseBehindBy = baseBehindBy
    }
}

/// A comment waiting for the author (`REV-01`): an unresolved, current review thread with its replies, a
/// conversation comment, or the body of a reviewer's latest changes-requested review.
public struct PendingComment: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case thread, conversation, review
    }

    /// A reply of a review thread, after its first comment (Open question 8).
    public struct Reply: Equatable, Sendable {
        public var author: String
        public var body: String

        public init(author: String, body: String) {
            self.author = author
            self.body = body
        }
    }

    /// The GitHub node id of the thread, the comment or the review: what Hide stores.
    public var id: String
    public var kind: Kind
    public var author: String
    public var body: String
    /// A thread's file; nil for a conversation comment or a review.
    public var path: String?
    /// A thread's line; nil for a comment on the whole file.
    public var line: Int?
    public var replies: [Reply]

    public init(id: String, kind: Kind, author: String, body: String, path: String? = nil, line: Int? = nil, replies: [Reply] = []) {
        self.id = id
        self.kind = kind
        self.author = author
        self.body = body
        self.path = path
        self.line = line
        self.replies = replies
    }
}

/// `CHK-01`'s durations: "1h 4m", "3m" or "45s" once finished; "<1m" or "3m" while running.
public enum CheckDuration {
    /// `end` nil: the check is still running, timed from `start` to `now`.
    public static func text(start: Date?, end: Date?, now: Date) -> String? {
        guard let start else { return nil }
        guard let end else {
            let elapsed = max(0, now.timeIntervalSince(start))
            return elapsed < 60 ? "<1m" : format(seconds: Int(elapsed), withSeconds: false)
        }
        return format(seconds: Int(max(0, end.timeIntervalSince(start))), withSeconds: true)
    }

    private static func format(seconds: Int, withSeconds: Bool) -> String {
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 || !withSeconds { return "\(minutes)m" }
        return "\(seconds)s"
    }
}
