import Foundation
import Testing
@testable import RockyKit

struct ChecksPresentationTests {
    private func pr(
        isDraft: Bool = false,
        isMerged: Bool = false,
        mergeable: String? = "MERGEABLE",
        mergeState: String? = "CLEAN",
        review: String? = "APPROVED",
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
            mergeStateStatus: mergeState,
            reviewDecision: review,
            checks: checks
        )
    }

    private func texts(_ rows: [GitStatusRow]) -> [String] {
        rows.map(\.text)
    }

    /// GST-01: the table's order; incompatible hides behind and ahead of the remote (Open question 4).
    @Test func gitStatusRowsFollowTheTableOrder() {
        let local = LocalGitStatus(uncommitted: 2, ahead: 1, behind: 3, isIncompatible: true)
        let rows = GitStatusRow.rows(
            pr: pr(mergeable: "CONFLICTING", mergeState: "DIRTY", review: "CHANGES_REQUESTED"),
            local: local,
            baseBehindBy: 5,
            base: "development"
        )
        #expect(texts(rows) == [
            "Merge conflicts detected", "Incompatible with remote", "2 uncommitted changes", "5 commits behind development",
            "PR changes requested",
        ])
        #expect(rows.map(\.action) == [.resolveConflicts, .resolveIncompatible, .commitAndPush, .pullFromBase, .addAllComments])
        #expect(rows.map(\.tone) == [.danger, .danger, .attention, .attention, .danger])
    }

    @Test func behindAndAheadOfTheRemoteInTheSingular() {
        let rows = GitStatusRow.rows(
            pr: pr(mergeState: "BLOCKED"),
            local: LocalGitStatus(uncommitted: 1, ahead: 1, behind: 1),
            baseBehindBy: 1,
            base: "main"
        )
        #expect(texts(rows) == ["1 uncommitted change", "1 commit behind remote", "1 commit ahead of remote", "1 commit behind main"])
        #expect(rows.map(\.action) == [.commitAndPush, .pull, .push, .pullFromBase])
    }

    /// Open question 14: a merged pull request shows only where it went.
    @Test func aMergedPullRequestShowsOnlyMerged() {
        let rows = GitStatusRow.rows(pr: pr(isMerged: true), local: LocalGitStatus(uncommitted: 3), baseBehindBy: 2, base: "development")
        #expect(rows == [GitStatusRow(text: "Merged into development", tone: .merged)])
    }

    @Test func withNothingToDoTheBranchIsUpToDate() {
        let rows = GitStatusRow.rows(pr: pr(mergeState: "BLOCKED", review: "APPROVED"), local: LocalGitStatus(), baseBehindBy: 0, base: "development")
        #expect(rows == [GitStatusRow(text: "Up to date with development", tone: .success)])
    }

    @Test func withoutAPullRequestTheRowOffersCreatePR() {
        let rows = GitStatusRow.rows(pr: nil, local: LocalGitStatus(ahead: 2), baseBehindBy: nil, base: "development")
        #expect(texts(rows) == ["2 commits ahead of remote", "No PR open"])
        #expect(rows.last?.action == .createPR)
        #expect(rows.last?.tone == .muted)
    }

    @Test func draftReviewAndReadyRows() {
        let draft = GitStatusRow.rows(pr: pr(isDraft: true, mergeState: "BLOCKED", review: "REVIEW_REQUIRED"), local: nil, baseBehindBy: nil, base: "main")
        #expect(draft == [GitStatusRow(text: "PR is in draft", tone: .muted, action: .readyForReview)])

        let waiting = GitStatusRow.rows(pr: pr(mergeState: "BLOCKED", review: "REVIEW_REQUIRED"), local: nil, baseBehindBy: nil, base: "main")
        #expect(waiting == [GitStatusRow(text: "Waiting for PR review", tone: .muted)])

        let ready = GitStatusRow.rows(pr: pr(mergeState: "CLEAN"), local: LocalGitStatus(), baseBehindBy: 0, base: "main")
        #expect(ready == [GitStatusRow(text: "Ready to merge", tone: .success, action: .merge)])
    }

    /// DEP-01: the icon by state (a deployment's own success is ACTIVE), and the Vercel slug as the name.
    @Test func deploymentStatesAndNames() {
        let states: [(String, DeploymentStatus)] = [
            ("SUCCESS", .deployed), ("ACTIVE", .deployed), ("FAILURE", .failed), ("ERROR", .failed),
            ("IN_PROGRESS", .deploying), ("QUEUED", .queued), ("PENDING", .queued), ("WAITING", .queued),
            ("INACTIVE", .inactive), ("DESTROYED", .inactive),
        ]
        for (state, status) in states {
            #expect(DeploymentStatus(state: state) == status, "\(state)")
        }
        #expect(DeploymentStatus.deploying.word == "Deploying")

        let vercel = PullRequestDeployment(environment: "Preview", state: "SUCCESS", url: URL(string: "https://celes-web-git-invoice.vercel.app"))
        #expect(vercel.isVercel)
        #expect(vercel.displayName == "celes-web-git-invoice")
        let storybook = PullRequestDeployment(environment: "storybook", state: "SUCCESS", url: URL(string: "https://storybook.example.dev"))
        #expect(!storybook.isVercel)
        #expect(storybook.displayName == "storybook")

        let check = PullRequestCheck(name: "Vercel – celes-web", state: .passed, url: URL(string: "https://vercel.com/celes/web/abc"))
        #expect(check.isVercel)
        #expect(!PullRequestCheck(name: "unit", state: .passed, url: URL(string: "https://github.com/jhzl1/rocky/actions/runs/1")).isVercel)
    }

    /// CHK-02: each failed check run's workflow run once; a status context has none.
    @Test func failedWorkflowRunsAreDistinct() {
        let checks = [
            PullRequestCheck(name: "unit", state: .failed, checkRunId: 11, workflowRunId: 901),
            PullRequestCheck(name: "e2e", state: .failed, checkRunId: 12, workflowRunId: 901),
            PullRequestCheck(name: "build", state: .passed, checkRunId: 13, workflowRunId: 902),
            PullRequestCheck(name: "docs", state: .failed, checkRunId: 14, workflowRunId: 903),
            PullRequestCheck(name: "ci/circleci", state: .failed, url: URL(string: "https://circleci.com/gh/jhzl1/rocky/12")),
        ]
        #expect(pr(checks: checks).failedWorkflowRunIds == [901, 903])
        #expect(pr().checksURL == URL(string: "https://github.com/jhzl1/rocky/pull/4525/checks"))
    }

    @Test func relativeAgeReadsSecondsMinutesHoursAndDays() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(RelativeAge.text(since: now, now: now) == "1s ago")
        #expect(RelativeAge.text(since: now.addingTimeInterval(-12), now: now) == "12s ago")
        #expect(RelativeAge.text(since: now.addingTimeInterval(-5 * 60 - 20), now: now) == "5m ago")
        #expect(RelativeAge.text(since: now.addingTimeInterval(-2 * 3600), now: now) == "2h ago")
        #expect(RelativeAge.text(since: now.addingTimeInterval(-3 * 86_400), now: now) == "3d ago")
    }

    /// PR-07's footer: the account, then when GitHub last answered, "No pull request", or offline since when.
    @Test func footerNamesTheAccountAndTheLastUpdate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let repository = RepositorySettings(id: "R_1")
        var panel = PullRequestPanelState(login: "jhzl1")
        #expect(panel.footerText(now: now) == "jhzl1")

        panel.snapshot = PullRequestSnapshot(repository: repository, pullRequest: pr())
        panel.updatedAt = now.addingTimeInterval(-12)
        #expect(panel.footerText(now: now) == "jhzl1 · Updated 12s ago")

        panel.snapshot = PullRequestSnapshot(repository: repository, pullRequest: nil)
        #expect(panel.footerText(now: now) == "jhzl1 · No pull request")

        panel.error = .offline
        panel.updatedAt = now.addingTimeInterval(-300)
        #expect(panel.footerText(now: now) == "jhzl1 · No internet connection · updated 5m ago")
    }

    /// HDR-03: the snapshot's pull request, else the stored one until the first refresh.
    @Test func shownPullRequestPrefersTheSnapshotOverTheStoredState() {
        let url = URL(string: "https://github.com/jhzl1/rocky/pull/4520")!
        let stored = StoredPullRequest(number: 4520, url: url, state: "MERGED", headerState: "merged", checks: [], updatedAt: Date())
        var panel = PullRequestPanelState(stored: stored)
        #expect(panel.shownPullRequest == PullRequestReference(number: 4520, url: url))

        panel.snapshot = PullRequestSnapshot(repository: RepositorySettings(id: "R_1"), pullRequest: nil)
        #expect(panel.shownPullRequest == nil)

        panel.snapshot = PullRequestSnapshot(repository: RepositorySettings(id: "R_1"), pullRequest: pr())
        #expect(panel.shownPullRequest?.number == 4525)
    }

    /// PR-05's labels: the button's, its confirmation's, the menu's items and second lines, and the tooltip.
    @Test func mergeMethodsReadAsPR05() {
        #expect(MergeMethod.allCases.map(\.buttonTitle) == ["Squash", "Rebase", "Merge"])
        #expect(MergeMethod.allCases.map(\.confirmTitle) == ["Confirm squash", "Confirm rebase", "Confirm merge"])
        #expect(MergeMethod.allCases.map(\.menuTitle) == ["Squash and merge", "Rebase and merge", "Create a merge commit"])
        #expect(MergeMethod.allCases.map { $0.menuDetail(base: "development") } == [
            "Combine all commits into one commit on development",
            "Replay each commit onto development, no merge commit",
            "Keep every commit and add a merge commit",
        ])
        #expect(MergeMethod.squash.tooltip(base: "development") == "Squash and merge into development")
    }

    /// REV-01's location column and the avatar's initials.
    @Test func commentRowsSayWhereTheCommentIs() {
        let thread = PendingComment(id: "T1", kind: .thread, author: "ana", body: "Use backoff.", path: "src/ocr/retry.ts", line: 42)
        let onAFile = PendingComment(id: "T2", kind: .thread, author: "ana", body: "Mention it.", path: "README.md")
        let review = PendingComment(id: "R1", kind: .review, author: "bo", body: "Split the client.")
        let long = "Please add a test for the timeout path.\nThe current tests only cover the happy path."
        let conversation = PendingComment(id: "C1", kind: .conversation, author: "cy", body: long)

        #expect(thread.rowLocation == "src/ocr/retry.ts:42")
        #expect(onAFile.rowLocation == "README.md")
        #expect(review.rowLocation == "review")
        #expect(conversation.rowLocation == "Please add a test for the timeout path. The curren")
        #expect(conversation.rowLocation.count == 50)
        #expect(thread.initials == "AN")
        #expect(PendingComment(id: "C2", kind: .conversation, author: "j", body: "Hi").initials == "J")
    }
}
