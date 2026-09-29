import Foundation
import RockyKit

/// What a diff's rows need from disk for one version of a file, off the main actor: the worktree file's lines for its
/// unchanged runs, the widest line in columns, and the syntax tokens. The diff tab (`UnifiedDiffView`) and the All
/// changes tab (`ALL-04`) read a file the same way.
@MainActor
enum DiffFileLoader {
    struct Lines: Equatable {
        let newLines: [String]?
        let maxColumns: Int
    }

    /// The worktree file when the rows need it (`DiffLayout.needsNewLines`), and the widest line of it and the hunks.
    static func lines(of file: FileDiff, worktree: String) async -> Lines {
        let wantsLines = DiffLayout.needsNewLines(file)
        let url = URL(fileURLWithPath: worktree).appendingPathComponent(file.path)
        return await Task.blocking { () -> Lines in
            let lines = wantsLines ? DiffLayout.readLines(of: url) : nil
            return Lines(newLines: lines, maxColumns: DiffMetrics.maxColumns(file: file, lines: lines))
        }.value
    }

    /// The tokens of the hunks and of `newLines`; none for a language Rocky does not highlight.
    static func tokens(of file: FileDiff, newLines: [String]?) async -> DiffTokens {
        guard let language = SyntaxHighlighter.language(forPath: file.path) else { return DiffTokens() }
        return await SyntaxHighlighter.shared.diffTokens(file: file, newLines: newLines, language: language)
    }
}
