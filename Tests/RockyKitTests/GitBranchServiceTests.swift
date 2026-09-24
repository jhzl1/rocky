import Foundation
import Testing
@testable import RockyKit

/// `GST-01`…`GST-03` on temporary clones of a bare origin (`GitFixture.clonedRepo`: default branch `trunk`, the clone
/// on `feature` without an upstream).
@Suite(.blockingWork)
struct GitBranchServiceTests {
    private let service = GitBranchService(environment: GitFixture.environment)

    private func commit(_ file: String, in repo: URL) throws {
        try Data("\(file)\n".utf8).write(to: repo.appendingPathComponent(file))
        try GitFixture.git(["add", file], in: repo)
        try GitFixture.git(["commit", "-q", "-m", "add \(file)"], in: repo)
    }

    /// A second clone of the fixture's origin, checked out on `branch`: someone else pushing.
    private func otherClone(in parent: URL, branch: String) throws -> URL {
        try GitFixture.git(["clone", "-q", "-b", branch, parent.appendingPathComponent("origin.git").path, "other"], in: parent)
        return parent.appendingPathComponent("other", isDirectory: true)
    }

    private func head(_ repo: URL, _ ref: String = "HEAD") throws -> String {
        try GitFixture.git(["rev-parse", ref], in: repo)
    }

    @Test func parseReadsEveryEntryType() {
        let output = """
            # branch.oid 1f6a3c0e9d2b4a5f8e7d6c5b4a3f2e1d0c9b8a7f
            # branch.head rocky/tokyo
            # branch.upstream origin/rocky/tokyo
            # branch.ab +2 -3
            1 .M N... 100644 100644 100644 1111111 1111111 README.md
            1 A. N... 000000 100644 100644 0000000 2222222 Sources/New.swift
            2 R. N... 100644 100644 100644 3333333 3333333 R100 Sources/Renamed.swift\tSources/Old.swift
            u UU N... 100644 100644 100644 100644 4444444 5555555 6666666 Conflict.swift
            ? notes.txt
            ! build.log
            """
        let status = LocalGitStatus.parse(porcelainV2: output)
        #expect(status.branch == "rocky/tokyo")
        #expect(status.upstream == "origin/rocky/tokyo")
        #expect(status.uncommitted == 5)
        #expect(status.ahead == 2)
        #expect(status.behind == 3)
        #expect(status.isIncompatible)
        #expect(!status.remoteWasRebased)
    }

    @Test func parseReadsADetachedHeadWithoutUpstream() {
        let status = LocalGitStatus.parse(porcelainV2: "# branch.oid 1f6a3c0e\n# branch.head (detached)\n")
        #expect(status == LocalGitStatus())
    }

    @Test func countsUncommittedAheadBehindAndAheadOfBase() throws {
        let parent = try Fixtures.temporaryDirectory("branch")
        let repo = try GitFixture.clonedRepo(in: parent)
        try commit("one.txt", in: repo)
        try service.push(worktree: repo, hasUpstream: false)
        try commit("two.txt", in: repo)
        try Data("changed\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        try Data("new\n".utf8).write(to: repo.appendingPathComponent("untracked.txt"))

        let status = try service.status(worktree: repo, base: "origin/trunk")
        #expect(status.branch == "feature")
        #expect(status.upstream == "origin/feature")
        #expect(status.uncommitted == 2)
        #expect(status.ahead == 1)
        #expect(status.behind == 0)
        #expect(status.commitsAheadOfBase == 2)
        #expect(!status.isIncompatible)

        // Behind counts what the last fetch brought.
        let other = try otherClone(in: parent, branch: "feature")
        try commit("three.txt", in: other)
        try GitFixture.git(["push", "-q"], in: other)
        #expect(try service.status(worktree: repo, base: "origin/trunk").behind == 0)
        try service.fetch(worktree: repo, branch: "feature")
        let fetched = try service.status(worktree: repo, base: "origin/trunk")
        #expect(fetched.ahead == 1)
        #expect(fetched.behind == 1)
        #expect(fetched.isIncompatible)
        #expect(!fetched.remoteWasRebased)
    }

    @Test func withoutAnUpstreamAheadCountsTheCommitsOnNoOriginBranch() throws {
        let repo = try GitFixture.clonedRepo(in: try Fixtures.temporaryDirectory("branch"))
        try commit("one.txt", in: repo)
        try commit("two.txt", in: repo)

        let status = try service.status(worktree: repo, base: "origin/trunk")
        #expect(status.upstream == nil)
        #expect(status.ahead == 2)
        #expect(status.behind == 0)
        #expect(status.commitsAheadOfBase == 2)

        // No base: counted from origin's default branch.
        #expect(try service.status(worktree: repo, base: nil).commitsAheadOfBase == 2)
    }

    /// Open question 4: ahead and behind at once after a forced update of the remote branch.
    @Test func aRewrittenRemoteBranchIsIncompatibleAndSaysItWasRebased() throws {
        let parent = try Fixtures.temporaryDirectory("branch")
        let repo = try GitFixture.clonedRepo(in: parent)
        try commit("one.txt", in: repo)
        try service.push(worktree: repo, hasUpstream: false)

        // The fixture itself force-pushes a rewritten commit; Rocky never does.
        let other = try otherClone(in: parent, branch: "feature")
        try GitFixture.git(["commit", "-q", "--amend", "-m", "rewritten"], in: other)
        try GitFixture.git(["push", "-q", "--force"], in: other)
        try service.fetch(worktree: repo, branch: "feature")

        let status = try service.status(worktree: repo, base: "origin/trunk")
        #expect(status.ahead == 1)
        #expect(status.behind == 1)
        #expect(status.isIncompatible)
        #expect(status.remoteWasRebased)
    }

    @Test func pushWithoutAnUpstreamSetsOne() throws {
        let parent = try Fixtures.temporaryDirectory("branch")
        let repo = try GitFixture.clonedRepo(in: parent)
        try commit("one.txt", in: repo)

        try service.push(worktree: repo, hasUpstream: false)
        #expect(try GitFixture.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo) == "origin/feature")
        #expect(try head(parent.appendingPathComponent("origin.git"), "refs/heads/feature") == head(repo))
        #expect(try service.status(worktree: repo, base: "origin/trunk").ahead == 0)
    }

    @Test func aRejectedPushIsNonFastForward() throws {
        let parent = try Fixtures.temporaryDirectory("branch")
        let repo = try GitFixture.clonedRepo(in: parent)
        try commit("one.txt", in: repo)
        try service.push(worktree: repo, hasUpstream: false)
        let other = try otherClone(in: parent, branch: "feature")
        try commit("theirs.txt", in: other)
        try GitFixture.git(["push", "-q"], in: other)
        try commit("mine.txt", in: repo)

        // Not fetched yet: git says "(fetch first)".
        #expect(throws: GitBranchError.nonFastForward) { try service.push(worktree: repo, hasUpstream: true) }
        // Fetched: git says "(non-fast-forward)".
        try service.fetch(worktree: repo, branch: "feature")
        #expect(throws: GitBranchError.nonFastForward) { try service.push(worktree: repo, hasUpstream: true) }
        #expect(GitBranchError.nonFastForward.description == "The remote has new commits. Pull first.")
    }

    @Test func pullFastForwardsTheBranch() throws {
        let parent = try Fixtures.temporaryDirectory("branch")
        let repo = try GitFixture.clonedRepo(in: parent)
        try commit("one.txt", in: repo)
        try service.push(worktree: repo, hasUpstream: false)
        let other = try otherClone(in: parent, branch: "feature")
        try commit("theirs.txt", in: other)
        try GitFixture.git(["push", "-q"], in: other)

        try service.pull(worktree: repo)
        #expect(try head(repo) == head(other))
        #expect(try service.status(worktree: repo, base: "origin/trunk").behind == 0)
    }

    @Test func otherFailuresCarryTheLastLinesOfStderr() throws {
        let repo = try GitFixture.clonedRepo(in: try Fixtures.temporaryDirectory("branch"))
        do {
            try service.fetch(worktree: repo, branch: "no-such-branch")
            Issue.record("fetching a missing branch succeeded")
        } catch GitBranchError.failed(let tail) {
            #expect(tail.contains("no-such-branch"))
            #expect(tail.split(separator: "\n").count <= 3)
        }
    }

    /// Pull, push and fetch reach the remote through the worktree's `core.sshCommand`, in batch mode, not over it (user
    /// report, 2026-09-23).
    @Test func remoteRunsUseTheWorktreesSSHCommand() throws {
        let parent = try Fixtures.temporaryDirectory("branch")
        let repo = try GitFixture.clonedRepo(in: parent)
        let (script, record) = try WorktreeServiceTests.recordingSSH(in: parent)
        try GitFixture.git(["remote", "set-url", "origin", "ssh://git@example.invalid/celes-app/celes-platform.git"], in: repo)
        try GitFixture.git(["config", "core.sshCommand", "\(script.path) -o IdentitiesOnly=yes"], in: repo)
        var environment = GitFixture.environment
        environment["GIT_SSH_COMMAND"] = nil
        let service = GitBranchService(environment: environment)
        #expect(service.environment["GIT_SSH_COMMAND"] == nil)

        #expect(throws: GitBranchError.self) { try service.fetch(worktree: repo, branch: "trunk") }
        #expect(try String(contentsOf: record, encoding: .utf8).hasPrefix("-o IdentitiesOnly=yes -o BatchMode=yes"))
        try FileManager.default.removeItem(at: record)

        #expect(throws: GitBranchError.self) { try service.push(worktree: repo, hasUpstream: false) }
        #expect(try String(contentsOf: record, encoding: .utf8).hasPrefix("-o IdentitiesOnly=yes -o BatchMode=yes"))
    }

    @Test func stderrTailsCarryNoToken() {
        let failure = ProcessFailure(
            command: "git push",
            status: 128,
            stderr: "remote: Invalid username or password.\nfatal: Authentication failed for 'https://x:ghp_abcdef1234567890@github.com/o/n.git/'"
        )
        let error = GitBranchService.branchError(failure)
        #expect(error == .failed(stderrTail: "remote: Invalid username or password.\nfatal: Authentication failed for 'https://x:[token]@github.com/o/n.git/'"))
    }

    /// GST-02: only a branch with no commits of its own fast-forwards; a diverged one is refused.
    @Test func fastForwardMovesOnlyABranchThatIsBehind() throws {
        let parent = try Fixtures.temporaryDirectory("branch")
        let repo = try GitFixture.clonedRepo(in: parent)
        let other = try otherClone(in: parent, branch: "trunk")
        try commit("base-one.txt", in: other)
        try GitFixture.git(["push", "-q"], in: other)

        try service.fetch(worktree: repo, branch: "trunk")
        #expect(try service.ownCommits(worktree: repo, since: "origin/trunk") == 0)
        try service.fastForward(worktree: repo, to: "origin/trunk")
        #expect(try head(repo) == head(repo, "origin/trunk"))

        try commit("mine.txt", in: repo)
        try commit("base-two.txt", in: other)
        try GitFixture.git(["push", "-q"], in: other)
        try service.fetch(worktree: repo, branch: "trunk")
        #expect(try service.ownCommits(worktree: repo, since: "origin/trunk") == 1)
        let before = try head(repo)
        #expect(throws: GitBranchError.self) { try service.fastForward(worktree: repo, to: "origin/trunk") }
        #expect(try head(repo) == before)
        #expect(try GitFixture.git(["rev-list", "--merges", "--count", "HEAD"], in: repo) == "0")
    }

    @Test func prefersRebaseReadsTheConfig() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("branch"))
        #expect(!service.prefersRebase(worktree: repo))
        for (value, rebases) in [("true", true), ("merges", true), ("interactive", true), ("false", false)] {
            try GitFixture.git(["config", "pull.rebase", value], in: repo)
            #expect(service.prefersRebase(worktree: repo) == rebases, "pull.rebase \(value)")
        }
    }

    @Test func remoteBranchOidIsTheLastFetchedHead() throws {
        let parent = try Fixtures.temporaryDirectory("branch")
        let repo = try GitFixture.clonedRepo(in: parent)
        #expect(service.remoteBranchOid(worktree: repo, branch: "feature") == nil)
        try commit("one.txt", in: repo)
        try service.push(worktree: repo, hasUpstream: false)
        #expect(try service.remoteBranchOid(worktree: repo, branch: "feature") == head(repo))
    }
}
