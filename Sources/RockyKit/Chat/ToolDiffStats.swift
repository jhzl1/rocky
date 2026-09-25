import Foundation

/// `DIFF-06`: the lines a tool call added and removed, from the ACP `diff` entries of its content, like Conductor's
/// edit rows (user request, 2026-09-25).
public enum ToolDiffStats {
    /// An entry is diffed line by line only when its two sides together have at most this many lines.
    public static let lineDiffLimit = 5_000

    /// The sum over `diffs`, each entry counted by the first rule that applies:
    /// 1. Claude's own counts (`ToolCallDiff.stats`), as sent;
    /// 2. no `oldText` (a new file, or a hunk that only adds lines): every line of `newText` is added;
    /// 3. a line diff of `oldText` against `newText` (`CollectionDifference`): its insertions are added and its
    ///    removals removed, so the context lines Claude's hunks carry, being on both sides, count on neither. Only up to
    ///    `lineDiffLimit` lines.
    ///
    /// nil with no entries, and when any entry cannot be counted: a partial sum would be wrong. `files` stays 0.
    /// Step 3 is CPU work, up to 5,000 lines: call this off the main actor.
    public static func count(_ diffs: [ToolCallDiff]) -> DiffStat? {
        guard !diffs.isEmpty else { return nil }
        var total = DiffStat()
        for diff in diffs {
            guard let stat = count(diff) else { return nil }
            total.additions += stat.additions
            total.deletions += stat.deletions
        }
        return total
    }

    static func count(_ diff: ToolCallDiff) -> DiffStat? {
        if let stats = diff.stats { return DiffStat(additions: stats.additions, deletions: stats.deletions) }
        guard let oldText = diff.oldText else { return DiffStat(additions: lines(of: diff.newText).count) }
        let old = lines(of: oldText)
        let new = lines(of: diff.newText)
        guard old.count + new.count <= lineDiffLimit else { return nil }
        // Each distinct line gets a number, so the diff compares integers instead of strings.
        var numbers: [Substring: Int] = [:]
        func numbered(_ lines: [Substring]) -> [Int] {
            lines.map { line in
                if let number = numbers[line] { return number }
                numbers[line] = numbers.count
                return numbers.count - 1
            }
        }
        let oldNumbers = numbered(old)
        let difference = numbered(new).difference(from: oldNumbers)
        return DiffStat(additions: difference.insertions.count, deletions: difference.removals.count)
    }

    /// `text` split on "\n": the empty piece after a final newline is not a line, and empty text has none. Split on the
    /// scalar, not the `Character`, since "\r\n" is one `Character` and a file with Windows line endings would read as
    /// one line.
    static func lines(of text: String) -> [Substring] {
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(Substring.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// The label of a tool row, or of a group's header: the sum of the calls' counts; nil when none has counts or the
    /// sum is 0 on both sides. A group's is what its rows say, not the files' net change: a line edited twice counts
    /// twice.
    public static func label(for tools: [ChatItem]) -> DiffStat? {
        var total = DiffStat()
        for stat in tools.compactMap(\.diffStat) {
            total.additions += stat.additions
            total.deletions += stat.deletions
        }
        return total.isEmpty ? nil : total
    }
}
