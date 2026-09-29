import Foundation

/// A branch the picker's Branches tab offers (`GHL-03`, `KIT-15`): a local branch, or one only on origin.
public struct BranchRef: Equatable, Sendable, Identifiable {
    /// Without `origin/`: "feat/button-styles".
    public let name: String
    /// Only on origin: switching to it creates the local branch, tracking it.
    public let isRemoteOnly: Bool
    /// "origin/feat/button-styles": a local branch's upstream, nil without one; a remote-only branch's own ref.
    public let upstream: String?
    /// The worktree that has it checked out, the workspace's own included; nil when none does.
    public let heldBy: URL?

    public var id: String { (isRemoteOnly ? "origin/" : "") + name }

    public init(name: String, isRemoteOnly: Bool, upstream: String?, heldBy: URL?) {
        self.name = name
        self.isRemoteOnly = isRemoteOnly
        self.upstream = upstream
        self.heldBy = heldBy
    }
}

/// What `GitBranchService.switchTo` switches a worktree to (`GHL-05`, `KIT-15`).
public enum SwitchTarget: Equatable, Sendable {
    /// `git switch <branch>`.
    case local(String)
    /// A branch only on origin: `git switch --track origin/<branch>`.
    case remote(String)
    /// A pull request of the repository itself, by its head branch: `git fetch origin <head>` first, then its local
    /// branch, or a new one tracking it.
    case pullRequest(head: String)
}

/// `KIT-15`'s pure parts: git's listings read, and the picker's reasons for a branch it cannot switch to.
public enum BranchLinks {
    /// `git for-each-ref`'s lines, `%(refname)` TAB `%(upstream:short)`, as branches in git's order: a remote branch
    /// with a local one of the same name once, as the local one, and without `origin/HEAD` (`GHL-03`). `holders` maps a
    /// local branch to the worktree that has it checked out.
    public static func branches(forEachRef output: String, holders: [String: URL]) -> [BranchRef] {
        let lines = output.split(whereSeparator: \.isNewline).map { line -> (ref: String, upstream: String?) in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let upstream = fields.count > 1 ? String(fields[1]) : ""
            return (String(fields[0]), upstream.isEmpty ? nil : upstream)
        }
        let local = Set(lines.compactMap { Self.name($0.ref, under: "refs/heads/") })
        return lines.compactMap { line in
            if let name = Self.name(line.ref, under: "refs/heads/") {
                return BranchRef(name: name, isRemoteOnly: false, upstream: line.upstream, heldBy: holders[name])
            }
            guard let name = Self.name(line.ref, under: "refs/remotes/origin/"), name != "HEAD", !local.contains(name) else {
                return nil
            }
            return BranchRef(name: name, isRemoteOnly: true, upstream: "origin/\(name)", heldBy: nil)
        }
    }

    private static func name(_ ref: String, under prefix: String) -> String? {
        guard ref.hasPrefix(prefix), ref.count > prefix.count else { return nil }
        return String(ref.dropFirst(prefix.count))
    }

    /// `git worktree list --porcelain`: each checked-out branch and the worktree that has it. A detached worktree holds
    /// no branch.
    public static func holders(porcelain output: String) -> [String: URL] {
        var holders: [String: URL] = [:]
        var worktree: URL?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                worktree = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)), isDirectory: true)
            } else if line.hasPrefix("branch refs/heads/"), let worktree {
                holders[String(line.dropFirst("branch refs/heads/".count))] = worktree
            } else if line.isEmpty {
                worktree = nil
            }
        }
        return holders
    }

    /// `GHL-02`'s reason at the end of a row Rocky cannot switch to (`GHL-05`): "Current branch" for the one the
    /// workspace's worktree has, "Checked out in <path>" for one another worktree holds, which git refuses. nil when it
    /// can be picked.
    public static func unavailableReason(heldBy holder: URL?, worktree: URL, mainClone: URL) -> String? {
        guard let holder else { return nil }
        if samePath(holder, worktree) { return "Current branch" }
        return "Checked out in \(holderLabel(holder, mainClone: mainClone))"
    }

    /// A worktree as the reason names it: "acme-platform-worktrees/tokyo" for one of Rocky's, next to the main clone;
    /// any other folder, the main clone included, with `~` for the home folder.
    public static func holderLabel(_ holder: URL, mainClone: URL) -> String {
        let root = WorktreeService.worktreesRoot(for: mainClone).resolvingSymlinksInPath().path
        let path = holder.resolvingSymlinksInPath().path
        if path.hasPrefix(root + "/") {
            return "\(URL(fileURLWithPath: root).lastPathComponent)/\(path.dropFirst(root.count + 1))"
        }
        return (holder.path as NSString).abbreviatingWithTildeInPath
    }

    /// `/var/…` and `/private/var/…` name one folder.
    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

extension GitBranchService {
    /// `GHL-03`'s branches, newest commit first: `git for-each-ref --sort=-committerdate refs/heads refs/remotes/origin`
    /// read by `BranchLinks.branches(forEachRef:holders:)`, each local one with the worktree that holds it
    /// (`git worktree list --porcelain`). Local runs only: `fetchPruning` brings the remote's branches.
    public func branches(worktree: URL) throws -> [BranchRef] {
        let refs = try perform(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname)%09%(upstream:short)", "refs/heads", "refs/remotes/origin"],
            in: worktree
        )
        return BranchLinks.branches(forEachRef: refs, holders: try worktreeHolders(worktree: worktree))
    }

    /// Each checked-out branch of the repository and the worktree that has it.
    public func worktreeHolders(worktree: URL) throws -> [String: URL] {
        BranchLinks.holders(porcelain: try perform(["worktree", "list", "--porcelain"], in: worktree))
    }

    /// `GHL-03`'s one fetch when the Branches tab first shows: `git fetch origin --prune`, so branches pushed since
    /// show and deleted ones go. Through the repository's own ssh command, in batch mode (`remoteEnvironment`).
    public func fetchPruning(worktree: URL) throws {
        try perform(["fetch", "--quiet", "--prune", "origin"], in: worktree, reachesRemote: true)
    }

    /// `GHL-05`'s switch, then the workspace's own branch deleted (`deleteBranch`), since it was just proven empty.
    /// Returns whether `ownBranch` was deleted: a failure there leaves it and is not the switch's. git's refusal (a
    /// branch another worktree holds, a missing one) throws, with the worktree as it was.
    @discardableResult
    public func switchTo(_ target: SwitchTarget, worktree: URL, dropping ownBranch: String?) throws -> Bool {
        let branch: String
        switch target {
        case .local(let name):
            try Self.checkName(name)
            try perform(["switch", "--quiet", name], in: worktree)
            branch = name
        case .remote(let name):
            try Self.checkName(name)
            try perform(["switch", "--quiet", "--track", "origin/\(name)"], in: worktree)
            branch = name
        case .pullRequest(let head):
            try Self.checkName(head)
            try fetch(worktree: worktree, branch: head)
            let hasLocal = (try? runGit(["rev-parse", "--verify", "--quiet", "refs/heads/\(head)"], in: worktree)) != nil
            try perform(hasLocal ? ["switch", "--quiet", head] : ["switch", "--quiet", "--track", "origin/\(head)"], in: worktree)
            branch = head
        }
        guard let ownBranch, ownBranch != branch else { return false }
        return (try? deleteBranch(ownBranch, worktree: worktree)) != nil
    }

    /// `git branch -D`: `-d` refuses a branch the new HEAD does not contain, and the workspace's own branch was proven
    /// empty before the switch (user decision, 2026-09-25: "Borrarla").
    public func deleteBranch(_ name: String, worktree: URL) throws {
        try Self.checkName(name)
        try perform(["branch", "-D", name], in: worktree)
    }

    /// `GHL-05`'s branch attachment: `git log` of the branch's last `limit` commits that `base` lacks, newest first, each
    /// "abbreviated-hash subject", and how many there are in all.
    public func commits(of branch: String, notIn base: String, worktree: URL, limit: Int = 20) throws -> (lines: [String], total: Int) {
        try Self.checkName(branch)
        let range = "\(base)..refs/heads/\(branch)"
        let log = try perform(["log", "--no-color", "--format=%h %s", "-n", "\(limit)", range], in: worktree)
        let total = try perform(["rev-list", "--count", range], in: worktree)
        let lines = log.split(whereSeparator: \.isNewline).map(String.init)
        return (lines, Int(total) ?? lines.count)
    }

    /// `GHL-05`: the workspace has nothing of its own, so switching loses nothing: no uncommitted changes, no commits
    /// its base lacks (`HDR-02`'s "No changes yet") and no file tab with unsaved edits (`EDIT-02`).
    public static func canSwitch(status: LocalGitStatus, unsavedEdits: Bool) -> Bool {
        status.uncommitted == 0 && status.commitsAheadOfBase == 0 && !unsavedEdits
    }

    /// A name starting with "-" would reach git as an option.
    private static func checkName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-") else { throw GitBranchError.failed(stderrTail: "\(name) is not a branch name.") }
    }
}

/// The picker's branches for one workspace (`GHL-02`, `GHL-03`), and where its worktree is, for the rows' reasons.
public struct LinkBranches: Equatable, Sendable {
    public let branches: [BranchRef]
    public let worktree: URL
    public let mainClone: URL

    public init(branches: [BranchRef], worktree: URL, mainClone: URL) {
        self.branches = branches
        self.worktree = worktree
        self.mainClone = mainClone
    }

    /// A branch row's reason: "Current branch", "Checked out in …"; nil when it can be picked.
    public func reason(for branch: BranchRef) -> String? {
        BranchLinks.unavailableReason(heldBy: branch.heldBy, worktree: worktree, mainClone: mainClone)
    }

    /// A pull request row's reason, from the local branch of its head when there is one.
    public func reason(forBranchNamed name: String) -> String? {
        branches.first { $0.name == name && !$0.isRemoteOnly }.flatMap(reason(for:))
    }

    /// `GHL-03`'s filter, in memory: the branches whose name holds `query`, ignoring case; all of them for an empty
    /// query.
    public func matching(_ query: String) -> [BranchRef] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }
}
