import Foundation
import Testing
@testable import RockyKit

/// `KIT-15` on temporary clones of a bare origin (`GitFixture.clonedRepo`: default branch `trunk`, the clone on
/// `feature`, no network).
@Suite(.blockingWork)
struct BranchLinksTests {
    private let service = GitBranchService(environment: GitFixture.environment)

    private func commit(_ file: String, in repo: URL, message: String? = nil) throws {
        try Data("\(file)\n".utf8).write(to: repo.appendingPathComponent(file))
        try GitFixture.git(["add", file], in: repo)
        try GitFixture.git(["commit", "-q", "-m", message ?? "add \(file)"], in: repo)
    }

    /// Someone else pushing `branch` to origin, with one commit on top of `trunk`.
    private func push(_ branch: String, in parent: URL) throws {
        let other = parent.appendingPathComponent("other-\(UUID().uuidString)", isDirectory: true)
        try GitFixture.git(["clone", "-q", "-b", "trunk", parent.appendingPathComponent("origin.git").path, other.path], in: parent)
        try GitFixture.git(["switch", "-q", "-c", branch], in: other)
        try commit("\(branch.replacingOccurrences(of: "/", with: "-")).txt", in: other)
        try GitFixture.git(["push", "-q", "origin", branch], in: other)
    }

    private func currentBranch(_ repo: URL) throws -> String {
        try GitFixture.git(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)
    }

    private func hasLocalBranch(_ name: String, in repo: URL) -> Bool {
        (try? GitFixture.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: repo)) != nil
    }

    // MARK: Listing (GHL-03)

    /// Local branches, the remote ones only on origin, once each, without origin/HEAD, with the worktree holding each.
    @Test func branchesAreLocalAndRemoteOnceEachWithTheirHolders() throws {
        let parent = try Fixtures.temporaryDirectory("links")
        let repo = try GitFixture.clonedRepo(in: parent)
        try push("feat/look-and-feel-3", in: parent)
        try service.fetchPruning(worktree: repo)
        let held = parent.appendingPathComponent("app-worktrees/tokyo", isDirectory: true)
        try GitFixture.git(["worktree", "add", "-q", "-b", "rocky/tokyo", held.path, "trunk"], in: repo)

        let branches = try service.branches(worktree: repo)
        #expect(Set(branches.map(\.id)) == ["trunk", "feature", "rocky/tokyo", "origin/feat/look-and-feel-3"])
        let byName = Dictionary(uniqueKeysWithValues: branches.map { ($0.name, $0) })
        #expect(byName["trunk"]?.upstream == "origin/trunk")
        #expect(byName["trunk"]?.isRemoteOnly == false)
        #expect(byName["trunk"]?.heldBy == nil)
        #expect(byName["feature"]?.upstream == nil)
        #expect(byName["feature"].flatMap(\.heldBy).map { BranchLinks.samePath($0, repo) } == true)
        #expect(byName["rocky/tokyo"].flatMap(\.heldBy).map { BranchLinks.samePath($0, held) } == true)
        let remote = try #require(byName["feat/look-and-feel-3"])
        #expect(remote.isRemoteOnly)
        #expect(remote.upstream == "origin/feat/look-and-feel-3")
        #expect(remote.heldBy == nil)
    }

    /// git's order stays; a remote branch with a local one shows once, as local; origin/HEAD is left out.
    @Test func forEachRefKeepsGitsOrderAndPrefersTheLocalBranch() {
        let output = """
            refs/remotes/origin/fix/pr\t
            refs/heads/trunk\torigin/trunk
            refs/remotes/origin/HEAD\t
            refs/remotes/origin/trunk\t
            refs/heads/rocky/lima\t
            """
        let holders = ["rocky/lima": URL(fileURLWithPath: "/w/app-worktrees/lima")]
        #expect(BranchLinks.branches(forEachRef: output, holders: holders) == [
            BranchRef(name: "fix/pr", isRemoteOnly: true, upstream: "origin/fix/pr", heldBy: nil),
            BranchRef(name: "trunk", isRemoteOnly: false, upstream: "origin/trunk", heldBy: nil),
            BranchRef(name: "rocky/lima", isRemoteOnly: false, upstream: nil, heldBy: URL(fileURLWithPath: "/w/app-worktrees/lima")),
        ])
    }

    @Test func worktreeListNamesEachCheckedOutBranch() {
        let output = """
            worktree /Users/me/dev/app
            HEAD 1f6a3c0e9d2b4a5f8e7d6c5b4a3f2e1d0c9b8a7f
            branch refs/heads/development

            worktree /Users/me/dev/app-worktrees/tokyo
            HEAD 2f6a3c0e9d2b4a5f8e7d6c5b4a3f2e1d0c9b8a7f
            branch refs/heads/jhzl/openapi-export

            worktree /Users/me/dev/app-worktrees/oslo
            HEAD 3f6a3c0e9d2b4a5f8e7d6c5b4a3f2e1d0c9b8a7f
            detached

            """
        #expect(BranchLinks.holders(porcelain: output) == [
            "development": URL(fileURLWithPath: "/Users/me/dev/app", isDirectory: true),
            "jhzl/openapi-export": URL(fileURLWithPath: "/Users/me/dev/app-worktrees/tokyo", isDirectory: true),
        ])
    }

    /// GHL-02's reasons: the current branch, and one another worktree holds, named from the worktrees' folder.
    @Test func unavailableRowsSayWhy() {
        let main = URL(fileURLWithPath: "/Users/me/dev/celes-platform")
        let lima = URL(fileURLWithPath: "/Users/me/dev/celes-platform-worktrees/lima")
        let tokyo = URL(fileURLWithPath: "/Users/me/dev/celes-platform-worktrees/tokyo")
        #expect(BranchLinks.unavailableReason(heldBy: nil, worktree: lima, mainClone: main) == nil)
        #expect(BranchLinks.unavailableReason(heldBy: lima, worktree: lima, mainClone: main) == "Current branch")
        #expect(BranchLinks.unavailableReason(heldBy: tokyo, worktree: lima, mainClone: main) == "Checked out in celes-platform-worktrees/tokyo")
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/celes-platform")
        #expect(BranchLinks.holderLabel(home, mainClone: home) == "~/dev/celes-platform")
    }

    // MARK: Switching (GHL-05)

    /// A local branch: `git switch`, and the workspace's own empty branch deleted.
    @Test func switchesToALocalBranchAndDeletesTheOwnBranch() throws {
        let repo = try GitFixture.clonedRepo(in: try Fixtures.temporaryDirectory("links"))
        try GitFixture.git(["branch", "feat/local", "trunk"], in: repo)

        #expect(try service.switchTo(.local("feat/local"), worktree: repo, dropping: "feature"))
        #expect(try currentBranch(repo) == "feat/local")
        #expect(!hasLocalBranch("feature", in: repo))
    }

    /// A branch only on origin: `git switch --track`, which creates the local branch tracking it.
    @Test func switchingToARemoteBranchTracksIt() throws {
        let parent = try Fixtures.temporaryDirectory("links")
        let repo = try GitFixture.clonedRepo(in: parent)
        try push("feat/remote", in: parent)
        try service.fetchPruning(worktree: repo)

        try service.switchTo(.remote("feat/remote"), worktree: repo, dropping: nil)
        #expect(try currentBranch(repo) == "feat/remote")
        #expect(try GitFixture.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo) == "origin/feat/remote")
        // Nothing to drop: `feature` stays.
        #expect(hasLocalBranch("feature", in: repo))
    }

    /// A pull request's head is fetched first, then tracked, without an earlier fetch of it.
    @Test func switchingToAPullRequestFetchesItsHead() throws {
        let parent = try Fixtures.temporaryDirectory("links")
        let repo = try GitFixture.clonedRepo(in: parent)
        try push("fix/test-pr-validation", in: parent)

        #expect(try service.switchTo(.pullRequest(head: "fix/test-pr-validation"), worktree: repo, dropping: "feature"))
        #expect(try currentBranch(repo) == "fix/test-pr-validation")
        #expect(try GitFixture.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo) == "origin/fix/test-pr-validation")
        #expect(!hasLocalBranch("feature", in: repo))
    }

    /// git refuses a branch another worktree holds; the worktree and the own branch stay as they were.
    @Test func aBranchAnotherWorktreeHoldsIsRefused() throws {
        let parent = try Fixtures.temporaryDirectory("links")
        let repo = try GitFixture.clonedRepo(in: parent)
        let held = parent.appendingPathComponent("app-worktrees/tokyo", isDirectory: true)
        try GitFixture.git(["worktree", "add", "-q", "-b", "jhzl/openapi-export", held.path, "trunk"], in: repo)

        #expect(throws: GitBranchError.self) { try service.switchTo(.local("jhzl/openapi-export"), worktree: repo, dropping: "feature") }
        #expect(try currentBranch(repo) == "feature")
        #expect(hasLocalBranch("feature", in: repo))
    }

    /// `branch -D` deletes an empty branch that `-d` would refuse: made from a base newer than the branch switched to,
    /// the new HEAD does not contain it.
    @Test func deletingTheEmptyOwnBranchNeedsNoMerge() throws {
        let parent = try Fixtures.temporaryDirectory("links")
        let repo = try GitFixture.clonedRepo(in: parent)
        try push("feat/elsewhere", in: parent)
        // trunk moves on after feat/elsewhere left it.
        let other = parent.appendingPathComponent("trunk-mover", isDirectory: true)
        try GitFixture.git(["clone", "-q", "-b", "trunk", parent.appendingPathComponent("origin.git").path, other.path], in: parent)
        try commit("newer.txt", in: other)
        try GitFixture.git(["push", "-q", "origin", "trunk"], in: other)
        try service.fetchPruning(worktree: repo)
        try GitFixture.git(["switch", "-q", "--no-track", "-c", "rocky/lima", "origin/trunk"], in: repo)
        try GitFixture.git(["switch", "-q", "--track", "origin/feat/elsewhere"], in: repo)
        #expect(throws: (any Error).self) { try GitFixture.git(["branch", "-d", "rocky/lima"], in: repo) }

        try service.deleteBranch("rocky/lima", worktree: repo)
        #expect(!hasLocalBranch("rocky/lima", in: repo))
        #expect(throws: GitBranchError.self) { try service.deleteBranch("-D", worktree: repo) }
    }

    /// GHL-05's branch file: the last 20 commits the base lacks, newest first, and how many in all.
    @Test func theLogIsTheLastTwentyCommitsTheBaseLacks() throws {
        let repo = try GitFixture.clonedRepo(in: try Fixtures.temporaryDirectory("links"))
        for index in 1...22 {
            try commit("file-\(index).txt", in: repo, message: "Step \(index)")
        }

        let log = try service.commits(of: "feature", notIn: "origin/trunk", worktree: repo)
        #expect(log.total == 22)
        #expect(log.lines.count == 20)
        let newest = try #require(log.lines.first)
        #expect(newest.hasSuffix(" Step 22"))
        let hash = try GitFixture.git(["rev-parse", "--short", "HEAD"], in: repo)
        #expect(newest == "\(hash) Step 22")
        #expect(log.lines.last?.hasSuffix(" Step 3") == true)

        let none = try service.commits(of: "trunk", notIn: "origin/trunk", worktree: repo)
        #expect(none.lines.isEmpty)
        #expect(none.total == 0)
    }

    /// KIT-15: only a workspace with nothing of its own can switch.
    @Test func canSwitchOnlyWithNothingOfItsOwn() {
        #expect(GitBranchService.canSwitch(status: LocalGitStatus(), unsavedEdits: false))
        #expect(!GitBranchService.canSwitch(status: LocalGitStatus(uncommitted: 1), unsavedEdits: false))
        #expect(!GitBranchService.canSwitch(status: LocalGitStatus(commitsAheadOfBase: 2), unsavedEdits: false))
        #expect(!GitBranchService.canSwitch(status: LocalGitStatus(), unsavedEdits: true))
        // Commits the upstream lacks but the base has are not the workspace's own.
        #expect(GitBranchService.canSwitch(status: LocalGitStatus(ahead: 3), unsavedEdits: false))
    }

    /// The fetches go through the repository's own ssh command, in batch mode (`remoteEnvironment`).
    @Test func fetchesUseTheRepositorysSSHCommand() throws {
        let parent = try Fixtures.temporaryDirectory("links")
        let repo = try GitFixture.clonedRepo(in: parent)
        let (script, record) = try WorktreeServiceTests.recordingSSH(in: parent)
        try GitFixture.git(["remote", "set-url", "origin", "ssh://git@example.invalid/jhzl1/app.git"], in: repo)
        try GitFixture.git(["config", "core.sshCommand", "\(script.path) -o IdentitiesOnly=yes"], in: repo)
        var environment = GitFixture.environment
        environment["GIT_SSH_COMMAND"] = nil
        let service = GitBranchService(environment: environment)

        #expect(throws: GitBranchError.self) { try service.fetchPruning(worktree: repo) }
        #expect(try String(contentsOf: record, encoding: .utf8).hasPrefix("-o IdentitiesOnly=yes -o BatchMode=yes"))
        try FileManager.default.removeItem(at: record)

        #expect(throws: GitBranchError.self) { try service.switchTo(.pullRequest(head: "fix/x"), worktree: repo, dropping: "feature") }
        #expect(try String(contentsOf: record, encoding: .utf8).hasPrefix("-o IdentitiesOnly=yes -o BatchMode=yes"))
        #expect(try currentBranch(repo) == "feature")
        #expect(hasLocalBranch("feature", in: repo))
    }
}
