import Foundation

/// Quick Open's list (`FIL-08`), pure so it is tested: the view ranks with it off the main actor, once per keystroke.
public enum QuickOpen {
    /// How many recently opened files each workspace keeps (`FIL-08`'s "the last 20 files opened in a tab here").
    public static let recentLimit = 20

    /// The files Quick Open lists for `query`. With a query, `FileTree.rank` with the recent files first inside each
    /// tier. With none: the recent files still in the list, newest first; then the changed files that are not recent,
    /// in `changed`'s order (`WorkspaceChanges`'); then every other file in Finder's order. `recent` and `changed` are
    /// worktree-relative; a path the list does not hold (a deleted file, one gone since it was opened) is left out, so
    /// each file shows once and every row opens.
    public static func results(query: String, list: FileList, recent: [String], changed: [String]) -> [String] {
        guard query.isEmpty else { return FileTree.rank(query, in: list, recent: recent) }
        let first = FileTree.positions(of: recent + changed, in: list)
        var results: [String] = []
        results.reserveCapacity(list.paths.count)
        for item in first { results.append(list.paths[item]) }
        // The rest in the list's order, skipping the ones above with one comparison per path.
        let skipped = first.sorted()
        var next = 0
        for (item, path) in list.paths.enumerated() {
            if next < skipped.count, skipped[next] == item {
                next += 1
                continue
            }
            results.append(path)
        }
        return results
    }
}
