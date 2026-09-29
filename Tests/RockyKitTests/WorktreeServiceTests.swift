import Foundation
import Testing
@testable import RockyKit

@Suite(.blockingWork)
struct WorktreeServiceTests {
    private let service = WorktreeService(environment: GitFixture.environment)

    @Test func worktreesLiveNextToTheRepo() {
        #expect(WorktreeService.worktreesRoot(for: URL(fileURLWithPath: "/Users/me/dev/app")).path == "/Users/me/dev/app-worktrees")
    }

    @Test func recognisesOnlyTheRepositoryRoot() throws {
        let parent = try Fixtures.temporaryDirectory("git")
        let repo = try GitFixture.localRepo(in: parent)
        let nested = repo.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(service.isRepositoryRoot(repo))
        #expect(!service.isRepositoryRoot(nested))
        #expect(!service.isRepositoryRoot(parent))
    }

    @Test func createsWorktreeFromCurrentBranchWhenThereIsNoOrigin() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("git"))
        let created = try service.create(repo: repo, name: "lisbon")
        #expect(created.baseRef == "main")
        #expect(created.branch == "rocky/lisbon")
        #expect(!created.fetchFailed)
        #expect(FileManager.default.fileExists(atPath: created.path.appendingPathComponent("README.md").path))
        #expect(try GitFixture.git(["rev-parse", "--abbrev-ref", "HEAD"], in: created.path) == "rocky/lisbon")
    }

    @Test func createsWorktreeFromOriginDefaultBranchNotTheCheckedOutOne() throws {
        let repo = try GitFixture.clonedRepo(in: try Fixtures.temporaryDirectory("git"))
        let created = try service.create(repo: repo, name: "kyoto")
        #expect(created.baseRef == "origin/trunk")
        #expect(!created.fetchFailed)
    }

    @Test func fetchFailureStillCreatesFromLastKnownRef() throws {
        let parent = try Fixtures.temporaryDirectory("git")
        let repo = try GitFixture.clonedRepo(in: parent)
        try FileManager.default.removeItem(at: parent.appendingPathComponent("origin.git"))
        let created = try service.create(repo: repo, name: "oslo")
        #expect(created.baseRef == "origin/trunk")
        #expect(created.fetchFailed)
    }

    @Test func repoWithoutCommitsThrowsInsteadOfCreating() throws {
        let repo = try Fixtures.temporaryDirectory("empty")
        try GitFixture.git(["init", "-q", "-b", "main"], in: repo)
        #expect(throws: ProcessFailure.self) { try service.create(repo: repo, name: "lima") }
    }

    @Test func nameIsTakenByDirectoryOrBranch() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("git"))
        _ = try service.create(repo: repo, name: "quito")
        #expect(service.isTaken(repo: repo, name: "quito"))
        try GitFixture.git(["branch", "rocky/cusco"], in: repo)
        #expect(service.isTaken(repo: repo, name: "cusco"))
        #expect(!service.isTaken(repo: repo, name: "hanoi"))
    }

    @Test func removeKeepsBranchAndRefusesDirtyWorktree() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("git"))
        let clean = try service.create(repo: repo, name: "dakar")
        try service.remove(repo: repo, worktree: clean.path)
        #expect(!FileManager.default.fileExists(atPath: clean.path.path))
        #expect(try GitFixture.git(["branch", "--list", "rocky/dakar"], in: repo).contains("rocky/dakar"))

        let dirty = try service.create(repo: repo, name: "accra")
        try Data("wip\n".utf8).write(to: dirty.path.appendingPathComponent("README.md"))
        #expect(throws: ProcessFailure.self) { try service.remove(repo: repo, worktree: dirty.path) }
        #expect(FileManager.default.fileExists(atPath: dirty.path.path))
    }

    /// User report, 2026-09-23: a fixed `ssh -o BatchMode=yes` overrode the repository's `core.sshCommand`. The ssh
    /// command of a run that reaches the remote is the one git would pick, in batch mode.
    @Test func batchSSHCommandKeepsTheCommandGitWouldRun() {
        let acme = "ssh -o IdentitiesOnly=yes -o IdentityFile=/Users/me/.ssh/id_rsa_work"
        #expect(WorktreeService.batchSSHCommand(inherited: nil, configured: nil) == "ssh -o BatchMode=yes")
        #expect(WorktreeService.batchSSHCommand(inherited: nil, configured: acme) == acme + " -o BatchMode=yes")
        #expect(WorktreeService.batchSSHCommand(inherited: "", configured: " \(acme)\n") == acme + " -o BatchMode=yes")
        // git's own order: GIT_SSH_COMMAND from the login shell wins over core.sshCommand.
        #expect(WorktreeService.batchSSHCommand(inherited: "ssh -i /k", configured: acme) == "ssh -i /k -o BatchMode=yes")
    }

    @Test func onlyRunsThatReachTheRemoteGetAnSSHCommand() throws {
        var environment = GitFixture.environment
        environment["GIT_SSH_COMMAND"] = nil
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("git"))
        let local = WorktreeService(environment: environment).environment
        #expect(local["GIT_SSH_COMMAND"] == nil)
        #expect(local["GIT_TERMINAL_PROMPT"] == "0")

        #expect(WorktreeService.configuredSSHCommand(in: repo, environment: local) == nil)
        #expect(WorktreeService.remoteEnvironment(local, in: repo)["GIT_SSH_COMMAND"] == "ssh -o BatchMode=yes")

        try GitFixture.git(["config", "core.sshCommand", "ssh -o IdentityFile=/Users/me/.ssh/id_rsa_work"], in: repo)
        #expect(WorktreeService.configuredSSHCommand(in: repo, environment: local) == "ssh -o IdentityFile=/Users/me/.ssh/id_rsa_work")
        let remote = WorktreeService.remoteEnvironment(local, in: repo)
        #expect(remote["GIT_SSH_COMMAND"] == "ssh -o IdentityFile=/Users/me/.ssh/id_rsa_work -o BatchMode=yes")
        #expect(remote["GIT_TERMINAL_PROMPT"] == "0")
    }

    /// The fetch before a new worktree goes out through the repository's `core.sshCommand`, in batch mode.
    @Test func fetchUsesTheRepositorysSSHCommand() throws {
        let parent = try Fixtures.temporaryDirectory("git")
        let repo = try GitFixture.clonedRepo(in: parent)
        let (script, record) = try Self.recordingSSH(in: parent)
        try GitFixture.git(["remote", "set-url", "origin", "ssh://git@example.invalid/acme-org/acme-platform.git"], in: repo)
        try GitFixture.git(["config", "core.sshCommand", "\(script.path) -o IdentitiesOnly=yes"], in: repo)
        var environment = GitFixture.environment
        environment["GIT_SSH_COMMAND"] = nil

        let created = try WorktreeService(environment: environment).create(repo: repo, name: "taipei")
        #expect(created.fetchFailed)
        #expect(created.baseRef == "origin/trunk")
        let arguments = try String(contentsOf: record, encoding: .utf8)
        #expect(arguments.hasPrefix("-o IdentitiesOnly=yes -o BatchMode=yes"))
        #expect(arguments.contains("example.invalid"))
    }

    /// A stand-in for ssh that writes its arguments to `record` and fails, as a host without access would.
    static func recordingSSH(in folder: URL) throws -> (script: URL, record: URL) {
        let script = folder.appendingPathComponent("fake-ssh")
        let record = folder.appendingPathComponent("ssh-arguments.txt")
        try Data("#!/bin/sh\necho \"$@\" > '\(record.path)'\nexit 255\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, record)
    }

    // MARK: Creating a workspace (WSC-04…WSC-06, KIT-18)

    /// A repository whose `.husky/post-checkout`, through `core.hooksPath` as acme-platform's, and whose default
    /// `.git/hooks/post-checkout` each write their arguments to a file in the folder they run in.
    static func repoWithHooks() throws -> URL {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("git"))
        let husky = repo.appendingPathComponent(".husky", isDirectory: true)
        try FileManager.default.createDirectory(at: husky, withIntermediateDirectories: true)
        try writeHook(#"echo "$@" > husky-ran.txt"#, to: husky.appendingPathComponent("post-checkout"))
        try GitFixture.git(["add", ".husky"], in: repo)
        try GitFixture.git(["commit", "-q", "-m", "hooks"], in: repo)
        try GitFixture.git(["config", "core.hooksPath", ".husky"], in: repo)
        try writeHook(#"echo "$@" > default-ran.txt"#, to: repo.appendingPathComponent(".git/hooks/post-checkout"))
        return repo
    }

    static func writeHook(_ body: String, to file: URL, executable: Bool = true) throws {
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
    }

    /// WSC-04: `git worktree add` runs no hook, so it returns once the checkout is done; Setup runs the hook instead.
    @Test func createRunsNoHook() throws {
        let repo = try Self.repoWithHooks()
        let created = try service.create(repo: repo, name: "lima")
        #expect(FileManager.default.fileExists(atPath: created.path.appendingPathComponent(".husky/post-checkout").path))
        #expect(!FileManager.default.fileExists(atPath: created.path.appendingPathComponent("husky-ran.txt").path))
        #expect(!FileManager.default.fileExists(atPath: created.path.appendingPathComponent("default-ran.txt").path))

        try GitFixture.git(["config", "--unset", "core.hooksPath"], in: repo)
        let plain = try service.create(repo: repo, name: "quito")
        #expect(!FileManager.default.fileExists(atPath: plain.path.appendingPathComponent("default-ran.txt").path))
    }

    /// WSC-05: the hook git would run, found through `core.hooksPath` in the worktree, else the main clone's shared
    /// hooks; a hook that is not executable is none, as git skips it.
    @Test func postCheckoutHookHonorsHooksPathAndSkipsANonExecutableOne() throws {
        let repo = try Self.repoWithHooks()
        let created = try service.create(repo: repo, name: "lima")
        let husky = created.path.appendingPathComponent(".husky/post-checkout")
        #expect(service.postCheckoutHook(worktree: created.path)?.resolvingSymlinksInPath() == husky.resolvingSymlinksInPath())
        let label = service.postCheckoutHook(worktree: created.path).map {
            SetupSteps.Hook.label(of: $0, worktree: created.path, mainClone: repo)
        }
        #expect(label == ".husky/post-checkout")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: husky.path)
        #expect(service.postCheckoutHook(worktree: created.path) == nil)

        try GitFixture.git(["config", "--unset", "core.hooksPath"], in: repo)
        let shared = try #require(service.postCheckoutHook(worktree: created.path))
        #expect(shared.resolvingSymlinksInPath() == repo.appendingPathComponent(".git/hooks/post-checkout").resolvingSymlinksInPath())
        #expect(SetupSteps.Hook.label(of: shared, worktree: created.path, mainClone: repo) == ".git/hooks/post-checkout")

        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git/hooks/post-checkout"))
        #expect(service.postCheckoutHook(worktree: created.path) == nil)
        #expect(try service.head(worktree: created.path) == GitFixture.git(["rev-parse", "HEAD"], in: repo))
    }

    /// WSC-06's Retry: a `rocky/<name>` a failed attempt made is checked out as it is, without `-b`.
    @Test func createReusesTheBranchAFailedAttemptMade() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("git"))
        let root = WorktreeService.worktreesRoot(for: repo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        #expect(throws: ProcessFailure.self) { try service.create(repo: repo, name: "lima") }
        #expect(try GitFixture.git(["branch", "--list", "rocky/lima"], in: repo).contains("rocky/lima"))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let retried = try service.create(repo: repo, name: "lima")
        #expect(try GitFixture.git(["rev-parse", "--abbrev-ref", "HEAD"], in: retried.path) == "rocky/lima")
        #expect(FileManager.default.fileExists(atPath: retried.path.appendingPathComponent("README.md").path))
    }

    /// WSC-06's Remove: the folder, a locked one git no longer has a folder for included, `worktree prune`, and the
    /// branch when it has no commits of its own; one with commits stays.
    @Test func cleanUpRemovesTheFolderAndTheEmptyBranch() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("git"))
        let made = try service.create(repo: repo, name: "lima")
        try service.cleanUp(repo: repo, path: made.path, branch: made.branch)
        #expect(!FileManager.default.fileExists(atPath: made.path.path))
        #expect(try GitFixture.git(["branch", "--list", "rocky/lima"], in: repo).isEmpty)
        #expect(try GitFixture.git(["worktree", "list", "--porcelain"], in: repo).components(separatedBy: "worktree ").count == 2)

        // A half-made one, as a stopped `worktree add` can leave it: locked, its folder gone.
        let locked = try service.create(repo: repo, name: "quito")
        try GitFixture.git(["worktree", "lock", "--reason", "initializing", locked.path.path], in: repo)
        try FileManager.default.removeItem(at: locked.path)
        try service.cleanUp(repo: repo, path: locked.path, branch: locked.branch)
        #expect(try GitFixture.git(["branch", "--list", "rocky/quito"], in: repo).isEmpty)
        #expect(!(try GitFixture.git(["worktree", "list"], in: repo)).contains("quito"))

        // Nothing of anyone's is lost: a branch with a commit of its own stays, and nil keeps the branch for Retry.
        let worked = try service.create(repo: repo, name: "cusco")
        try Data("mine\n".utf8).write(to: worked.path.appendingPathComponent("mine.txt"))
        try GitFixture.git(["add", "mine.txt"], in: worked.path)
        try GitFixture.git(["commit", "-q", "-m", "mine"], in: worked.path)
        try service.cleanUp(repo: repo, path: worked.path, branch: worked.branch)
        #expect(!FileManager.default.fileExists(atPath: worked.path.path))
        #expect(try GitFixture.git(["branch", "--list", "rocky/cusco"], in: repo).contains("rocky/cusco"))
        let kept = try service.create(repo: repo, name: "hanoi")
        try service.cleanUp(repo: repo, path: kept.path, branch: nil)
        #expect(try GitFixture.git(["branch", "--list", "rocky/hanoi"], in: repo).contains("rocky/hanoi"))
    }

    // MARK: Removing a workspace (WSC-07, KIT-19)

    /// A worktree of `repo` with one commit of its own on its `rocky/<name>`.
    private func worktreeWithACommit(in repo: URL, name: String) throws -> CreatedWorktree {
        let made = try service.create(repo: repo, name: name)
        try Data("\(name)\n".utf8).write(to: made.path.appendingPathComponent("\(name).txt"))
        try GitFixture.git(["add", "\(name).txt"], in: made.path)
        try GitFixture.git(["commit", "-q", "-m", name], in: made.path)
        return made
    }

    private func hasBranch(_ branch: String, in repo: URL) throws -> Bool {
        try !GitFixture.git(["branch", "--list", branch], in: repo).isEmpty
    }

    /// The user's rule of 2026-09-28, "Borrarla si está vacía": a `rocky/` branch goes when everything on it is also on
    /// another branch, a remote branch or a tag. Empty, pushed to its remote branch, or merged into a local branch.
    @Test func removeDeletesABranchWhoseCommitsAreAllElsewhere() throws {
        let repo = try GitFixture.clonedRepo(in: try Fixtures.temporaryDirectory("git"))

        let empty = try service.create(repo: repo, name: "lima")
        #expect(try service.remove(repo: repo, worktree: empty.path, branch: empty.branch) == .deleted)
        #expect(!FileManager.default.fileExists(atPath: empty.path.path))
        #expect(try !hasBranch("rocky/lima", in: repo))

        let pushed = try worktreeWithACommit(in: repo, name: "oslo")
        try GitFixture.git(["push", "-q", "origin", "rocky/oslo"], in: pushed.path)
        #expect(try service.remove(repo: repo, worktree: pushed.path, branch: pushed.branch) == .deleted)
        #expect(try !hasBranch("rocky/oslo", in: repo))
        #expect(try GitFixture.git(["branch", "-r", "--list", "origin/rocky/oslo"], in: repo).contains("origin/rocky/oslo"))

        let merged = try worktreeWithACommit(in: repo, name: "quito")
        try GitFixture.git(["merge", "-q", "--ff-only", "rocky/quito"], in: repo)
        #expect(try service.remove(repo: repo, worktree: merged.path, branch: merged.branch) == .deleted)
        #expect(try !hasBranch("rocky/quito", in: repo))
    }

    /// No commit is lost: one nowhere else keeps its branch, and a branch without the `rocky/` prefix (one GHL-05
    /// switched to, a pull request's) always stays, even with nothing of its own. A dirty worktree changes nothing.
    @Test func removeKeepsABranchWithACommitNowhereElseAndEveryOtherBranch() throws {
        let repo = try GitFixture.clonedRepo(in: try Fixtures.temporaryDirectory("git"))

        let worked = try worktreeWithACommit(in: repo, name: "cusco")
        #expect(try service.remove(repo: repo, worktree: worked.path, branch: worked.branch) == .kept(commits: 1))
        #expect(!FileManager.default.fileExists(atPath: worked.path.path))
        #expect(try hasBranch("rocky/cusco", in: repo))

        let switched = try service.create(repo: repo, name: "hanoi")
        try GitFixture.git(["switch", "-q", "-c", "fix/login", "origin/trunk"], in: switched.path)
        #expect(try service.remove(repo: repo, worktree: switched.path, branch: "fix/login") == .leftAlone)
        #expect(try hasBranch("fix/login", in: repo))

        let dirty = try service.create(repo: repo, name: "dakar")
        try Data("wip\n".utf8).write(to: dirty.path.appendingPathComponent("wip.txt"))
        #expect(throws: ProcessFailure.self) { try service.remove(repo: repo, worktree: dirty.path, branch: dirty.branch) }
        #expect(FileManager.default.fileExists(atPath: dirty.path.path))
        #expect(try hasBranch("rocky/dakar", in: repo))
    }

    /// A branch whose commits are all elsewhere but that git will not delete, checked out in the main clone, stays, and
    /// git's reason comes back; the worktree is removed all the same.
    @Test func removeKeepsABranchGitCannotDelete() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("git"))
        let made = try service.create(repo: repo, name: "accra")
        try GitFixture.git(["switch", "-q", "-c", "elsewhere"], in: made.path)
        try GitFixture.git(["switch", "-q", "rocky/accra"], in: repo)

        let outcome = try service.remove(repo: repo, worktree: made.path, branch: made.branch)
        guard case .notDeleted(let reason) = outcome else {
            Issue.record("expected .notDeleted, got \(outcome)")
            return
        }
        #expect(reason.contains("rocky/accra"))
        #expect(!FileManager.default.fileExists(atPath: made.path.path))
        #expect(try hasBranch("rocky/accra", in: repo))
    }

    /// WSC-06: a stopped creation runs no more git, and throws `CancellationError`.
    @Test func aStoppedCreationStartsNothing() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("git"))
        let stopper = ProcessStopper()
        stopper.stop()
        #expect(throws: CancellationError.self) { try service.create(repo: repo, name: "lima", stopper: stopper) }
        #expect(!FileManager.default.fileExists(atPath: WorktreeService.worktreesRoot(for: repo).appendingPathComponent("lima").path))
        #expect(try GitFixture.git(["branch", "--list", "rocky/lima"], in: repo).isEmpty)
    }

    @Test func namerSkipsTakenNamesAndFallsBackToSuffix() {
        let identity: ([String]) -> [String] = { $0 }
        #expect(WorkspaceNamer.pick(isTaken: { $0 == "lisbon" }, order: identity) == "kyoto")
        #expect(WorkspaceNamer.pick(isTaken: { !$0.hasSuffix("-2") || $0 == "lisbon-2" }, order: identity) == "kyoto-2")
    }
}
