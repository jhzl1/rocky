import Foundation
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
