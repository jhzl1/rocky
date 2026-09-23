import Foundation
import Testing
@testable import RockyKit

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

    @Test func namerSkipsTakenNamesAndFallsBackToSuffix() {
        let identity: ([String]) -> [String] = { $0 }
        #expect(WorkspaceNamer.pick(isTaken: { $0 == "lisbon" }, order: identity) == "kyoto")
        #expect(WorkspaceNamer.pick(isTaken: { !$0.hasSuffix("-2") || $0 == "lisbon-2" }, order: identity) == "kyoto-2")
    }
}
