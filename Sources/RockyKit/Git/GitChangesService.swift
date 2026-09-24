import Foundation

/// A workspace's changes against its base (`GIT-01`, `GIT-03`) and discarding a file's uncommitted ones (`GIT-05`),
/// through `/usr/bin/git` in the worktree with the workspace environment. Synchronous and blocking, like
/// `GitBranchService`: callers run it through `Task.blocking`, and only after an FSEvents change, never on a timer.
/// Reads run as `git --no-optional-locks`, so Rocky never holds the index lock an agent's own git needs.
public struct GitChangesService: Sendable {
    private static let git = URL(fileURLWithPath: "/usr/bin/git")
    /// Before every read: no optional lock, and paths printed as they are rather than octal-escaped.
    private static let readOptions = ["--no-optional-locks", "-c", "core.quotepath=off"]
    /// Before every diff: renames without copies, whatever `diff.renames` says, so each file is one entry the parser
    /// knows.
    private static let diffOptions = readOptions + ["-c", "diff.renames=true"]
    /// git's own binary rule: a NUL byte in the first 8,000 bytes.
    static let binarySniffLength = 8_000

    public let environment: [String: String]
    /// `GIT-05`'s Trash for untracked files; tests pass their own.
    private let recycle: @Sendable (URL) throws -> Void

    public init(
        environment: [String: String],
        recycle: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.environment = WorktreeService.nonInteractive(environment)
        self.recycle = recycle
    }

    // MARK: Base (GIT-01)

    /// `git merge-base <baseRef> HEAD`. A nil `baseRef` (a workspace made by M1) is origin/HEAD's branch, else the
    /// repository's current branch: the main worktree's.
    public func base(worktree: URL, baseRef: String?) throws -> String {
        let ref = try baseRef ?? defaultBaseRef(worktree: worktree)
        guard !ref.hasPrefix("-") else { throw GitBranchError.failed(stderrTail: "\(ref) is not a ref.") }
        return try perform(Self.readOptions + ["merge-base", ref, "HEAD"], in: worktree)
    }

    private func defaultBaseRef(worktree: URL) throws -> String {
        if let origin = try? runGit(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], in: worktree), !origin.isEmpty {
            return origin
        }
        // The first entry of the list is the main worktree: "worktree <path>", "HEAD <oid>", "branch <ref>".
        let list = try perform(["worktree", "list", "--porcelain"], in: worktree)
        for line in list.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }
            if line.hasPrefix("branch ") { return String(line.dropFirst("branch ".count)) }
        }
        throw GitBranchError.failed(stderrTail: "The repository has no origin/HEAD and its main folder is on no branch.")
    }

    // MARK: Changes (GIT-01, GIT-03)

    /// `GIT-03`'s numbers: the diff against `base` plus the lines of untracked files, and the files they are in
    /// (`CHG-01`'s count). Summed from `--numstat`, whose numbers are `--shortstat`'s but never translated, as a git
    /// built with gettext translates the summary line.
    public func shortstat(worktree: URL, base: String) throws -> DiffStat {
        let output = try perform(
            Self.diffOptions + ["diff", "--numstat", "--no-color", "--no-ext-diff", "--find-renames", base, "--"],
            in: worktree
        )
        var stat = Self.sumNumstat(output)
        for path in try untrackedPaths(worktree: worktree) {
            stat.additions += Self.lineCount(Self.mappedContents(of: worktree.appendingPathComponent(path)))
            stat.files += 1
        }
        return stat
    }

    /// Every file changed against `base`: the committed, staged and unstaged changes of `git diff <base>`, then the
    /// untracked files, read from disk and shown as added. Each is flagged uncommitted from `git status`.
    public func changes(worktree: URL, base: String) throws -> WorkspaceChanges {
        let patch = try output(
            Self.diffOptions + [
                "diff", "--no-color", "--no-ext-diff", "--find-renames", "-U3", "--src-prefix=a/", "--dst-prefix=b/", base, "--",
            ],
            in: worktree
        )
        var files = DiffParser.parse(String(decoding: patch, as: UTF8.self))
        var uncommittedPaths = Set<String>()
        for entry in try uncommittedEntries(worktree: worktree) {
            uncommittedPaths.insert(entry.path)
            if let original = entry.originalPath { uncommittedPaths.insert(original) }
        }
        for index in files.indices {
            let file = files[index]
            let oldPathIsUncommitted = file.oldPath.map { uncommittedPaths.contains($0) } ?? false
            files[index].isUncommitted = uncommittedPaths.contains(file.path) || oldPathIsUncommitted
        }
        for path in try untrackedPaths(worktree: worktree) {
            files.append(Self.untrackedDiff(path: path, in: worktree))
        }
        files.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        return WorkspaceChanges(base: base, files: files)
    }

    /// The size in bytes of `path` as `commit` has it (`DIFF-03`'s binary sizes, "24 KB → 31 KB"); nil when the commit
    /// has no such file or git cannot say.
    public func blobSize(worktree: URL, commit: String, path: String) -> Int? {
        // "<commit>:<path>" names the blob; a path is literal there, so a name like "*.png" is that one file.
        guard !commit.hasPrefix("-"), let size = try? runGit(Self.readOptions + ["cat-file", "-s", "\(commit):\(path)"], in: worktree) else {
            return nil
        }
        return Int(size)
    }

    /// The bytes of `path` as `commit` has it, exactly as stored (no filters or text conversion): `EDIT-04`'s base for the
    /// editor's change bars. nil when the commit has no such file or git cannot say.
    public func blob(worktree: URL, commit: String, path: String) -> Data? {
        guard !commit.hasPrefix("-") else { return nil }
        return try? output(Self.readOptions + ["cat-file", "blob", "\(commit):\(path)"], in: worktree)
    }

    /// `GIT-01`'s busy check: a rebase or merge in progress, or an index lock, in the worktree's own git directory.
    /// The diff waits for the next event rather than read a half-written state.
    public static func isBusy(worktree: URL) -> Bool {
        guard let gitDirectory = gitDirectory(worktree: worktree) else { return false }
        return ["rebase-merge", "rebase-apply", "MERGE_HEAD", "index.lock"].contains {
            FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent($0).path)
        }
    }

    /// The worktree's git directory, read from its `.git` file ("gitdir: <repo>/.git/worktrees/<name>") without running
    /// git; `.git` itself in a main clone. nil when there is none.
    public static func gitDirectory(worktree: URL) -> URL? {
        let dotGit = worktree.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("gitdir:") {
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : worktree.appendingPathComponent(path)
            return url.standardizedFileURL
        }
        return nil
    }

    // MARK: Discard (GIT-05)

    /// `GIT-05`: a tracked file goes back to HEAD with `git restore --staged --worktree`; an untracked file goes to the
    /// Trash. A file added to the index, or the new side of a staged rename, is unstaged and goes to the Trash too,
    /// since restoring a path HEAD lacks deletes it. Committed changes are never touched: a file without uncommitted
    /// changes is refused, and so is a file whose state differs from `isUntracked`, the list's view of it.
    public func discard(worktree: URL, path: String, isUntracked: Bool) throws {
        // The whole status, not one path's: narrowed to the new name, git would show a staged rename as an added file
        // and leave its original deleted.
        let entries = try uncommittedEntries(worktree: worktree, includingUntracked: true)
        guard let entry = entries.first(where: { $0.path == path }) else {
            throw GitBranchError.failed(stderrTail: "\(path) has no uncommitted changes.")
        }
        guard entry.isUntracked == isUntracked else {
            throw GitBranchError.failed(stderrTail: "\(path) changed since the list was read. Try again.")
        }
        let file = worktree.appendingPathComponent(path)
        if entry.isUntracked {
            try recycleFile(file)
            return
        }
        switch entry.index {
        case UInt8(ascii: "A"):
            try perform(Self.pathOptions + ["restore", "--staged", "--", path], in: worktree)
            try recycleFile(file)
        case UInt8(ascii: "R"), UInt8(ascii: "C"):
            // The index holds `path` in place of its original: put the original back in the index, send the new name
            // to the Trash, then write the original back to disk.
            let original = entry.originalPath.map { [$0] } ?? []
            try perform(Self.pathOptions + ["restore", "--staged", "--", path] + original, in: worktree)
            try recycleFile(file)
            if !original.isEmpty {
                try perform(Self.pathOptions + ["restore", "--worktree", "--"] + original, in: worktree)
            }
        default:
            try perform(Self.pathOptions + ["restore", "--staged", "--worktree", "--", path], in: worktree)
        }
    }

    /// Paths as written, never as patterns: a file named `*.ts` must not discard every TypeScript file.
    private static let pathOptions = ["--literal-pathspecs"]

    private func recycleFile(_ file: URL) throws {
        // Already gone from disk (added, then deleted): nothing to keep. The attributes are the link's own, so a
        // broken link still goes to the Trash.
        guard (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil else { return }
        do {
            try recycle(file)
        } catch {
            throw GitBranchError.failed(stderrTail: "Couldn’t move \(file.lastPathComponent) to the Trash: \(error.localizedDescription)")
        }
    }

    // MARK: Commit (GIT-04)

    /// `GIT-04`: every change in the worktree, untracked files included (`git add -A`), committed with `subject` and,
    /// when there is one, `description` as its body (`git commit -m <subject> -m <description>`). Hooks run: Rocky
    /// never passes `--no-verify`. What git and its hooks write reaches `output` as they write it, a batch of lines
    /// per read. A step that fails throws `GitCommitFailure` with its exit status and its last lines (`ERR-02`). A
    /// worktree in the middle of a rebase or a merge is refused: a commit there would land inside that operation.
    public func commit(worktree: URL, subject: String, description: String?, output: ([String]) -> Void) throws {
        if let gitDirectory = Self.gitDirectory(worktree: worktree),
           ["rebase-merge", "rebase-apply", "MERGE_HEAD"].contains(where: { FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent($0).path) }) {
            throw GitBranchError.failed(stderrTail: "A rebase or a merge is in progress in this worktree. Finish it first.")
        }
        try commitStep(["add", "-A"], command: "git add -A", in: worktree, output: output)
        var arguments = ["commit", "-m", subject]
        if let description, !description.isEmpty { arguments += ["-m", description] }
        try commitStep(arguments, command: "git commit", in: worktree, output: output)
    }

    /// The lines of a failed step kept for `GitCommitFailure`.
    static let commitFailureLineCount = 20

    private func commitStep(_ arguments: [String], command: String, in worktree: URL, output: ([String]) -> Void) throws {
        var decoder = CommandOutputDecoder()
        var tail: [String] = []
        let status: Int32
        do {
            status = try ProcessRunner.stream(Self.git, arguments, in: worktree, environment: environment) { data in
                Self.show(decoder.feed(data), tail: &tail, output: output)
            }
        } catch {
            throw GitBranchService.branchError(error)
        }
        Self.show(decoder.finish(), tail: &tail, output: output)
        guard status == 0 else {
            let lines = tail.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            throw GitCommitFailure(command: command, status: status, outputTail: lines.joined(separator: "\n"))
        }
    }

    /// Hands `lines` on and keeps the last of them for a failure. Hook output is the user's own tools, which may print
    /// the account's token they were given (`GH_TOKEN`).
    private static func show(_ lines: [String], tail: inout [String], output: ([String]) -> Void) {
        guard !lines.isEmpty else { return }
        let safe = lines.map { GitHubAccounts.withoutTokenShapes($0) }
        tail = Array((tail + safe).suffix(commitFailureLineCount))
        output(safe)
    }

    // MARK: Reading git's lists

    /// One entry of `git status --porcelain=v1 -z`: the index and worktree letters, the path, and the path a rename
    /// or copy came from.
    struct StatusEntry: Equatable {
        let index: UInt8
        let worktree: UInt8
        let path: String
        let originalPath: String?

        var isUntracked: Bool { index == UInt8(ascii: "?") }
    }

    /// Uncommitted entries of tracked files, or of every file with `includingUntracked`.
    func uncommittedEntries(worktree: URL, includingUntracked: Bool = false) throws -> [StatusEntry] {
        let untracked = includingUntracked ? "--untracked-files=all" : "--untracked-files=no"
        return Self.parseStatus(try output(Self.readOptions + ["status", "--porcelain=v1", "-z", untracked], in: worktree))
    }

    static func parseStatus(_ output: Data) -> [StatusEntry] {
        let fields = output.split(separator: 0, omittingEmptySubsequences: false).map { Array($0) }
        var entries: [StatusEntry] = []
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard field.count > 3 else { continue }
            let path = String(decoding: field[3...], as: UTF8.self)
            var original: String?
            // "R  new\0old\0": a rename or copy is followed by the path it came from.
            if [field[0], field[1]].contains(where: { $0 == UInt8(ascii: "R") || $0 == UInt8(ascii: "C") }), index < fields.count {
                original = String(decoding: fields[index], as: UTF8.self)
                index += 1
            }
            entries.append(StatusEntry(index: field[0], worktree: field[1], path: path, originalPath: original))
        }
        return entries
    }

    /// `git ls-files --others --exclude-standard -z`: untracked files that no ignore rule hides. A nested repository
    /// lists as its folder ("vendor/lib/"), which is left out.
    func untrackedPaths(worktree: URL) throws -> [String] {
        let data = try output(Self.readOptions + ["ls-files", "--others", "--exclude-standard", "-z"], in: worktree)
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.hasSuffix("/") }
    }

    static func sumNumstat(_ output: String) -> DiffStat {
        var stat = DiffStat()
        for line in output.split(separator: "\n") {
            // "12\t3\tpath"; a binary file is "-\t-\tpath".
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            stat.additions += Int(fields[0]) ?? 0
            stat.deletions += Int(fields[1]) ?? 0
            stat.files += 1
        }
        return stat
    }

    // MARK: Untracked files

    /// An untracked file as an added one: every line added, binary without rows (`DIFF-03`), and over 1 MB large and
    /// without rows, since its lines are not read into memory on every refresh.
    static func untrackedDiff(path: String, in worktree: URL) -> FileDiff {
        var file = FileDiff(path: path, status: .added, isUncommitted: true, isUntracked: true)
        guard let data = mappedContents(of: worktree.appendingPathComponent(path)) else { return file }
        if isBinary(data) {
            file.isBinary = true
            return file
        }
        let count = lineCount(data)
        file.additions = count
        file.isLarge = count > FileDiff.largeLineCount || data.count > FileDiff.largeByteCount
        guard count > 0, data.count <= FileDiff.largeByteCount else { return file }
        let lines = DiffParser.lines(of: String(decoding: data, as: UTF8.self))
        var hunk = Hunk(header: "@@ -0,0 +1,\(lines.count) @@", oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count)
        hunk.lines = lines.enumerated().map { DiffLine(kind: .added, oldNumber: nil, newNumber: $0.offset + 1, text: $0.element) }
        hunk.noNewlineAtEnd.new = data.last != UInt8(ascii: "\n")
        file.hunks = [hunk]
        return file
    }

    /// The file's bytes, mapped rather than copied; nil when it cannot be read (a folder, a broken link).
    static func mappedContents(of file: URL) -> Data? {
        try? Data(contentsOf: file, options: .alwaysMapped)
    }

    static func isBinary(_ data: Data) -> Bool {
        data.prefix(binarySniffLength).contains(0)
    }

    /// Lines as git counts them: a last line without a newline counts; binary files count none.
    static func lineCount(_ data: Data?) -> Int {
        guard let data, !data.isEmpty, !isBinary(data) else { return 0 }
        let newlines = data.withUnsafeBytes { buffer in
            buffer.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        }
        return newlines + (data.last == UInt8(ascii: "\n") ? 0 : 1)
    }

    // MARK: Running git

    @discardableResult
    private func perform(_ arguments: [String], in worktree: URL) throws -> String {
        do {
            return try runGit(arguments, in: worktree)
        } catch {
            throw GitBranchService.branchError(error)
        }
    }

    private func runGit(_ arguments: [String], in worktree: URL) throws -> String {
        try ProcessRunner.run(Self.git, arguments, in: worktree, environment: environment)
    }

    /// stdout as git wrote it: a patch's last line can be a lone space, and `status -z` can start with one.
    private func output(_ arguments: [String], in worktree: URL) throws -> Data {
        do {
            return try ProcessRunner.output(Self.git, arguments, in: worktree, environment: environment)
        } catch {
            throw GitBranchService.branchError(error)
        }
    }
}

/// A step of `GIT-04`'s commit that git ran and that failed: a hook that refused, nothing to commit, an index another
/// git holds. The sheet shows `summary` over the output it streamed (`ERR-02`).
public struct GitCommitFailure: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// "git add -A" or "git commit".
    public let command: String
    public let status: Int32
    /// The step's last lines, terminal escapes removed.
    public let outputTail: String

    public init(command: String, status: Int32, outputTail: String) {
        self.command = command
        self.status = status
        self.outputTail = outputTail
    }

    /// "git commit exited 1".
    public var summary: String { "\(command) exited \(status)" }

    public var description: String { outputTail.isEmpty ? summary + "." : summary + ":\n" + outputTail }

    public var errorDescription: String? { description }
}
