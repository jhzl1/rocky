import Foundation
import Testing
@testable import RockyKit

struct WorkspaceStatusTests {
    private func stored(
        state: String = "OPEN",
        headerState: HeaderState = .readyToMerge,
        checks: [CheckState] = []
    ) -> StoredPullRequest {
        StoredPullRequest(
            number: 4525,
            url: URL(string: "https://github.com/jhzl1/rocky/pull/4525")!,
            state: state,
            headerState: headerState.rawValue,
            checks: checks.enumerated().map { PullRequestCheck(name: "check \($0.offset)", state: $0.element) },
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    /// Every pair of states resolves to the one listed first in ROW-03 and ROW-07: needs you › error › working ›
    /// unread › pull request › merged › idle.
    @Test func priorityOrder() {
        let open = stored()
        let merged = stored(state: "MERGED", headerState: .merged)
        #expect(WorkspaceStatus.resolve(needsYou: true, failure: "x", working: true, unread: true, pullRequest: open) == .needsYou)
        #expect(WorkspaceStatus.resolve(needsYou: true, failure: nil, working: false, unread: false) == .needsYou)
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: "x", working: true, unread: true, pullRequest: open) == .failed("x"))
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: "x", working: false, unread: false) == .failed("x"))
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: nil, working: true, unread: true, pullRequest: merged) == .working)
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: nil, working: false, unread: true, pullRequest: open) == .unread)
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: nil, working: false, unread: false, pullRequest: open) == .pullRequest(tone: .passed))
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: nil, working: false, unread: false, pullRequest: merged) == .merged)
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: nil, working: false, unread: false, pullRequest: nil) == .idle)
    }

    /// WSC-02: creating and couldn't create come before needs you, since nothing else can apply then; setting up comes
    /// right after working, with the same spinner.
    @Test func creationStatesKeepTheOrder() {
        let open = stored()
        #expect(WorkspaceStatus.resolve(creating: "c", creationFailure: "f", needsYou: true, failure: "x", working: true, unread: true) == .creating("c"))
        #expect(WorkspaceStatus.resolve(creationFailure: "f", needsYou: true, failure: "x", working: true, unread: true) == .creationFailed("f"))
        #expect(WorkspaceStatus.resolve(needsYou: true, failure: nil, working: false, settingUp: "s", unread: false) == .needsYou)
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: "x", working: false, settingUp: "s", unread: false) == .failed("x"))
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: nil, working: true, settingUp: "s", unread: true) == .working)
        #expect(WorkspaceStatus.resolve(needsYou: false, failure: nil, working: false, settingUp: "s", unread: true, pullRequest: open) == .settingUp("s"))
        #expect(WorkspaceStatus.mostUrgent([.settingUp("s"), .unread, .creationFailed("f")]) == .creationFailed("f"))
        #expect(WorkspaceStatus.mostUrgent([.creating("c"), .needsYou]) == .creating("c"))
        #expect(WorkspaceStatus.mostUrgent([.unread, .settingUp("s"), .working]) == .working)

        #expect(WorkspaceStatus.creatingText(name: "lima", branch: "rocky/lima") == "Creating lima: fetching origin and checking out rocky/lima")
        #expect(WorkspaceStatus.creationFailedText(name: "lima", message: "fatal: no space\nhint: free some") == "Couldn't create lima: fatal: no space")
        let worktreeAdd = "Preparing worktree (new branch 'rocky/lima')\nfatal: could not create leading directories of 'lima/.git': Permission denied"
        #expect(WorkspaceStatus.creationFailedText(name: "lima", message: worktreeAdd) == "Couldn't create lima: fatal: could not create leading directories of 'lima/.git': Permission denied")
        #expect(WorkspaceStatus.creationFailedText(name: "lima", message: "one\ntwo") == "Couldn't create lima: two")
        #expect(WorkspaceStatus.settingUpText(name: "lima", step: .hook) == "Setting up lima: the post-checkout hook")
        #expect(WorkspaceStatus.settingUpText(name: "lima", step: .script) == "Setting up lima: the Setup script")
        #expect(WorkspaceStatus.settingUpText(name: "lima", step: nil) == "Setting up lima")
    }

    /// WSC-07: a workspace being removed shows only that, before everything else, with its two tooltips; the Remove and
    /// Archive messages end with the branch rule's sentence, and a branch without the `rocky/` prefix is kept.
    @Test func removalComesFirstWithItsTooltipsAndTheBranchSentence() {
        #expect(WorkspaceStatus.resolve(removing: "r", creating: "c", needsYou: true, failure: "x", working: true, unread: true) == .removing("r"))
        #expect(WorkspaceStatus.mostUrgent([.creating("c"), .needsYou, .removing("r")]) == .removing("r"))
        #expect(WorkspaceStatus.archivingText(name: "manila") == "Running manila's archive script")
        #expect(WorkspaceStatus.removingText(name: "manila") == "Removing manila…")
        #expect(AppModel.branchSentence(branch: "rocky/manila") == "The branch rocky/manila is deleted if all its commits are also on another branch, the remote or a tag; otherwise it is kept.")
        #expect(AppModel.branchSentence(branch: "fix/login") == "The branch fix/login is kept.")
    }

    @Test func aFoldedRepositoryShowsItsMostUrgentWorkspace() {
        #expect(WorkspaceStatus.mostUrgent([.working, .failed("setup"), .idle]) == .failed("setup"))
        #expect(WorkspaceStatus.mostUrgent([.idle, .unread]) == .unread)
        #expect(WorkspaceStatus.mostUrgent([.merged, .unread, .pullRequest(tone: .draft)]) == .unread)
        #expect(WorkspaceStatus.mostUrgent([.idle, .merged, .pullRequest(tone: .failed)]) == .pullRequest(tone: .failed))
        #expect(WorkspaceStatus.mostUrgent([.idle, .merged]) == .merged)
        #expect(WorkspaceStatus.mostUrgent([]) == .idle)
    }

    /// ROW-07's tone, in the design's order: a draft, then a failed check or conflicts, then a check running or
    /// waiting, else passed.
    @Test func pullRequestToneOrder() {
        #expect(PullRequestTone(stored(state: "DRAFT", headerState: .draftPR, checks: [.failed, .running])) == .draft)
        #expect(PullRequestTone(stored(headerState: .checksFailing, checks: [.running, .failed, .passed])) == .failed)
        #expect(PullRequestTone(stored(headerState: .mergeConflicts, checks: [.running])) == .failed)
        #expect(PullRequestTone(stored(headerState: .checksPending, checks: [.passed, .running])) == .running)
        #expect(PullRequestTone(stored(headerState: .checksPending, checks: [.pending])) == .running)
        #expect(PullRequestTone(stored(checks: [.passed, .other])) == .passed)
        #expect(PullRequestTone(stored()) == .passed)
    }
}
