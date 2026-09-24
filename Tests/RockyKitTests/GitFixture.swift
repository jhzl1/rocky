import Foundation
import Testing
@testable import RockyKit

/// Real git repositories in a temp directory; no network.
enum GitFixture {
    static let git = URL(fileURLWithPath: "/usr/bin/git")
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_AUTHOR_NAME"] = "Rocky Test"
        env["GIT_AUTHOR_EMAIL"] = "rocky@example.com"
        env["GIT_COMMITTER_NAME"] = "Rocky Test"
        env["GIT_COMMITTER_EMAIL"] = "rocky@example.com"
        return env
    }()

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) throws -> String {
        try ProcessRunner.run(git, arguments, in: directory, environment: environment)
    }

    /// A repo with one commit on `main` and no remote.
    static func localRepo(in parent: URL, name: String = "app") throws -> URL {
        let repo = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try Data("hello\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        try git(["add", "README.md"], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        return repo
    }

    // For `@MainActor` suites: on `BlockingWorkExecutor`, neither the main thread nor the cooperative pool (see
    // `BlockingWorkExecutor` for what a full pool stops).

    static func localRepoOffMain(in parent: URL, name: String = "app") async throws -> URL {
        try await Task.blocking { try localRepo(in: parent, name: name) }.value
    }

    static func clonedRepoOffMain(in parent: URL) async throws -> URL {
        try await Task.blocking { try clonedRepo(in: parent) }.value
    }

    @discardableResult
    static func gitOffMain(_ arguments: [String], in directory: URL) async throws -> String {
        try await Task.blocking { try git(arguments, in: directory) }.value
    }

    /// A clone of a bare origin whose default branch is `trunk`, with the clone checked out on `feature`.
    static func clonedRepo(in parent: URL) throws -> URL {
        let seed = try localRepo(in: parent, name: "seed")
        try git(["branch", "-m", "main", "trunk"], in: seed)
        try git(["clone", "-q", "--bare", seed.path, parent.appendingPathComponent("origin.git").path], in: parent)
        try git(["clone", "-q", parent.appendingPathComponent("origin.git").path, "app"], in: parent)
        let repo = parent.appendingPathComponent("app", isDirectory: true)
        try git(["switch", "-q", "-c", "feature"], in: repo)
        return repo
    }
}

/// Runs a suite's tests on `BlockingWorkExecutor`. Swift Testing runs a synchronous test on the cooperative pool, and
/// the git of these suites held a pool thread for the whole test: in a full run they filled the pool, and `DispatchIO`
/// stopped reading `PTYSessionTests`' terminals (see `BlockingWorkExecutor`).
struct BlockingWorkTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await withTaskExecutorPreference(BlockingWorkExecutor.shared) {
            try await function()
        }
    }
}

extension Trait where Self == BlockingWorkTrait {
    static var blockingWork: Self { Self() }
}
