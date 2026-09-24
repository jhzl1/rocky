import Foundation
import Testing
@testable import RockyKit

/// `GIT-01`, `GIT-03` and `GIT-05` on temporary repositories (`GitFixture`).
@Suite(.blockingWork)
struct GitChangesServiceTests {
    private let service = GitChangesService(environment: GitFixture.environment)

    private func write(_ text: String, to path: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func commit(_ paths: [String], message: String, in repo: URL) throws {
        try GitFixture.git(["add"] + paths, in: repo)
        try GitFixture.git(["commit", "-q", "-m", message], in: repo)
    }

    private func read(_ path: String, in repo: URL) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// A clone on `feature` with one of each kind of change: a commit of the branch (`committed.txt`, `.gitignore`), a
    /// staged new file, an unstaged edit, an untracked file in a folder, and an ignored file.
    private func cloneWithEveryKindOfChange() throws -> URL {
        let repo = try GitFixture.clonedRepo(in: try Fixtures.temporaryDirectory("changes"))
        try write("ignored.log\n", to: ".gitignore", in: repo)
        try write("one\ntwo\n", to: "committed.txt", in: repo)
        try commit([".gitignore", "committed.txt"], message: "branch work", in: repo)
        try write("staged\n", to: "staged.txt", in: repo)
        try GitFixture.git(["add", "staged.txt"], in: repo)
        try write("hello\nchanged\n", to: "README.md", in: repo)
        try write("untracked\n", to: "notes/untracked.txt", in: repo)
        try write("noise\n", to: "ignored.log", in: repo)
        return repo
    }

    @Test func committedStagedUnstagedAndUntrackedAllAppear() throws {
        let repo = try cloneWithEveryKindOfChange()
        let base = try service.base(worktree: repo, baseRef: "origin/trunk")
        let changes = try service.changes(worktree: repo, base: base)

        #expect(changes.base == base)
        #expect(changes.files.map(\.path) == [".gitignore", "README.md", "committed.txt", "notes/untracked.txt", "staged.txt"])
        #expect(changes.files.map(\.status) == [.added, .modified, .added, .added, .added])
        #expect(changes.files.map(\.isUncommitted) == [false, true, false, true, true])
        #expect(changes.files.map(\.isUntracked) == [false, false, false, true, false])
        #expect(changes.uncommitted.map(\.path) == ["README.md", "notes/untracked.txt", "staged.txt"])
        #expect(changes.committed.map(\.path) == [".gitignore", "committed.txt"])

        let untracked = try #require(changes.file(at: "notes/untracked.txt"))
        #expect(untracked.additions == 1)
        #expect(untracked.hunks.first?.lines == [DiffLine(kind: .added, oldNumber: nil, newNumber: 1, text: "untracked")])
        let readme = try #require(changes.file(at: "README.md"))
        #expect(readme.additions == 1)
        #expect(readme.deletions == 0)
    }

    /// GIT-03: the sidebar's numbers are the Changes tab's totals, untracked lines included.
    @Test func shortstatMatchesTheParsedTotals() throws {
        let repo = try cloneWithEveryKindOfChange()
        let base = try service.base(worktree: repo, baseRef: "origin/trunk")
        let changes = try service.changes(worktree: repo, base: base)
        let stat = try service.shortstat(worktree: repo, base: base)
        #expect(stat == changes.stat)
        // .gitignore 1, committed.txt 2, staged.txt 1, README.md 1, notes/untracked.txt 1.
        #expect(stat == DiffStat(additions: 6, deletions: 0, files: 5))
    }

    /// The base is where the branch left its base branch, not the base branch's tip: commits the base branch gained
    /// since are not the workspace's changes.
    @Test func baseIsTheMergeBaseAfterTheBaseBranchMoves() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("changes"))
        let forkPoint = try GitFixture.git(["rev-parse", "HEAD"], in: repo)
        try GitFixture.git(["switch", "-q", "-c", "feature"], in: repo)
        try write("feature\n", to: "feature.txt", in: repo)
        try commit(["feature.txt"], message: "feature", in: repo)
        try GitFixture.git(["switch", "-q", "main"], in: repo)
        try write("main\n", to: "main-only.txt", in: repo)
        try commit(["main-only.txt"], message: "main moves on", in: repo)
        try GitFixture.git(["switch", "-q", "feature"], in: repo)

        let base = try service.base(worktree: repo, baseRef: "main")
        #expect(base == forkPoint)
        #expect(try service.changes(worktree: repo, base: base).files.map(\.path) == ["feature.txt"])
    }

    /// GIT-01: a workspace made by M1 has no `baseRef`; origin/HEAD's branch stands in.
    @Test func nilBaseRefFallsBackToOriginHEADsBranch() throws {
        let repo = try GitFixture.clonedRepo(in: try Fixtures.temporaryDirectory("changes"))
        try write("feature\n", to: "feature.txt", in: repo)
        try commit(["feature.txt"], message: "feature", in: repo)

        let base = try service.base(worktree: repo, baseRef: nil)
        #expect(base == (try GitFixture.git(["rev-parse", "origin/trunk"], in: repo)))
    }

    /// Without origin, the repository's current branch: the main folder's, read from a worktree.
    @Test func nilBaseRefWithoutOriginIsTheMainFoldersBranch() throws {
        let parent = try Fixtures.temporaryDirectory("changes")
        let repo = try GitFixture.localRepo(in: parent)
        let worktree = parent.appendingPathComponent("tokyo", isDirectory: true)
        try GitFixture.git(["worktree", "add", "-q", "-b", "rocky/tokyo", worktree.path], in: repo)
        try write("tokyo\n", to: "tokyo.txt", in: worktree)
        try commit(["tokyo.txt"], message: "tokyo", in: worktree)

        let base = try service.base(worktree: worktree, baseRef: nil)
        #expect(base == (try GitFixture.git(["rev-parse", "main"], in: repo)))
    }

    /// GIT-01's busy check reads the worktree's own git directory, which its `.git` file names, and the watcher watches
    /// that directory too.
    @Test func aLockedIndexIsBusyInTheWorktreesGitDirectory() throws {
        let parent = try Fixtures.temporaryDirectory("changes")
        let repo = try GitFixture.localRepo(in: parent)
        let worktree = parent.appendingPathComponent("lisbon", isDirectory: true)
        try GitFixture.git(["worktree", "add", "-q", "-b", "rocky/lisbon", worktree.path], in: repo)

        let gitDirectory = try #require(GitChangesService.gitDirectory(worktree: worktree))
        let expected = repo.appendingPathComponent(".git/worktrees/lisbon")
        #expect(FileWatcher.canonicalPath(gitDirectory) == FileWatcher.canonicalPath(expected))
        #expect(FileWatcher.workspacePaths(worktree: worktree).map(FileWatcher.canonicalPath)
            == [FileWatcher.canonicalPath(worktree), FileWatcher.canonicalPath(expected)])
        #expect(!GitChangesService.isBusy(worktree: worktree))

        let lock = gitDirectory.appendingPathComponent("index.lock")
        try Data().write(to: lock)
        #expect(GitChangesService.isBusy(worktree: worktree))
        try FileManager.default.removeItem(at: lock)
        #expect(!GitChangesService.isBusy(worktree: worktree))
    }

    /// DIFF-03's "Binary file · 24 KB → 31 KB": the old size is the base's object, whatever the worktree holds now.
    @Test func blobSizeIsTheFilesSizeAtTheCommit() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("changes"))
        let base = try GitFixture.git(["rev-parse", "HEAD"], in: repo)
        try write("a longer readme\n", to: "README.md", in: repo)

        #expect(service.blobSize(worktree: repo, commit: base, path: "README.md") == 6)
        #expect(service.blobSize(worktree: repo, commit: base, path: "missing.png") == nil)
    }

    /// EDIT-04's base for the change bars: the file's bytes at the commit, whatever the worktree holds now.
    @Test func blobIsTheFileAtTheCommit() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("changes"))
        let base = try GitFixture.git(["rev-parse", "HEAD"], in: repo)
        try write("a longer readme\n", to: "README.md", in: repo)

        #expect(service.blob(worktree: repo, commit: base, path: "README.md") == Data("hello\n".utf8))
        #expect(service.blob(worktree: repo, commit: base, path: "missing.txt") == nil)
    }

    // MARK: Discard (GIT-05)

    @Test func discardRestoresATrackedFile() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("changes"))
        try write("staged\n", to: "README.md", in: repo)
        try GitFixture.git(["add", "README.md"], in: repo)
        try write("staged and edited\n", to: "README.md", in: repo)

        try service.discard(worktree: repo, path: "README.md", isUntracked: false)

        #expect(try read("README.md", in: repo) == "hello\n")
        #expect(try GitFixture.git(["status", "--porcelain"], in: repo).isEmpty)
    }

    @Test func discardMovesAnUntrackedFileToTheTrash() throws {
        let parent = try Fixtures.temporaryDirectory("changes")
        let repo = try GitFixture.localRepo(in: parent)
        let trash = parent.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let service = GitChangesService(environment: GitFixture.environment) { file in
            try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent))
        }
        try write("draft\n", to: "notes/draft.md", in: repo)

        // The list saw it tracked: it changed since, so nothing happens.
        #expect(throws: GitBranchError.self) {
            try service.discard(worktree: repo, path: "notes/draft.md", isUntracked: false)
        }
        try service.discard(worktree: repo, path: "notes/draft.md", isUntracked: true)

        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("notes/draft.md").path))
        #expect(try read("draft.md", in: trash) == "draft\n")
    }

    /// Restoring a path HEAD lacks would delete it: a file only added to the index is unstaged and goes to the Trash.
    @Test func discardSendsAStagedNewFileToTheTrash() throws {
        let parent = try Fixtures.temporaryDirectory("changes")
        let repo = try GitFixture.localRepo(in: parent)
        let trash = parent.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let service = GitChangesService(environment: GitFixture.environment) { file in
            try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent))
        }
        try write("new\n", to: "added.txt", in: repo)
        try GitFixture.git(["add", "added.txt"], in: repo)

        try service.discard(worktree: repo, path: "added.txt", isUntracked: false)

        #expect(try read("added.txt", in: trash) == "new\n")
        #expect(try GitFixture.git(["status", "--porcelain"], in: repo).isEmpty)
    }

    @Test func discardRefusesACommittedOnlyFile() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("changes"))
        try write("done\n", to: "done.txt", in: repo)
        try commit(["done.txt"], message: "done", in: repo)
        let head = try GitFixture.git(["rev-parse", "HEAD"], in: repo)

        #expect(throws: GitBranchError.self) {
            try service.discard(worktree: repo, path: "done.txt", isUntracked: false)
        }
        #expect(try read("done.txt", in: repo) == "done\n")
        #expect(try GitFixture.git(["rev-parse", "HEAD"], in: repo) == head)
    }

    // MARK: Commit (GIT-04, ERR-02)

    /// An executable hook in the repository's hooks folder.
    private func installHook(_ name: String, _ script: String, in repo: URL) throws {
        let hook = repo.appendingPathComponent(".git/hooks/\(name)")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    /// GIT-04: `git add -A` takes every change, untracked files included, and the description is the message's body.
    /// git's own lines reach the caller.
    @Test func commitIncludesUntrackedFiles() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("commit"))
        try write("edited\n", to: "README.md", in: repo)
        try write("new\n", to: "notes/new.txt", in: repo)
        try write("staged\n", to: "staged.txt", in: repo)
        try GitFixture.git(["add", "staged.txt"], in: repo)
        var output: [String] = []

        try service.commit(worktree: repo, subject: "Add the notes", description: "Two files and an edit.") { output += $0 }

        #expect(try GitFixture.git(["status", "--porcelain"], in: repo).isEmpty)
        #expect(try GitFixture.git(["log", "-1", "--format=%B"], in: repo) == "Add the notes\n\nTwo files and an edit.")
        let files = try GitFixture.git(["show", "--name-only", "--format=", "HEAD"], in: repo)
        #expect(files.split(separator: "\n").map(String.init) == ["README.md", "notes/new.txt", "staged.txt"])
        #expect(output.contains { $0.contains("Add the notes") })
    }

    /// ERR-02: a hook that refuses stops the commit. What it wrote reaches the caller as it runs, in order and without
    /// its colors, and the failure has git's exit status and those last lines. The hook always runs: no `--no-verify`.
    @Test func failingHookReportsItsOutput() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("commit"))
        let head = try GitFixture.git(["rev-parse", "HEAD"], in: repo)
        try installHook("pre-commit", #"""
            #!/bin/sh
            echo 'checking 1 file'
            printf '\033[31mlint failed: README.md\033[0m\n' >&2
            exit 1

            """#, in: repo)
        try write("edited\n", to: "README.md", in: repo)
        var output: [String] = []

        do {
            try service.commit(worktree: repo, subject: "Edit", description: nil) { output += $0 }
            Issue.record("The commit went through its failing hook.")
        } catch let failure as GitCommitFailure {
            #expect(failure.command == "git commit")
            #expect(failure.status == 1)
            #expect(failure.outputTail == "checking 1 file\nlint failed: README.md")
            #expect(failure.summary == "git commit exited 1")
        }
        #expect(output == ["checking 1 file", "lint failed: README.md"])
        #expect(try GitFixture.git(["rev-parse", "HEAD"], in: repo) == head)
    }

    /// GIT-04: a hook that passes runs too, and its output comes before git's own.
    @Test func aPassingHookRunsFirst() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("commit"))
        try installHook("pre-commit", "#!/bin/sh\necho 'formatting'\nexit 0\n", in: repo)
        try write("edited\n", to: "README.md", in: repo)
        var output: [String] = []

        try service.commit(worktree: repo, subject: "Format", description: nil) { output += $0 }

        #expect(output.first == "formatting")
        #expect(output.dropFirst().contains { $0.contains("Format") })
        #expect(try GitFixture.git(["log", "-1", "--format=%s"], in: repo) == "Format")
    }

    /// A commit in the middle of a rebase would land inside it: refused before anything is staged.
    @Test func commitRefusesDuringARebase() throws {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("commit"))
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true)
        try write("edited\n", to: "README.md", in: repo)

        #expect(throws: GitBranchError.self) {
            try service.commit(worktree: repo, subject: "Edit", description: nil) { _ in }
        }
        #expect(try GitFixture.git(["diff", "--cached", "--name-only"], in: repo).isEmpty)
    }
}

/// GIT-04's output as the commit sheet shows it.
struct CommandOutputDecoderTests {
    /// Lines come whole, even when a read splits a character in two, and the last one comes at the end.
    @Test func linesComeWholeAcrossReads() {
        var decoder = CommandOutputDecoder()
        let bytes = Array("héllo\nwor".utf8)
        // "h" and the first byte of "é".
        let first = decoder.feed(Data(bytes[..<2]))
        let second = decoder.feed(Data(bytes[2...]))
        let third = decoder.feed(Data("ld\n\n".utf8))
        let fourth = decoder.feed(Data("done".utf8))
        let last = decoder.finish()
        let afterTheEnd = decoder.finish()

        #expect(first == [])
        #expect(second == ["héllo"])
        #expect(third == ["world", ""])
        #expect(fourth == [])
        #expect(last == ["done"])
        #expect(afterTheEnd == [])
    }

    /// Colors, a window title and a bell go; CRLF ends a line; a line carriage returns rewrote shows its last version.
    @Test func escapesGoAndARewrittenLineShowsItsLastVersion() {
        var decoder = CommandOutputDecoder()
        let text = "\u{1B}[1;32m✔\u{1B}[0m lint\r\n10%\r50%\r100%\n\u{1B}]0;title\u{07}tab\there\u{07}\n"
        let lines = decoder.feed(Data(text.utf8))
        #expect(lines == ["✔ lint", "100%", "tab\there"])
    }

    /// The sheet keeps the output's last lines: a hook running a test suite can print thousands.
    @Test func commitProgressKeepsItsLastLines() {
        var progress = CommitProgress(subject: "Edit", description: "")
        progress.append((1...CommitProgress.maxLines).map { "line \($0)" })
        progress.append(["one more"])
        #expect(progress.lines.count == CommitProgress.maxLines)
        #expect(progress.lines.first == "line 2")
        #expect(progress.lines.last == "one more")
        #expect(progress.isRunning)
        progress.fail("git commit exited 1")
        #expect(!progress.isRunning)
    }
}
