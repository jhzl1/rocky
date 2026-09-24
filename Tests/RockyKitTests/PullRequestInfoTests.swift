import Foundation
import Testing
@testable import RockyKit

struct PullRequestInfoTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func pullRequest(checks: [PullRequestCheck] = [], deployments: [PullRequestDeployment] = []) -> PullRequestInfo {
        PullRequestInfo(
            id: "PR_1", number: 1, url: URL(string: "https://github.com/o/n/pull/1")!,
            baseRefName: "development", headRefName: "rocky/tokyo", checks: checks, deployments: deployments
        )
    }

    // MARK: Check states (CHK-01)

    @Test func checkRunStatesFollowCHK01() {
        #expect(CheckState.checkRun(status: "IN_PROGRESS", conclusion: nil) == .running)
        for status in ["QUEUED", "REQUESTED", "WAITING", "PENDING"] {
            #expect(CheckState.checkRun(status: status, conclusion: nil) == .pending)
        }
        for conclusion in ["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"] {
            #expect(CheckState.checkRun(status: "COMPLETED", conclusion: conclusion) == .failed)
        }
        for conclusion in ["SUCCESS", "NEUTRAL", "SKIPPED"] {
            #expect(CheckState.checkRun(status: "COMPLETED", conclusion: conclusion) == .passed)
        }
        // In none of CHK-01's sets: its "anything else" dot.
        for conclusion in ["STALE", "STARTUP_FAILURE"] {
            #expect(CheckState.checkRun(status: "COMPLETED", conclusion: conclusion) == .other)
        }
        #expect(CheckState.checkRun(status: "COMPLETED", conclusion: nil) == .other)
    }

    @Test func statusContextStatesFollowCHK01() {
        #expect(CheckState.statusContext(state: "PENDING") == .pending)
        #expect(CheckState.statusContext(state: "EXPECTED") == .pending)
        #expect(CheckState.statusContext(state: "FAILURE") == .failed)
        #expect(CheckState.statusContext(state: "ERROR") == .failed)
        #expect(CheckState.statusContext(state: "SUCCESS") == .passed)
        #expect(CheckState.statusContext(state: nil) == .other)
    }

    // MARK: Order and dedupe

    @Test func failedChecksComeFirstThenRunningThenTheAPIsOrder() {
        let names: [(String, CheckState)] = [
            ("build", .passed), ("lint", .running), ("e2e", .failed), ("docs", .pending), ("unit", .failed), ("vercel", .running),
        ]
        let pr = pullRequest(checks: names.map { PullRequestCheck(name: $0.0, state: $0.1) })
        #expect(pr.orderedChecks.map(\.name) == ["e2e", "unit", "lint", "vercel", "build", "docs"])
    }

    @Test func latestDeploymentIsTheFirstOfEachEnvironment() {
        let pr = pullRequest(deployments: [
            PullRequestDeployment(environment: "Preview", state: "IN_PROGRESS"),
            PullRequestDeployment(environment: "Production", state: "SUCCESS"),
            PullRequestDeployment(environment: "Preview", state: "SUCCESS"),
            PullRequestDeployment(environment: "Production", state: "FAILURE"),
        ])
        #expect(pr.latestDeployments == [
            PullRequestDeployment(environment: "Preview", state: "IN_PROGRESS"),
            PullRequestDeployment(environment: "Production", state: "SUCCESS"),
        ])
    }

    // MARK: Durations

    @Test func finishedDurations() {
        #expect(CheckDuration.text(start: start, end: start.addingTimeInterval(3840), now: start) == "1h 4m")
        #expect(CheckDuration.text(start: start, end: start.addingTimeInterval(200), now: start) == "3m")
        #expect(CheckDuration.text(start: start, end: start.addingTimeInterval(45), now: start) == "45s")
        #expect(CheckDuration.text(start: nil, end: start, now: start) == nil)
    }

    @Test func runningDurationsCountFromTheStart() {
        #expect(CheckDuration.text(start: start, end: nil, now: start.addingTimeInterval(20)) == "<1m")
        #expect(CheckDuration.text(start: start, end: nil, now: start.addingTimeInterval(200)) == "3m")
        #expect(CheckDuration.text(start: start, end: nil, now: start.addingTimeInterval(3900)) == "1h 5m")
    }

    // MARK: Merge methods (PR-05)

    @Test func methodsKeepTheOrderSquashRebaseMerge() {
        let all = RepositorySettings(id: "R", squashMergeAllowed: true, rebaseMergeAllowed: true, mergeCommitAllowed: true)
        #expect(MergeMethods.available(repository: all) == [.squash, .rebase, .merge])
        let noSquash = RepositorySettings(id: "R", squashMergeAllowed: false, rebaseMergeAllowed: true, mergeCommitAllowed: true)
        #expect(MergeMethods.available(repository: noSquash) == [.rebase, .merge])
        #expect(MergeMethods.initial(available: [.squash, .rebase, .merge], viewerDefault: nil) == .squash)
    }

    @Test func oneAllowedMethodIsTheOnlyChoice() {
        let onlyMerge = RepositorySettings(id: "R", squashMergeAllowed: false, rebaseMergeAllowed: false, mergeCommitAllowed: true)
        let available = MergeMethods.available(repository: onlyMerge)
        #expect(available == [.merge])
        #expect(MergeMethods.initial(available: available, viewerDefault: .squash) == .merge)
    }

    @Test func theViewersDefaultWinsOnlyWhenAllowed() {
        #expect(MergeMethods.initial(available: [.squash, .rebase, .merge], viewerDefault: .rebase) == .rebase)
        #expect(MergeMethods.initial(available: [.rebase, .merge], viewerDefault: .squash) == .rebase)
    }
}
