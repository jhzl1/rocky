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
        self.environment = Self.nonInteractive(environment)
    }

    /// The environment of Rocky's own git runs: never block on a credential prompt, since there is no terminal to
    /// answer it. `GitBranchService` uses it too. It sets no ssh command: local runs need none, and a run that reaches
    /// the remote gets its own (`remoteEnvironment(_:in:)`).
    static func nonInteractive(_ environment: [String: String]) -> [String: String] {
        environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
    }

    /// `environment` for a git run that reaches the remote (fetch, pull, push) in `directory`: ssh in batch mode, so a
    /// passphrase or host-key question fails instead of waiting for a terminal, on the command git itself would run
    /// (`batchSSHCommand`). A fixed `GIT_SSH_COMMAND=ssh -o BatchMode=yes` overrode the repository's
    /// `core.sshCommand`: a celes clone's key, set by an `includeIf "gitdir:…"`, was skipped, and the fetch went out
    /// with the personal key, which has no access (user report, 2026-09-23).
    static func remoteEnvironment(_ environment: [String: String], in directory: URL) -> [String: String] {
        var remote = environment
        remote["GIT_SSH_COMMAND"] = batchSSHCommand(
            inherited: environment["GIT_SSH_COMMAND"],
            configured: configuredSSHCommand(in: directory, environment: environment)
        )
        return remote
    }

    /// The ssh command git would run, with ` -o BatchMode=yes` after it: `GIT_SSH_COMMAND` from the login shell, else
    /// the repository's `core.sshCommand`, else `ssh`, which is git's own order. ssh keeps the first value it gets for
    /// an option, so the command's own options still win.
    static func batchSSHCommand(inherited: String?, configured: String?) -> String {
        let command = [inherited, configured]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "ssh"
        return command + " -o BatchMode=yes"
    }

    /// `git config --get core.sshCommand` in `directory`, which follows `~/.gitconfig`'s `includeIf "gitdir:…"`; nil
    /// when it is unset (git exits 1) or git fails. Read without `GIT_SSH_COMMAND`, so nothing of Rocky's is in the way.
    static func configuredSSHCommand(in directory: URL, environment: [String: String]) -> String? {
        var plain = environment
        plain["GIT_SSH_COMMAND"] = nil
        guard let value = try? ProcessRunner.run(git, ["config", "--get", "core.sshCommand"], in: directory, environment: plain),
              !value.isEmpty else { return nil }
        return value
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
        let fetchFailed = (try? run(["fetch", "--quiet", "origin"], in: repo, reachesRemote: true)) == nil
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
    private func run(_ arguments: [String], in directory: URL, reachesRemote: Bool = false) throws -> String {
        let environment = reachesRemote ? Self.remoteEnvironment(environment, in: directory) : environment
        return try ProcessRunner.run(Self.git, arguments, in: directory, environment: environment)
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
