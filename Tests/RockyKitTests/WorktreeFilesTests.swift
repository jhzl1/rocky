import Foundation
import Testing
@testable import RockyKit

/// `FIL-02`…`FIL-04` and `FIL-07`'s reads on temporary repositories (`GitFixture`): git's list and one folder's listing.
@Suite(.blockingWork)
struct WorktreeFilesTests {
    private let files = WorktreeFiles(environment: GitFixture.environment)

    private func write(_ text: String, to path: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A repository with a tracked `.gitignore` hiding `dist/` and `.env`, a tracked file in a folder, an untracked
    /// file, and one ignored file of each kind.
    private func repoWithIgnoredFiles() throws -> URL {
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("files"))
        try write("dist/\n.env\n", to: ".gitignore", in: repo)
        try write("export const a = 1\n", to: "src/a.ts", in: repo)
        try GitFixture.git(["add", ".gitignore", "src/a.ts"], in: repo)
        try GitFixture.git(["commit", "-q", "-m", "files"], in: repo)
        try write("draft\n", to: "src/new.ts", in: repo)
        try write("built\n", to: "dist/out.js", in: repo)
        try write("A=1\n", to: ".env", in: repo)
        return repo
    }

    /// FIL-04's source: tracked and untracked files, in Finder's order; ignored ones are neither listed nor shown as
    /// anything but ignored (FIL-03).
    @Test func listHasTrackedAndUntrackedButNotIgnored() throws {
        let repo = try repoWithIgnoredFiles()
        let list = try files.list(worktree: repo)
        #expect(list.paths == [".gitignore", "README.md", "src/a.ts", "src/new.ts"])
        #expect(list.isIgnored("dist"))
        #expect(list.isIgnored("dist/out.js"))
        #expect(list.isIgnored(".env"))
        #expect(!list.isIgnored("src"))
        #expect(!list.isIgnored(".gitignore"))

        // The same output keeps the list it had.
        let again = try files.list(worktree: repo, reusing: list)
        #expect(again == list)
        try write("more\n", to: "src/more.ts", in: repo)
        #expect(try files.list(worktree: repo, reusing: list).paths.contains("src/more.ts"))
    }

    /// FIL-02's "Deleted": `--cached` still lists a file deleted from disk but not staged; `--deleted` takes it out.
    @Test func listLeavesOutFilesDeletedFromDisk() throws {
        let repo = try repoWithIgnoredFiles()
        try FileManager.default.removeItem(at: repo.appendingPathComponent("src/a.ts"))
        let list = try files.list(worktree: repo)
        #expect(!list.paths.contains("src/a.ts"))
        #expect(list.paths.contains("src/new.ts"))
    }

    /// A folder's listing: dotfiles included, `.git` never (FIL-03); folders first, then files, in Finder's order; a
    /// link lists as what it points to, and a broken one as a file (`WorktreeLinker`'s `.env` links).
    @Test func listingNeverShowsGit() throws {
        let repo = try repoWithIgnoredFiles()
        let manager = FileManager.default
        try manager.createSymbolicLink(at: repo.appendingPathComponent("linked.env"), withDestinationURL: repo.appendingPathComponent(".env"))
        try manager.createSymbolicLink(at: repo.appendingPathComponent("linked-src"), withDestinationURL: repo.appendingPathComponent("src"))
        try manager.createSymbolicLink(at: repo.appendingPathComponent("broken"), withDestinationURL: repo.appendingPathComponent("nowhere"))
        try write("x\n", to: "file10.txt", in: repo)
        try write("x\n", to: "file2.txt", in: repo)

        let root = try files.listing(worktree: repo, folder: "")
        #expect(!root.contains { $0.name == ".git" })
        #expect(root.filter(\.isDirectory).map(\.name) == ["dist", "linked-src", "src"])
        let names = root.filter { !$0.isDirectory }.map(\.name)
        #expect(names.contains(".env"))
        #expect(names.contains(".gitignore"))
        #expect(names.contains("linked.env"))
        #expect(names.contains("broken"))
        #expect(names.firstIndex(of: "file2.txt")! < names.firstIndex(of: "file10.txt")!)
        #expect(root.firstIndex { !$0.isDirectory }! > root.lastIndex { $0.isDirectory }!)

        #expect(try files.listing(worktree: repo, folder: "src").map(\.name) == ["a.ts", "new.ts"])
    }
}
