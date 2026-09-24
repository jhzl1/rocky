import Foundation

/// `HDR-02`'s states, declared in its priority order. Stored by raw value (`StoredPullRequest.headerState`).
public enum HeaderState: String, Codable, Sendable, CaseIterable {
    case merged, queuedToMerge, working, noChanges, createPR, commitAndPush, incompatible, pull, push, mergeConflicts,
         changesRequested, draftPR, checksFailing, checksPending, reviewRequired, blocked, loadingPR, readyToMerge,
         unableToMerge
}

/// `HDR-01`'s tint groups. `loading` also holds `ERR-01`'s labels.
public enum HeaderGroup: Sendable {
    case inSync, outOfSync, queued, merged, noPR, loading
}

/// The header's one action (`HDR-02`'s last column). Checks pending, review required and blocked have none: their
/// Conductor actions (Automerge, Approve) are `OUT-30`, and a merge queue shows only a static badge.
public enum HeaderAction: Sendable {
    case none, archive, queuedBadge, createPR, commitAndPush, resolveIncompatible, pull, push, resolveConflicts,
         addAllComments, readyForReview, fixErrors, viewChecks, merge
}

/// What the header draws: its tint, its label and its action.
public struct HeaderPresentation: Equatable, Sendable {
    public var group: HeaderGroup
    public var label: String
    public var action: HeaderAction
    /// A spinner before the label: the state is moving.
    public var spins: Bool
    /// The label says there is nothing yet ("No pull request", "No changes yet"): `textTertiary`, regular weight
    /// (`HDR-04`), instead of the group's tone in medium.
    public var isDim: Bool

    public init(group: HeaderGroup, label: String, action: HeaderAction = .none, spins: Bool = false, isDim: Bool = false) {
        self.group = group
        self.label = label
        self.action = action
        self.spins = spins
        self.isDim = isDim
    }
}

/// `HDR-02`: the pull request header's state and how it reads.
public enum PullRequestHeader {
    /// The first row of `HDR-02` that applies. `pr` is the branch's newest open or merged pull request (a closed one
    /// is nil, so it falls back to create PR); `agentWorking` is the selected conversation's turn running (`AGT-00`).
    public static func state(pr: PullRequestInfo?, local: LocalGitStatus?, agentWorking: Bool) -> HeaderState {
        if pr?.isMerged == true { return .merged }
        // Only a merge queue entry: an enabled auto-merge is Conductor's Automerge (OUT-30).
        if pr?.mergeQueueState != nil { return .queuedToMerge }
        if agentWorking { return .working }
        guard let pr else {
            // Without a local status Rocky cannot tell there is nothing to put in a pull request, so it offers one.
            let hasChanges = local.map { $0.uncommitted > 0 || $0.commitsAheadOfBase > 0 } ?? true
            return hasChanges ? .createPR : .noChanges
        }
        if let local {
            if local.uncommitted > 0 { return .commitAndPush }
            if local.isIncompatible { return .incompatible }
            if local.behind > 0 { return .pull }
            if local.ahead > 0 { return .push }
        }
        if pr.mergeable == "CONFLICTING" || pr.mergeStateStatus == "DIRTY" { return .mergeConflicts }
        if pr.reviewDecision == "CHANGES_REQUESTED" { return .changesRequested }
        // GitHub's MergeStateStatus has no DRAFT (checked 2026-09-23): a draft is `isDraft` only.
        if pr.isDraft { return .draftPR }
        let counts = CheckCounts(pr.checks)
        // UNSTABLE: whatever failed does not block the merge (Open question 2).
        if counts.failed > 0 && pr.mergeStateStatus != "UNSTABLE" { return .checksFailing }
        if counts.pending > 0 { return .checksPending }
        switch pr.mergeStateStatus {
        case "BLOCKED": return pr.reviewDecision == "REVIEW_REQUIRED" ? .reviewRequired : .blocked
        case "UNKNOWN": return .loadingPR
        case "CLEAN", "UNSTABLE", "HAS_HOOKS": return .readyToMerge
        default: return .unableToMerge
        }
    }

    /// The state's group, label and action (`HDR-01`, `HDR-02`), with "1 commit" and "1 check" in the singular.
    public static func presentation(_ state: HeaderState, pr: PullRequestInfo?, local: LocalGitStatus?) -> HeaderPresentation {
        let counts = CheckCounts(pr?.checks ?? [])
        switch state {
        case .merged:
            return HeaderPresentation(group: .merged, label: "Merged", action: .archive)
        case .queuedToMerge:
            return HeaderPresentation(group: .queued, label: queueLabel(pr?.mergeQueueState), action: .queuedBadge)
        case .working:
            return HeaderPresentation(group: .loading, label: "Working…", spins: true)
        case .noChanges:
            return HeaderPresentation(group: .noPR, label: "No changes yet", isDim: true)
        case .createPR:
            // HDR-04: the header's left side is never empty.
            return HeaderPresentation(group: .noPR, label: "No pull request", action: .createPR, isDim: true)
        case .commitAndPush:
            return HeaderPresentation(group: .outOfSync, label: "Uncommitted changes", action: .commitAndPush)
        case .incompatible:
            let label = local?.remoteWasRebased == true ? "Remote branch was rebased" : "Incompatible with remote"
            return HeaderPresentation(group: .outOfSync, label: label, action: .resolveIncompatible)
        case .pull:
            return HeaderPresentation(group: .outOfSync, label: "Behind by \(commits(local?.behind ?? 0))", action: .pull)
        case .push:
            return HeaderPresentation(group: .outOfSync, label: "Ahead by \(commits(local?.ahead ?? 0))", action: .push)
        case .mergeConflicts:
            return HeaderPresentation(group: .outOfSync, label: "Merge conflicts", action: .resolveConflicts)
        case .changesRequested:
            return HeaderPresentation(group: .outOfSync, label: "PR changes requested", action: .addAllComments)
        case .draftPR:
            return HeaderPresentation(group: .outOfSync, label: "Draft PR open", action: .readyForReview)
        case .checksFailing:
            let noun = counts.total == 1 ? "check" : "checks"
            var label = "\(counts.failed) / \(counts.total) \(noun) failed"
            if counts.pending > 0 { label += ", \(counts.pending) pending" }
            // Fix errors needs somewhere to read the failure; without a URL the checks page is all there is.
            return HeaderPresentation(group: .outOfSync, label: label, action: counts.failedHaveURL ? .fixErrors : .viewChecks)
        case .checksPending:
            let noun = counts.pending == 1 ? "check" : "checks"
            return HeaderPresentation(group: .queued, label: "\(counts.pending) \(noun) pending…", spins: true)
        case .reviewRequired:
            return HeaderPresentation(group: .outOfSync, label: "PR review required")
        case .blocked:
            return HeaderPresentation(group: .outOfSync, label: "Blocked from merging")
        case .loadingPR:
            return HeaderPresentation(group: .loading, label: "Checking mergeability…", spins: true)
        case .readyToMerge:
            var label = "Ready to merge"
            if pr?.mergeStateStatus == "UNSTABLE", counts.failed > 0 {
                label = "\(counts.failed) optional \(counts.failed == 1 ? "check" : "checks") failed"
            }
            return HeaderPresentation(group: .inSync, label: label, action: .merge)
        case .unableToMerge:
            let label = pr.map { $0.mergeStateStatus == "BEHIND" ? "Unable to merge · behind \($0.baseRefName)" : "Unable to merge" }
            return HeaderPresentation(group: .outOfSync, label: label ?? "Unable to merge")
        }
    }

    /// Open question 1: the queue entry's state names the label.
    static func queueLabel(_ state: String?) -> String {
        switch state {
        case "AWAITING_CHECKS": "Merge queue checks pending"
        case "UNMERGEABLE": "Merge queue blocked"
        case "LOCKED": "Merge queue locked"
        default: "Queued to merge"
        }
    }

    static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }
}

/// `HDR-02`'s check counts: failed, and pending (running or not started yet), out of every check.
struct CheckCounts {
    let total: Int
    let failed: Int
    let pending: Int
    let failedHaveURL: Bool

    init(_ checks: [PullRequestCheck]) {
        total = checks.count
        failed = checks.filter { $0.state == .failed }.count
        pending = checks.filter { $0.state == .running || $0.state == .pending }.count
        failedHaveURL = checks.contains { $0.state == .failed && $0.url != nil }
    }
}
