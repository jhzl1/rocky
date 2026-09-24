import Foundation

/// What the All files tab reads from a worktree (`FIL-04`, `FIL-07`): git's list of its files and one folder's
/// listing. `WorktreeFiles` in Rocky; `AppModel` tests pass their own, which count the reads.
public protocol WorktreeFileReading: Sendable {
    /// `previous` is the list the tab has: when git prints the same, it comes back as it is, unsorted again.
    func list(worktree: URL, reusing previous: FileList?) throws -> FileList
    func listing(worktree: URL, folder: String) throws -> [FileEntry]
}

/// The worktree's files for the All files tab (`FIL-02`…`FIL-04`, `FIL-07`): `git ls-files` through `ProcessRunner`
/// with the workspace environment, and folder listings from `FileManager`. Synchronous and blocking, like
/// `GitChangesService`: callers run it through `Task.blocking`, when the tab shows and after a change on disk, never on
/// a timer.
public struct WorktreeFiles: WorktreeFileReading {
    private static let git = URL(fileURLWithPath: "/usr/bin/git")
    /// No optional lock, so Rocky never holds the index lock an agent's own git needs.
    private static let readOptions = ["--no-optional-locks", "-c", "core.quotepath=off"]

    public let environment: [String: String]

    public init(environment: [String: String]) {
        self.environment = WorktreeService.nonInteractive(environment)
    }

    /// `FIL-04`'s source: `git ls-files --cached --others --exclude-standard -z` (tracked and untracked files, ignored
    /// ones left out), minus `git ls-files --deleted -z`, since `--cached` still lists a file deleted from disk but not
    /// staged (`FIL-02`'s "Deleted").
    public func list(worktree: URL) throws -> FileList {
        try list(worktree: worktree, reusing: nil)
    }

    public func list(worktree: URL, reusing previous: FileList?) throws -> FileList {
        let listed = try paths(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], in: worktree)
        let deleted = try paths(["ls-files", "--deleted", "-z"], in: worktree)
        // The same output keeps the list it had: nothing is sorted again, and its identity stays, so the view neither
        // ranks nor redraws for a change that moved no file.
        if let previous, previous.listed == listed, previous.deleted == deleted { return previous }
        return FileList(listed: listed, deleted: deleted)
    }

    /// One folder's entries (`FileManager.contentsOfDirectory`), dotfiles included, in `FIL-02`'s order
    /// (`FileTree.sorted`). `.git` never shows. A symbolic link lists as what it points to, so `WorktreeLinker`'s `.env`
    /// links are files and a linked folder is a folder; a broken link lists as a file. `folder` is worktree-relative, ""
    /// the root.
    public func listing(worktree: URL, folder: String) throws -> [FileEntry] {
        let directory = folder.isEmpty ? worktree : worktree.appendingPathComponent(folder, isDirectory: true)
        let manager = FileManager.default
        let urls = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        let entries = urls.compactMap { url -> FileEntry? in
            let name = url.lastPathComponent
            guard name != ".git" else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink == true else {
                return FileEntry(name: name, isDirectory: values?.isDirectory ?? false)
            }
            // A link's own values describe the link: what it points to decides, and nothing there is a file.
            var isDirectory: ObjCBool = false
            let exists = manager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return FileEntry(name: name, isDirectory: exists && isDirectory.boolValue)
        }
        return FileTree.sorted(entries)
    }

    /// One `ls-files` run's paths, NUL-separated as `-z` prints them, verbatim.
    private func paths(_ arguments: [String], in worktree: URL) throws -> [String] {
        let data: Data
        do {
            data = try ProcessRunner.output(Self.git, Self.readOptions + arguments, in: worktree, environment: environment)
        } catch {
            throw GitBranchService.branchError(error)
        }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
}
