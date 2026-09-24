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
