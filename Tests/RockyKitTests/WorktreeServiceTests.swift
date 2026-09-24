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
        let celes = "ssh -o IdentitiesOnly=yes -o IdentityFile=/Users/me/.ssh/id_rsa_celes"
        #expect(WorktreeService.batchSSHCommand(inherited: nil, configured: nil) == "ssh -o BatchMode=yes")
        #expect(WorktreeService.batchSSHCommand(inherited: nil, configured: celes) == celes + " -o BatchMode=yes")
        #expect(WorktreeService.batchSSHCommand(inherited: "", configured: " \(celes)\n") == celes + " -o BatchMode=yes")
        // git's own order: GIT_SSH_COMMAND from the login shell wins over core.sshCommand.
        #expect(WorktreeService.batchSSHCommand(inherited: "ssh -i /k", configured: celes) == "ssh -i /k -o BatchMode=yes")
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

        try GitFixture.git(["config", "core.sshCommand", "ssh -o IdentityFile=/Users/me/.ssh/id_rsa_celes"], in: repo)
        #expect(WorktreeService.configuredSSHCommand(in: repo, environment: local) == "ssh -o IdentityFile=/Users/me/.ssh/id_rsa_celes")
        let remote = WorktreeService.remoteEnvironment(local, in: repo)
        #expect(remote["GIT_SSH_COMMAND"] == "ssh -o IdentityFile=/Users/me/.ssh/id_rsa_celes -o BatchMode=yes")
        #expect(remote["GIT_TERMINAL_PROMPT"] == "0")
    }

    /// The fetch before a new worktree goes out through the repository's `core.sshCommand`, in batch mode.
    @Test func fetchUsesTheRepositorysSSHCommand() throws {
        let parent = try Fixtures.temporaryDirectory("git")
        let repo = try GitFixture.clonedRepo(in: parent)
        let (script, record) = try Self.recordingSSH(in: parent)
        try GitFixture.git(["remote", "set-url", "origin", "ssh://git@example.invalid/celes-app/celes-platform.git"], in: repo)
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

    @Test func namerSkipsTakenNamesAndFallsBackToSuffix() {
        let identity: ([String]) -> [String] = { $0 }
        #expect(WorkspaceNamer.pick(isTaken: { $0 == "lisbon" }, order: identity) == "kyoto")
        #expect(WorkspaceNamer.pick(isTaken: { !$0.hasSuffix("-2") || $0 == "lisbon-2" }, order: identity) == "kyoto-2")
    }
}
