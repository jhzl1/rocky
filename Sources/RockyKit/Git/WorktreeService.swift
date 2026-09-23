import Foundation

public struct CreatedWorktree: Sendable, Equatable {
    public let name: String
    public let path: URL
    public let branch: String
    public let baseRef: String
    /// `git fetch` failed (offline, auth); the worktree was created from the last fetched ref.
    public let fetchFailed: Bool
}

/// Git worktree operations through `/usr/bin/git`. Blocking: call off the main actor.
public struct WorktreeService: Sendable {
    public static let branchPrefix = "rocky/"
    private static let git = URL(fileURLWithPath: "/usr/bin/git")

    public let environment: [String: String]

    public init(environment: [String: String]) {
        // Never block on a credential or host-key prompt: there is no terminal to answer it.
        self.environment = environment.merging([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_SSH_COMMAND": "ssh -o BatchMode=yes",
        ]) { _, new in new }
    }

    /// Worktrees live next to the repo, so `~/.gitconfig` `includeIf "gitdir:..."` rules still match.
    public static func worktreesRoot(for repo: URL) -> URL {
        repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-worktrees", isDirectory: true)
    }

    public func isRepositoryRoot(_ url: URL) -> Bool {
        guard let top = try? run(["rev-parse", "--show-toplevel"], in: url) else { return false }
        return URL(fileURLWithPath: top).resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
    }

    /// origin's default branch when the repo has an origin, else the current branch.
    public func baseRef(repo: URL) throws -> (ref: String, fetchFailed: Bool) {
        let remotes = try run(["remote"], in: repo).split(separator: "\n").map(String.init)
        guard remotes.contains("origin") else {
            return (try run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo), false)
        }
        let fetchFailed = (try? run(["fetch", "--quiet", "origin"], in: repo)) == nil
        if let ref = try? run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo) {
            return (ref, fetchFailed)
        }
        return (try run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo), fetchFailed)
    }

    public func isTaken(repo: URL, name: String) -> Bool {
        let path = Self.worktreesRoot(for: repo).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: path.path) { return true }
        return (try? run(["rev-parse", "--verify", "--quiet", "refs/heads/\(Self.branchPrefix)\(name)"], in: repo)) != nil
    }

    public func create(repo: URL, name: String) throws -> CreatedWorktree {
        let (base, fetchFailed) = try baseRef(repo: repo)
        let root = Self.worktreesRoot(for: repo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(name, isDirectory: true)
        let branch = Self.branchPrefix + name
        try run(["worktree", "add", "-b", branch, path.path, base], in: repo)
        return CreatedWorktree(name: name, path: path, branch: branch, baseRef: base, fetchFailed: fetchFailed)
    }

    /// Removes the worktree directory and keeps its branch, so no commit is lost.
    /// Fails while the worktree has uncommitted changes.
    public func remove(repo: URL, worktree: URL) throws {
        try run(["worktree", "remove", worktree.path], in: repo)
    }

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) throws -> String {
        try ProcessRunner.run(Self.git, arguments, in: directory, environment: environment)
    }
}

public enum WorkspaceNamer {
    public static let cities = [
        "lisbon", "kyoto", "oslo", "lima", "quito", "cusco", "hanoi", "dakar", "accra", "porto",
        "nairobi", "havana", "bogota", "caracas", "merida", "sucre", "rosario", "valencia", "seville", "bergen",
        "tallinn", "riga", "vilnius", "krakow", "prague", "vienna", "zagreb", "split", "tbilisi", "yerevan",
        "baku", "almaty", "busan", "osaka", "taipei", "manila", "cebu", "perth", "hobart", "auckland",
    ]

    public static func pick(isTaken: (String) -> Bool, order: ([String]) -> [String] = { $0.shuffled() }) -> String {
        let candidates = order(cities)
        if let free = candidates.first(where: { !isTaken($0) }) { return free }
        var suffix = 2
        while true {
            if let free = candidates.map({ "\($0)-\(suffix)" }).first(where: { !isTaken($0) }) { return free }
            suffix += 1
        }
    }
}
