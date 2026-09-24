import Foundation

/// The workspace branch as its worktree sees it (`GST-01`'s local source): `git status --porcelain=v2 --branch`, plus
/// the commits ahead of the base and whether the upstream was rewritten.
public struct LocalGitStatus: Codable, Equatable, Sendable {
    /// `# branch.head`; nil while HEAD is detached. The live branch, which pull request lookups use (Decisions).
    public var branch: String?
    /// `# branch.upstream`, for example `origin/rocky/tokyo`; nil without one.
    public var upstream: String?
    /// Staged, changed, conflicted and untracked entries.
    public var uncommitted: Int
    /// Commits the upstream lacks. Without an upstream, the commits on no `origin` branch, so `GST-03`'s
    /// `git push -u origin HEAD` has a count to show.
    public var ahead: Int
    /// Upstream commits the branch lacks, as of the last fetch; 0 without an upstream.
    public var behind: Int
    /// Commits of the branch that the base lacks: `HDR-02`'s create PR against "No changes yet".
    public var commitsAheadOfBase: Int
    /// Ahead of and behind the upstream at once (Open question 4), so pull means behind only and push ahead only.
    public var isIncompatible: Bool
    /// Incompatible because the last fetch of the upstream was a forced update: "Remote branch was rebased".
    public var remoteWasRebased: Bool

    public init(
        branch: String? = nil,
        upstream: String? = nil,
        uncommitted: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        commitsAheadOfBase: Int = 0,
        isIncompatible: Bool = false,
        remoteWasRebased: Bool = false
    ) {
        self.branch = branch
        self.upstream = upstream
        self.uncommitted = uncommitted
        self.ahead = ahead
        self.behind = behind
        self.commitsAheadOfBase = commitsAheadOfBase
        self.isIncompatible = isIncompatible
        self.remoteWasRebased = remoteWasRebased
    }

    /// The branch, its upstream, the entries and `# branch.ab`'s counts. `commitsAheadOfBase` and
    /// `remoteWasRebased` need more git runs; `GitBranchService.status` fills them in.
    public static func parse(porcelainV2 output: String) -> LocalGitStatus {
        parseCounting(output).status
    }

    /// Also says whether `# branch.ab` was there: git leaves it out without an upstream, and when the upstream's ref
    /// is gone.
    static func parseCounting(_ output: String) -> (status: LocalGitStatus, hasUpstreamCounts: Bool) {
        var status = LocalGitStatus()
        var hasUpstreamCounts = false
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                status.branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // "+2 -3": two commits ahead, three behind.
                let fields = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if fields.count == 2, let ahead = Int(fields[0]), let behind = Int(fields[1]) {
                    status.ahead = abs(ahead)
                    status.behind = abs(behind)
                    hasUpstreamCounts = true
                }
            } else if let kind = line.first, "12u?".contains(kind), line.dropFirst().first == " " {
                // Changed (1), renamed or copied (2), unmerged (u) and untracked (?). Ignored entries (!) only show
                // with --ignored, which Rocky never passes.
                status.uncommitted += 1
            }
        }
        status.isIncompatible = status.ahead > 0 && status.behind > 0
        return (status, hasUpstreamCounts)
    }
}

public enum GitBranchError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// A push the remote refused because it has commits the branch lacks (`GST-03`).
    case nonFastForward
    /// Any other git failure: the last lines of its stderr, for `ERR-01`'s toast.
    case failed(stderrTail: String)

    public var description: String {
        switch self {
        case .nonFastForward: "The remote has new commits. Pull first."
        case .failed(let stderrTail): stderrTail
        }
    }

    public var errorDescription: String? { description }
}

/// The branch operations of the pull request panel (`GST-01`…`GST-03`, `AGT-04`) through `/usr/bin/git`, in the
/// worktree, with the workspace environment. Rocky never force-pushes, never creates a merge commit and never skips
/// hooks here. Blocking: call it off the main actor, and only on `PR-07`'s event triggers, never on a timer.
public struct GitBranchService: Sendable {
    private static let git = URL(fileURLWithPath: "/usr/bin/git")

    public let environment: [String: String]

    /// `environment` is the workspace's, so `GH_TOKEN` (ENV-01) signs an HTTPS push or fetch.
    public init(environment: [String: String]) {
        self.environment = WorktreeService.nonInteractive(environment)
    }

    /// `GST-01`'s local status. `base` is the ref "commits ahead of the base" counts from, for example
    /// `origin/development`; nil counts from origin's default branch (a workspace made before M2 has no base).
    public func status(worktree: URL, base: String?) throws -> LocalGitStatus {
        // Reading takes no optional lock, so it never holds the index lock an agent's own git needs.
        let output = try perform(["--no-optional-locks", "status", "--porcelain=v2", "--branch"], in: worktree)
        let parsed = LocalGitStatus.parseCounting(output)
        var status = parsed.status
        if !parsed.hasUpstreamCounts {
            // Without an upstream: the commits on no origin branch are what `push -u origin HEAD` would send.
            status.ahead = count(["rev-list", "--count", "HEAD", "--not", "--remotes=origin"], in: worktree)
            status.behind = 0
            status.isIncompatible = false
        }
        let baseRef = base ?? "refs/remotes/origin/HEAD"
        status.commitsAheadOfBase = count(["rev-list", "--count", "\(baseRef)..HEAD"], in: worktree)
        if status.isIncompatible, let upstream = status.upstream {
            // The tracking ref's last reflog entry says whether that fetch rewrote it (Open question 4).
            let entry = try? runGit(["reflog", "-1", "--format=%gs", "refs/remotes/\(upstream)"], in: worktree)
            status.remoteWasRebased = entry?.contains("forced-update") == true
        }
        return status
    }

    /// `GST-03`'s Pull, as `git pull --ff-only`: the header offers it only while the branch is behind and not ahead,
    /// and `--ff-only` keeps Rocky from creating a merge commit if the agent committed since.
    public func pull(worktree: URL) throws {
        try perform(["pull", "--ff-only"], in: worktree, reachesRemote: true)
    }

    /// `GST-03`'s Push: `git push`, or `git push -u origin HEAD` without an upstream. A refusal because the remote has
    /// new commits is `nonFastForward`.
    public func push(worktree: URL, hasUpstream: Bool) throws {
        let arguments = hasUpstream ? ["push"] : ["push", "-u", "origin", "HEAD"]
        do {
            try runGit(arguments, in: worktree, reachesRemote: true)
        } catch let failure as ProcessFailure where Self.isNonFastForward(failure.stderr) {
            throw GitBranchError.nonFastForward
        } catch {
            throw Self.branchError(error)
        }
    }

    /// `git fetch origin <branch>`: the base before `GST-02`'s fast-forward, or the branch itself when GitHub's head
    /// differs from `refs/remotes/origin/<branch>` (`GST-01`). The tracking ref follows the remote's default refspec.
    public func fetch(worktree: URL, branch: String) throws {
        guard !branch.hasPrefix("-") else { throw GitBranchError.failed(stderrTail: "\(branch) is not a branch name.") }
        try perform(["fetch", "--quiet", "origin", branch], in: worktree, reachesRemote: true)
    }

    /// `GST-02`'s "only behind" step: `git merge --ff-only <ref>`, which refuses a diverged branch.
    public func fastForward(worktree: URL, to ref: String) throws {
        try perform(["merge", "--ff-only", ref], in: worktree)
    }

    /// The branch's commits that `ref` lacks: 0 means `GST-02` can fast-forward.
    public func ownCommits(worktree: URL, since ref: String) throws -> Int {
        let output = try perform(["rev-list", "--count", "\(ref)..HEAD"], in: worktree)
        guard let count = Int(output) else { throw GitBranchError.failed(stderrTail: "git rev-list printed \"\(output)\".") }
        return count
    }

    /// `git config pull.rebase` (`AGT-04`, `GST-02`): true, merges, interactive and the like rebase; unset or false
    /// merge.
    public func prefersRebase(worktree: URL) -> Bool {
        guard let value = try? runGit(["config", "--get", "pull.rebase"], in: worktree) else { return false }
        return !["", "false", "no", "off", "0"].contains(value.lowercased())
    }

    /// `PR-06`'s "Archive anyway": the worktree's uncommitted changes and untracked files go to a stash of the
    /// repository (`git stash list` in the main folder shows `message`), so `git worktree remove` finds it clean and
    /// nothing is lost. Ignored files are not stashed: the removal deletes them, as it always did. A clean worktree
    /// stashes nothing.
    public func stashAll(worktree: URL, message: String) throws {
        try perform(["stash", "push", "--include-untracked", "--message", message], in: worktree)
    }

    /// `refs/remotes/origin/<branch>`, the branch as of the last fetch; nil when it was never fetched.
    public func remoteBranchOid(worktree: URL, branch: String) -> String? {
        guard !branch.hasPrefix("-") else { return nil }
        return try? runGit(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], in: worktree)
    }

    // MARK: Running git

    /// A count from `git rev-list --count`; 0 when git fails (no commits yet, or the ref does not exist).
    private func count(_ arguments: [String], in worktree: URL) -> Int {
        (try? runGit(arguments, in: worktree)).flatMap { Int($0) } ?? 0
    }

    @discardableResult
    private func perform(_ arguments: [String], in worktree: URL, reachesRemote: Bool = false) throws -> String {
        do {
            return try runGit(arguments, in: worktree, reachesRemote: reachesRemote)
        } catch {
            throw Self.branchError(error)
        }
    }

    /// A run that reaches the remote (pull, push, fetch) gets the ssh command git itself would use, in batch mode
    /// (`WorktreeService.remoteEnvironment(_:in:)`), so the worktree's `core.sshCommand` is not overridden.
    @discardableResult
    private func runGit(_ arguments: [String], in worktree: URL, reachesRemote: Bool = false) throws -> String {
        let environment = reachesRemote ? WorktreeService.remoteEnvironment(environment, in: worktree) : environment
        return try ProcessRunner.run(Self.git, arguments, in: worktree, environment: environment)
    }

    /// git's words for a push the remote refused because it moved on: "(fetch first)" before the new commits were
    /// fetched, "(non-fast-forward)" after.
    static func isNonFastForward(_ stderr: String) -> Bool {
        stderr.contains("[rejected]") && (stderr.contains("(fetch first)") || stderr.contains("(non-fast-forward)"))
    }

    /// `failed` with the last three lines of stderr, and no word shaped like a token (a remote URL can carry one).
    static func branchError(_ error: Error) -> GitBranchError {
        if let error = error as? GitBranchError { return error }
        guard let failure = error as? ProcessFailure else {
            return .failed(stderrTail: GitHubAccounts.withoutTokenShapes("git could not run: \(error.localizedDescription)"))
        }
        let tail = failure.stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .joined(separator: "\n")
        let text = tail.isEmpty ? "\(failure.command) exited \(failure.status)." : tail
        return .failed(stderrTail: GitHubAccounts.withoutTokenShapes(text))
    }
}
