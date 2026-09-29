import Foundation

public struct CreatedWorktree: Sendable, Equatable {
    public let name: String
    public let path: URL
    public let branch: String
    public let baseRef: String
    /// `git fetch` failed (offline, auth); the worktree was created from the last fetched ref.
    public let fetchFailed: Bool
}

/// KIT-19: what `WorktreeService.remove` did with the workspace's branch once the worktree was gone (WSC-07's rule).
public enum BranchOutcome: Equatable, Sendable {
    /// Every commit of it is also on another branch, a remote branch or a tag: `git branch -D` deleted it.
    case deleted
    /// `commits` of its commits are nowhere else, so it stays and nothing is lost.
    case kept(commits: Int)
    /// Not Rocky's own (no `rocky/` prefix), no branch was given, or it no longer exists: nothing was asked of git.
    case leftAlone
    /// git could not count or delete it, for git's reason (a branch the main clone has checked out, for example): it
    /// stays.
    case notDeleted(String)
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

    /// origin's default branch when the repo has an origin, else the current branch. A stopped `stopper` ends it
    /// wherever it is, even during the fetch, with `CancellationError`.
    public func baseRef(repo: URL, stopper: ProcessStopper? = nil) throws -> (ref: String, fetchFailed: Bool) {
        let remotes = try run(["remote"], in: repo, stopper: stopper).split(separator: "\n").map(String.init)
        guard remotes.contains("origin") else {
            return (try run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo, stopper: stopper), false)
        }
        let fetched: Bool
        do {
            try run(["fetch", "--quiet", "origin"], in: repo, reachesRemote: true, stopper: stopper)
            fetched = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            fetched = false
        }
        if let ref = try? run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo, stopper: stopper) {
            return (ref, !fetched)
        }
        return (try run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo, stopper: stopper), !fetched)
    }

    public func isTaken(repo: URL, name: String) -> Bool {
        let path = Self.worktreesRoot(for: repo).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: path.path) { return true }
        return branchExists(Self.branchPrefix + name, in: repo)
    }

    /// WSC-04: the workspace's worktree, `<repo>-worktrees/<name>` on `rocky/<name>`, from `baseRef`: the fetch, then
    /// origin's default branch. No hook runs (`core.hooksPath=/dev/null`), so it returns once git has checked out,
    /// whatever the repository's post-checkout hook would do; Setup runs that hook next, in its tab (WSC-05). A
    /// `rocky/<name>` that already exists, which a failed attempt made, is checked out as it is, without `-b` (WSC-06's
    /// Retry). `stopper` stops git between or during its runs (WSC-06's Remove, a quit).
    public func create(repo: URL, name: String, stopper: ProcessStopper? = nil) throws -> CreatedWorktree {
        let (base, fetchFailed) = try baseRef(repo: repo, stopper: stopper)
        let root = Self.worktreesRoot(for: repo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(name, isDirectory: true)
        let branch = Self.branchPrefix + name
        let add = branchExists(branch, in: repo)
            ? ["worktree", "add", path.path, branch]
            : ["worktree", "add", "-b", branch, path.path, base]
        try run(["-c", "core.hooksPath=/dev/null"] + add, in: repo, stopper: stopper)
        return CreatedWorktree(name: name, path: path, branch: branch, baseRef: base, fetchFailed: fetchFailed)
    }

    /// WSC-05: the post-checkout hook git would have run for `worktree`, where git looks for it:
    /// `rev-parse --git-path hooks/post-checkout` honors `core.hooksPath` (`.husky/post-checkout` in celes-platform) and
    /// the hooks a linked worktree shares with its main clone. nil when that file is missing or not executable, which
    /// git skips too.
    public func postCheckoutHook(worktree: URL) -> URL? {
        guard let path = try? run(["rev-parse", "--git-path", "hooks/post-checkout"], in: worktree), !path.isEmpty else {
            return nil
        }
        // A relative path is the worktree's, where rev-parse ran.
        let hook = URL(fileURLWithPath: path, relativeTo: worktree).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: hook.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: hook.path) else { return nil }
        return URL(fileURLWithPath: hook.path)
    }

    /// The commit `worktree` has checked out: git's second argument to a post-checkout hook (WSC-05).
    public func head(worktree: URL) throws -> String {
        try run(["rev-parse", "HEAD"], in: worktree)
    }

    /// WSC-06: what a creation that did not finish leaves goes. The half-made folder: as a worktree git knows, locked
    /// or not, through `worktree remove --force --force`, which works with its folder gone too, else as a plain folder.
    /// Then `worktree prune`. Then `branch`, only when it has no commit that another branch or tag lacks, so nothing of
    /// anyone's is lost; nil keeps it, for Retry to reuse.
    public func cleanUp(repo: URL, path: URL, branch: String?) throws {
        if (try? run(["worktree", "remove", "--force", "--force", path.path], in: repo)) == nil,
           FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        try run(["worktree", "prune"], in: repo)
        guard let branch, branchExists(branch, in: repo) else { return }
        guard try ownCommitCount(of: branch, in: repo) == 0 else { return }
        try run(["branch", "-D", branch], in: repo)
    }

    private func branchExists(_ branch: String, in repo: URL) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo)) != nil
    }

    /// The commits of `branch` that no other branch, remote branch or tag has: 0 when everything on it is also
    /// somewhere else, so deleting it loses nothing (the user's definition of an empty branch, 2026-09-28).
    private func ownCommitCount(of branch: String, in repo: URL) throws -> Int {
        let count = try run(
            ["rev-list", "--count", "refs/heads/\(branch)", "--not", "--exclude=\(branch)", "--branches", "--remotes", "--tags"],
            in: repo
        )
        guard let commits = Int(count) else { throw GitBranchError.failed(stderrTail: "git rev-list printed “\(count)”.") }
        return commits
    }

    /// WSC-07, KIT-19: removes the worktree directory, then applies the branch rule to `branch`, the workspace's. It
    /// fails, and changes nothing, while the worktree has uncommitted changes or is locked. The user's rule of
    /// 2026-09-28, "Borrarla si está vacía": a `rocky/` branch goes when all its commits are also on another branch, a
    /// remote branch or a tag, so a branch whose work is pushed or merged goes too, and one with a commit nowhere else
    /// stays. A branch without the prefix (one GHL-05 switched to, a pull request's) always stays, and so does every
    /// branch when `branch` is nil.
    @discardableResult
    public func remove(repo: URL, worktree: URL, branch: String? = nil) throws -> BranchOutcome {
        try run(["worktree", "remove", worktree.path], in: repo)
        guard let branch, branch.hasPrefix(Self.branchPrefix), branchExists(branch, in: repo) else { return .leftAlone }
        // The worktree is gone by now: what follows can only keep the branch, never bring the workspace back.
        do {
            let commits = try ownCommitCount(of: branch, in: repo)
            guard commits == 0 else { return .kept(commits: commits) }
            try run(["branch", "-D", branch], in: repo)
            return .deleted
        } catch {
            return .notDeleted(GitBranchService.branchError(error).description)
        }
    }

    @discardableResult
    private func run(_ arguments: [String], in directory: URL, reachesRemote: Bool = false, stopper: ProcessStopper? = nil) throws -> String {
        let environment = reachesRemote ? Self.remoteEnvironment(environment, in: directory) : environment
        return try ProcessRunner.run(Self.git, arguments, in: directory, environment: environment, stopper: stopper)
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
