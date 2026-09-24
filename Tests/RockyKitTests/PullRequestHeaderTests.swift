import Foundation
import Testing
@testable import RockyKit

/// `HDR-02`: one test per row, in the table's order, then the overlaps and the labels.
struct PullRequestHeaderTests {
    private func pr(
        isDraft: Bool = false,
        isMerged: Bool = false,
        mergeable: String? = "MERGEABLE",
        mergeStateStatus: String? = "CLEAN",
        reviewDecision: String? = nil,
        mergeQueueState: String? = nil,
        checks: [PullRequestCheck] = []
    ) -> PullRequestInfo {
        PullRequestInfo(
            id: "PR_1",
            number: 4525,
            url: URL(string: "https://github.com/jhzl1/rocky/pull/4525")!,
            isDraft: isDraft,
            isMerged: isMerged,
            baseRefName: "development",
            headRefName: "rocky/tokyo",
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            reviewDecision: reviewDecision,
            mergeQueueState: mergeQueueState,
            checks: checks
        )
    }

    private let clean = LocalGitStatus(branch: "rocky/tokyo", upstream: "origin/rocky/tokyo", commitsAheadOfBase: 2)

    private func check(_ name: String, _ state: CheckState, url: String? = "https://github.com/jhzl1/rocky/actions/runs/1") -> PullRequestCheck {
        PullRequestCheck(name: name, state: state, url: url.flatMap { URL(string: $0) })
    }

    private func state(_ pr: PullRequestInfo?, _ local: LocalGitStatus?, working: Bool = false) -> HeaderState {
        PullRequestHeader.state(pr: pr, local: local, agentWorking: working)
    }

    private func label(_ state: HeaderState, _ pr: PullRequestInfo?, _ local: LocalGitStatus?) -> String {
        PullRequestHeader.presentation(state, pr: pr, local: local).label
    }

    // MARK: One per row

    @Test func merged() {
        #expect(state(pr(isMerged: true, mergeStateStatus: "DIRTY"), clean, working: true) == .merged)
        #expect(PullRequestHeader.presentation(.merged, pr: pr(isMerged: true), local: clean)
            == HeaderPresentation(group: .merged, label: "Merged", action: .archive))
    }

    @Test func queuedToMerge() {
        #expect(state(pr(mergeQueueState: "QUEUED"), clean, working: true) == .queuedToMerge)
        let labels = ["AWAITING_CHECKS", "UNMERGEABLE", "LOCKED", "QUEUED", "MERGEABLE"].map { queue in
            PullRequestHeader.presentation(.queuedToMerge, pr: pr(mergeQueueState: queue), local: clean)
        }
        #expect(labels.map(\.label) == ["Merge queue checks pending", "Merge queue blocked", "Merge queue locked", "Queued to merge", "Queued to merge"])
        #expect(labels.allSatisfy { $0.group == .queued && $0.action == .queuedBadge && !$0.spins })
    }

    @Test func autoMergeAloneIsNotQueued() {
        var auto = pr()
        auto.autoMergeEnabled = true
        #expect(state(auto, clean) == .readyToMerge)
    }

    @Test func working() {
        #expect(state(pr(mergeStateStatus: "DIRTY"), clean, working: true) == .working)
        #expect(state(nil, clean, working: true) == .working)
        #expect(PullRequestHeader.presentation(.working, pr: nil, local: clean)
            == HeaderPresentation(group: .loading, label: "Working…", spins: true))
    }

    @Test func createPRWithChangesElseNoChangesYet() {
        #expect(state(nil, clean) == .createPR)
        #expect(state(nil, LocalGitStatus(uncommitted: 1)) == .createPR)
        #expect(state(nil, LocalGitStatus()) == .noChanges)
        #expect(state(nil, nil) == .createPR)
        // HDR-04: "No pull request" beside the split button, dimmed like "No changes yet".
        #expect(PullRequestHeader.presentation(.createPR, pr: nil, local: clean)
            == HeaderPresentation(group: .noPR, label: "No pull request", action: .createPR, isDim: true))
        #expect(PullRequestHeader.presentation(.noChanges, pr: nil, local: LocalGitStatus())
            == HeaderPresentation(group: .noPR, label: "No changes yet", isDim: true))
    }

    @Test func commitAndPush() {
        var local = clean
        local.uncommitted = 3
        #expect(state(pr(), local) == .commitAndPush)
        #expect(PullRequestHeader.presentation(.commitAndPush, pr: pr(), local: local)
            == HeaderPresentation(group: .outOfSync, label: "Uncommitted changes", action: .commitAndPush))
    }

    @Test func incompatible() {
        var local = clean
        local.ahead = 1
        local.behind = 2
        local.isIncompatible = true
        #expect(state(pr(), local) == .incompatible)
        #expect(PullRequestHeader.presentation(.incompatible, pr: pr(), local: local)
            == HeaderPresentation(group: .outOfSync, label: "Incompatible with remote", action: .resolveIncompatible))
        local.remoteWasRebased = true
        #expect(label(.incompatible, pr(), local) == "Remote branch was rebased")
    }

    @Test func pull() {
        var local = clean
        local.behind = 3
        #expect(state(pr(), local) == .pull)
        #expect(PullRequestHeader.presentation(.pull, pr: pr(), local: local)
            == HeaderPresentation(group: .outOfSync, label: "Behind by 3 commits", action: .pull))
        local.behind = 1
        #expect(label(.pull, pr(), local) == "Behind by 1 commit")
    }

    @Test func push() {
        var local = clean
        local.ahead = 2
        #expect(state(pr(), local) == .push)
        #expect(PullRequestHeader.presentation(.push, pr: pr(), local: local)
            == HeaderPresentation(group: .outOfSync, label: "Ahead by 2 commits", action: .push))
        local.ahead = 1
        #expect(label(.push, pr(), local) == "Ahead by 1 commit")
    }

    @Test func mergeConflicts() {
        #expect(state(pr(mergeStateStatus: "DIRTY"), clean) == .mergeConflicts)
        #expect(state(pr(mergeable: "CONFLICTING", mergeStateStatus: "UNKNOWN"), clean) == .mergeConflicts)
        #expect(PullRequestHeader.presentation(.mergeConflicts, pr: pr(), local: clean)
            == HeaderPresentation(group: .outOfSync, label: "Merge conflicts", action: .resolveConflicts))
    }

    @Test func changesRequested() {
        #expect(state(pr(mergeStateStatus: "BLOCKED", reviewDecision: "CHANGES_REQUESTED"), clean) == .changesRequested)
        #expect(PullRequestHeader.presentation(.changesRequested, pr: pr(), local: clean)
            == HeaderPresentation(group: .outOfSync, label: "PR changes requested", action: .addAllComments))
    }

    @Test func draftPR() {
        #expect(state(pr(isDraft: true, mergeStateStatus: "BLOCKED"), clean) == .draftPR)
        #expect(PullRequestHeader.presentation(.draftPR, pr: pr(isDraft: true), local: clean)
            == HeaderPresentation(group: .outOfSync, label: "Draft PR open", action: .readyForReview))
    }

    @Test func checksFailing() {
        let checks = [check("lint", .passed), check("unit", .failed), check("e2e", .failed), check("build", .running), check("deploy", .pending)]
        let failing = pr(mergeStateStatus: "BLOCKED", reviewDecision: "APPROVED", checks: checks)
        #expect(state(failing, clean) == .checksFailing)
        #expect(PullRequestHeader.presentation(.checksFailing, pr: failing, local: clean)
            == HeaderPresentation(group: .outOfSync, label: "2 / 5 checks failed, 2 pending", action: .fixErrors))

        // Without pending checks the label drops ", K pending"; without a URL on a failed check, View checks.
        let noURL = pr(mergeStateStatus: "BLOCKED", checks: [check("lint", .passed), check("ci/jenkins", .failed, url: nil)])
        #expect(PullRequestHeader.presentation(.checksFailing, pr: noURL, local: clean)
            == HeaderPresentation(group: .outOfSync, label: "1 / 2 checks failed", action: .viewChecks))
        let single = pr(mergeStateStatus: "BLOCKED", checks: [check("unit", .failed)])
        #expect(label(.checksFailing, single, clean) == "1 / 1 check failed")
    }

    @Test func checksPending() {
        let pending = pr(mergeStateStatus: "BLOCKED", checks: [check("lint", .passed), check("unit", .running), check("e2e", .pending)])
        #expect(state(pending, clean) == .checksPending)
        #expect(PullRequestHeader.presentation(.checksPending, pr: pending, local: clean)
            == HeaderPresentation(group: .queued, label: "2 checks pending…", spins: true))
        #expect(label(.checksPending, pr(checks: [check("unit", .running)]), clean) == "1 check pending…")
    }

    @Test func reviewRequired() {
        #expect(state(pr(mergeStateStatus: "BLOCKED", reviewDecision: "REVIEW_REQUIRED"), clean) == .reviewRequired)
        #expect(PullRequestHeader.presentation(.reviewRequired, pr: pr(), local: clean)
            == HeaderPresentation(group: .outOfSync, label: "PR review required"))
    }

    @Test func blocked() {
        #expect(state(pr(mergeStateStatus: "BLOCKED", reviewDecision: "APPROVED"), clean) == .blocked)
        #expect(PullRequestHeader.presentation(.blocked, pr: pr(), local: clean)
            == HeaderPresentation(group: .outOfSync, label: "Blocked from merging"))
    }

    @Test func loadingPR() {
        #expect(state(pr(mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN"), clean) == .loadingPR)
        #expect(PullRequestHeader.presentation(.loadingPR, pr: pr(), local: clean)
            == HeaderPresentation(group: .loading, label: "Checking mergeability…", spins: true))
    }

    @Test func readyToMerge() {
        for status in ["CLEAN", "UNSTABLE", "HAS_HOOKS"] {
            #expect(state(pr(mergeStateStatus: status), clean) == .readyToMerge, "\(status)")
        }
        #expect(PullRequestHeader.presentation(.readyToMerge, pr: pr(), local: clean)
            == HeaderPresentation(group: .inSync, label: "Ready to merge", action: .merge))
    }

    /// Open question 2: with UNSTABLE, failed checks are optional and the pull request is ready to merge.
    @Test func optionalChecksFailedIsReadyToMerge() {
        let unstable = pr(mergeStateStatus: "UNSTABLE", checks: [check("lint", .passed), check("flaky", .failed), check("slow", .failed)])
        #expect(state(unstable, clean) == .readyToMerge)
        #expect(label(.readyToMerge, unstable, clean) == "2 optional checks failed")
        let one = pr(mergeStateStatus: "UNSTABLE", checks: [check("flaky", .failed)])
        #expect(label(.readyToMerge, one, clean) == "1 optional check failed")
    }

    @Test func unableToMerge() {
        #expect(state(pr(mergeStateStatus: "BEHIND"), clean) == .unableToMerge)
        #expect(state(pr(mergeStateStatus: nil), clean) == .unableToMerge)
        #expect(PullRequestHeader.presentation(.unableToMerge, pr: pr(mergeStateStatus: "BEHIND"), local: clean)
            == HeaderPresentation(group: .outOfSync, label: "Unable to merge · behind development"))
        #expect(label(.unableToMerge, pr(mergeStateStatus: "BLOCKED"), clean) == "Unable to merge")
    }

    // MARK: Overlaps

    @Test func uncommittedChangesWinOverConflicts() {
        var local = clean
        local.uncommitted = 1
        #expect(state(pr(mergeable: "CONFLICTING", mergeStateStatus: "DIRTY"), local) == .commitAndPush)
    }

    @Test func draftWinsOverFailingChecks() {
        #expect(state(pr(isDraft: true, mergeStateStatus: "BLOCKED", checks: [check("unit", .failed)]), clean) == .draftPR)
    }

    @Test func incompatibleWinsOverBehindAndAhead() {
        let local = LocalGitStatus(branch: "rocky/tokyo", upstream: "origin/rocky/tokyo", ahead: 1, behind: 1, isIncompatible: true)
        #expect(state(pr(), local) == .incompatible)
    }

    @Test func behindWinsOverAhead() {
        // Incompatible is ahead and behind at once, so this only happens when the status came without that flag.
        let local = LocalGitStatus(branch: "rocky/tokyo", upstream: "origin/rocky/tokyo", ahead: 1, behind: 2)
        #expect(state(pr(), local) == .pull)
    }

    @Test func withoutALocalStatusThePullRequestDecides() {
        #expect(state(pr(mergeStateStatus: "DIRTY"), nil) == .mergeConflicts)
    }

    @Test func statesAreStoredByTheirRawValue() {
        #expect(HeaderState.checksFailing.rawValue == "checksFailing")
        #expect(HeaderState(rawValue: "readyToMerge") == .readyToMerge)
    }
}
