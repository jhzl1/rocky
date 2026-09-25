import Foundation
import Testing
@testable import RockyKit

/// DIFF-06: an edit tool call's added and removed lines, counted per `diff` entry by the first rule that applies.
struct ToolDiffStatsTests {
    private func diff(_ oldText: String?, _ newText: String, stats: DiffStat? = nil) -> ToolCallDiff {
        ToolCallDiff(path: "/tmp/tokyo/README.md", oldText: oldText, newText: newText, stats: stats)
    }

    /// Rule 1: Claude's counts are used as sent, before the text is looked at, even on a hunk with no `oldText`.
    @Test func claudesStatsAreUsedAsSent() {
        #expect(ToolDiffStats.count([diff("a\nb", "a\nc", stats: DiffStat(additions: 7, deletions: 3))]) == DiffStat(additions: 7, deletions: 3))
        #expect(ToolDiffStats.count([diff(nil, "a\nb\nc", stats: DiffStat(additions: 2, deletions: 0))]) == DiffStat(additions: 2))
    }

    /// Rule 2: no `oldText` (a new file, or a hunk that only adds lines) adds every line of `newText`.
    @Test func aNewFileAddsEveryLine() {
        #expect(ToolDiffStats.count([diff(nil, "one\ntwo\nthree\n")]) == DiffStat(additions: 3))
        #expect(ToolDiffStats.count([diff(nil, "one\ntwo")]) == DiffStat(additions: 2))
        #expect(ToolDiffStats.count([diff(nil, "")]) == DiffStat())
        // OpenCode sends "" as a new file's old text: empty text has no lines, so rule 3 adds them all.
        #expect(ToolDiffStats.count([diff("", "one\ntwo\n")]) == DiffStat(additions: 2))
    }

    /// Rule 3: Claude's hunks carry context lines on both sides, and the diff drops them.
    @Test func contextLinesAreNotCounted() {
        let hunk = diff("import A\nlet x = 1\nlet y = 2\nprint(x)", "import A\nlet x = 10\nprint(x)")
        #expect(ToolDiffStats.count([hunk]) == DiffStat(additions: 1, deletions: 2))
        #expect(ToolDiffStats.count([diff("a\nb\nc", "a\nb\nc")]) == DiffStat())
    }

    /// The empty piece after a final newline is not a line, and "\r\n" ends a line like "\n".
    @Test func aFinalNewlineStartsNoLine() {
        #expect(ToolDiffStats.count([diff("a\nb", "a\nb\n")]) == DiffStat())
        #expect(ToolDiffStats.count([diff(nil, "\n")]) == DiffStat(additions: 1))
        #expect(ToolDiffStats.count([diff(nil, "a\n\n")]) == DiffStat(additions: 2))
        #expect(ToolDiffStats.count([diff(nil, "a\r\nb\r\n")]) == DiffStat(additions: 2))
        #expect(ToolDiffStats.count([diff("a\r\nb\r\n", "a\r\nc\r\n")]) == DiffStat(additions: 1, deletions: 1))
    }

    /// Rule 3 runs up to 5,000 lines for both sides together; over it the entry has no counts.
    @Test func overTheCapTheEntryHasNoCounts() {
        let old = (1...2_500).map { "old \($0)" }.joined(separator: "\n")
        let atTheCap = (1...2_500).map { "new \($0)" }.joined(separator: "\n") + "\n"
        #expect(ToolDiffStats.count([diff(old, atTheCap)]) == DiffStat(additions: 2_500, deletions: 2_500))
        #expect(ToolDiffStats.count([diff(old, atTheCap + "one more")]) == nil)
        // Rule 2 has no cap.
        #expect(ToolDiffStats.count([diff(nil, atTheCap + atTheCap)]) == DiffStat(additions: 5_000))
    }

    /// One label per call: the sum over its entries, also across files; one entry it cannot count makes it nil.
    @Test func oneUncountableEntryMakesTheCallUncountable() {
        let small = diff("a", "b")
        #expect(ToolDiffStats.count([small, diff(nil, "c\nd"), diff("x", "y", stats: DiffStat(additions: 4, deletions: 1))])
            == DiffStat(additions: 7, deletions: 2))
        let huge = (1...5_001).map(String.init).joined(separator: "\n")
        #expect(ToolDiffStats.count([small, diff("", huge)]) == nil)
        #expect(ToolDiffStats.count([]) == nil)
    }

    /// A row's label and a group's: the sum of what the rows say, hidden at 0 and when no row has counts.
    @Test func theLabelSumsTheRowsAndHidesAtZero() {
        let edit = ChatItem(kind: .tool, text: "Edit a.ts", status: "completed", diffStat: DiffStat(additions: 2, deletions: 1))
        let write = ChatItem(kind: .tool, text: "Write b.ts", status: "completed", diffStat: DiffStat(additions: 10))
        let read = ChatItem(kind: .tool, text: "Read c.ts", status: "completed")
        let unchanged = ChatItem(kind: .tool, text: "Write d.ts", status: "completed", diffStat: DiffStat())
        #expect(ToolDiffStats.label(for: [write]) == DiffStat(additions: 10))
        // The same line edited twice counts twice.
        #expect(ToolDiffStats.label(for: [edit, read, write, edit]) == DiffStat(additions: 14, deletions: 2))
        #expect(ToolDiffStats.label(for: [read, unchanged]) == nil)
        #expect(ToolDiffStats.label(for: [unchanged]) == nil)
    }
}
