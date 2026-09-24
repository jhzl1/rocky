import Foundation
import Testing
@testable import RockyKit

/// `DIFF-02`'s rows and `DIFF-03`'s large untracked file: the unchanged runs git leaves out of the patch, counted,
/// numbered on both sides and expanded from the worktree file.
struct DiffLayoutTests {
    /// Lines 1–5 of the new side changed from 1–4 of the old (one line added), then 21–24 against 20–23.
    private static let twoHunks = FileDiff(
        path: "src/a.ts",
        status: .modified,
        hunks: [
            Hunk(header: "@@ -1,4 +1,5 @@", oldStart: 1, oldCount: 4, newStart: 1, newCount: 5, lines: [
                DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "one"),
                DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "new"),
                DiffLine(kind: .context, oldNumber: 2, newNumber: 3, text: "two"),
                DiffLine(kind: .context, oldNumber: 3, newNumber: 4, text: "three"),
                DiffLine(kind: .context, oldNumber: 4, newNumber: 5, text: "four"),
            ]),
            Hunk(header: "@@ -20,4 +21,4 @@ func f()", oldStart: 20, oldCount: 4, newStart: 21, newCount: 4, lines: [
                DiffLine(kind: .context, oldNumber: 20, newNumber: 21, text: "twenty"),
                DiffLine(kind: .removed, oldNumber: 21, newNumber: nil, text: "old"),
                DiffLine(kind: .added, oldNumber: nil, newNumber: 22, text: "new"),
                DiffLine(kind: .context, oldNumber: 22, newNumber: 23, text: "twenty-two"),
                DiffLine(kind: .context, oldNumber: 23, newNumber: 24, text: "twenty-three"),
            ]),
        ],
        additions: 2,
        deletions: 1
    )

    /// The worktree file of `twoHunks`: 30 lines, "n1" to "n30".
    private static let thirtyLines = (1...30).map { "n\($0)" }

    private static func gaps(_ rows: [DiffRow]) -> [(DiffGap, Int)] {
        rows.compactMap { row in
            if case .gap(let gap, let count) = row { return (gap, count) }
            return nil
        }
    }

    private static func lines(_ rows: [DiffRow]) -> [DiffLine] {
        rows.compactMap { row in
            if case .line(let line) = row { return line }
            return nil
        }
    }

    @Test func theRunBetweenHunksCollapsesToItsCount() {
        let rows = DiffLayout.rows(for: Self.twoHunks, newLines: nil, expanded: [])
        #expect(rows.map(\.id) == ["h0", "l1:1", "l0:2", "l2:3", "l3:4", "l4:5", "g1", "h1", "l20:21", "l21:0", "l0:22", "l22:23", "l23:24"])
        let gaps = Self.gaps(rows)
        #expect(gaps.map(\.0) == [DiffGap(hunkIndex: 1)])
        // New lines 6 to 20.
        #expect(gaps.map(\.1) == [15])
    }

    @Test func anExpandedRunShowsItsLinesWithBothNumbers() {
        let rows = DiffLayout.rows(for: Self.twoHunks, newLines: Self.thirtyLines, expanded: [DiffGap(hunkIndex: 1)])
        let run = Self.lines(rows).filter { $0.kind == .context && ($0.newNumber ?? 0) >= 6 && ($0.newNumber ?? 0) <= 20 }
        #expect(run.count == 15)
        #expect(run.first == DiffLine(kind: .context, oldNumber: 5, newNumber: 6, text: "n6"))
        #expect(run.last == DiffLine(kind: .context, oldNumber: 19, newNumber: 20, text: "n20"))
        #expect(!Self.gaps(rows).contains { $0.0 == DiffGap(hunkIndex: 1) })
    }

    /// Only the file knows how long the run after the last hunk is.
    @Test func theRunAfterTheLastHunkNeedsTheFile() {
        #expect(!Self.gaps(DiffLayout.rows(for: Self.twoHunks, newLines: nil, expanded: [])).contains { $0.0 == DiffGap(hunkIndex: 2) })

        let rows = DiffLayout.rows(for: Self.twoHunks, newLines: Self.thirtyLines, expanded: [])
        #expect(rows.last == .gap(DiffGap(hunkIndex: 2), count: 6))

        let expanded = DiffLayout.rows(for: Self.twoHunks, newLines: Self.thirtyLines, expanded: [DiffGap(hunkIndex: 2)])
        #expect(Self.lines(expanded).suffix(6).first == DiffLine(kind: .context, oldNumber: 24, newNumber: 25, text: "n25"))
        #expect(Self.lines(expanded).last == DiffLine(kind: .context, oldNumber: 29, newNumber: 30, text: "n30"))
    }

    @Test func aRunBeforeTheFirstHunkStartsAtLineOne() {
        let file = FileDiff(path: "a.swift", status: .modified, hunks: [
            Hunk(header: "@@ -10,2 +10,3 @@", oldStart: 10, oldCount: 2, newStart: 10, newCount: 3, lines: [
                DiffLine(kind: .context, oldNumber: 10, newNumber: 10, text: "ten"),
                DiffLine(kind: .added, oldNumber: nil, newNumber: 11, text: "new"),
                DiffLine(kind: .context, oldNumber: 11, newNumber: 12, text: "eleven"),
            ]),
        ])
        let rows = DiffLayout.rows(for: file, newLines: Self.thirtyLines, expanded: [DiffGap(hunkIndex: 0)])
        #expect(Self.lines(rows).first == DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "n1"))
        #expect(Self.lines(rows)[8] == DiffLine(kind: .context, oldNumber: 9, newNumber: 9, text: "n9"))
        #expect(rows[9] == .hunk(index: 0, header: "@@ -10,2 +10,3 @@"))
    }

    /// An added or deleted file is one hunk from its first line to its last: nothing to collapse. A deleted file's new
    /// side is `+0,0`.
    @Test func anAddedOrDeletedFileHasNoRuns() {
        let deleted = FileDiff(path: "gone.txt", status: .deleted, hunks: [
            Hunk(header: "@@ -1,2 +0,0 @@", oldStart: 1, oldCount: 2, newStart: 0, newCount: 0, lines: [
                DiffLine(kind: .removed, oldNumber: 1, newNumber: nil, text: "a"),
                DiffLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "b"),
            ]),
        ])
        #expect(Self.gaps(DiffLayout.rows(for: deleted, newLines: [], expanded: [])).isEmpty)
        #expect(DiffLayout.rows(for: deleted, newLines: nil, expanded: []).count == 3)

        let added = FileDiff(path: "new.txt", status: .added, hunks: [
            Hunk(header: "@@ -0,0 +1,2 @@", oldStart: 0, oldCount: 0, newStart: 1, newCount: 2, lines: [
                DiffLine(kind: .added, oldNumber: nil, newNumber: 1, text: "a"),
                DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "b"),
            ]),
        ])
        #expect(Self.gaps(DiffLayout.rows(for: added, newLines: ["a", "b"], expanded: [])).isEmpty)
        #expect(!DiffLayout.needsNewLines(added))
        #expect(!DiffLayout.needsNewLines(deleted))
        #expect(DiffLayout.needsNewLines(Self.twoHunks))
    }

    /// DIFF-03's Show on an untracked file over 1 MB, which has no hunks (Task 1): every line of the file is added.
    @Test func aLargeUntrackedFileIsAddedRowsOnceRead() {
        let file = FileDiff(path: "big.log", status: .added, additions: 2, isUncommitted: true, isUntracked: true, isLarge: true)
        #expect(DiffLayout.needsNewLines(file))
        #expect(DiffLayout.rows(for: file, newLines: nil, expanded: []).isEmpty)
        #expect(DiffLayout.rows(for: file, newLines: ["a", "b"], expanded: []) == [
            .line(DiffLine(kind: .added, oldNumber: nil, newNumber: 1, text: "a")),
            .line(DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "b")),
        ])

        let binary = FileDiff(path: "a.png", status: .added, isBinary: true)
        #expect(!DiffLayout.needsNewLines(binary))
        #expect(!binary.isEditable)
    }

    /// `LazyVStack` needs one id per row, whatever is expanded.
    @Test func rowIdsAreUnique() {
        let rows = DiffLayout.rows(
            for: Self.twoHunks,
            newLines: Self.thirtyLines,
            expanded: [DiffGap(hunkIndex: 1), DiffGap(hunkIndex: 2)]
        )
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    /// CMT-02: a comment on a line of a collapsed run opens that run. Between the hunks the run is new lines 6–20 and old
    /// lines 5–19; after the last hunk, new 25–30 and old 24–29, which only the file's length tells.
    @Test func aRunHoldingACommentedLineIsFound() {
        let file = Self.twoHunks
        #expect(DiffLayout.gaps(holding: [CommentLine(side: .new, number: 10)], in: file, lineCount: nil) == [DiffGap(hunkIndex: 1)])
        #expect(DiffLayout.gaps(holding: [CommentLine(side: .old, number: 19)], in: file, lineCount: nil) == [DiffGap(hunkIndex: 1)])
        #expect(DiffLayout.gaps(holding: [CommentLine(side: .new, number: 21)], in: file, lineCount: 30).isEmpty)
        #expect(DiffLayout.gaps(holding: [CommentLine(side: .new, number: 27)], in: file, lineCount: nil).isEmpty)
        #expect(DiffLayout.gaps(holding: [CommentLine(side: .new, number: 27), CommentLine(side: .old, number: 5)], in: file, lineCount: 30)
            == [DiffGap(hunkIndex: 1), DiffGap(hunkIndex: 2)])
    }

    /// A file shorter than its diff (read after the agent cut it) shows the lines it has.
    @Test func aShorterFileShowsTheLinesItHas() {
        let rows = DiffLayout.rows(for: Self.twoHunks, newLines: Array(Self.thirtyLines.prefix(10)), expanded: [DiffGap(hunkIndex: 1)])
        let run = Self.lines(rows).filter { ($0.newNumber ?? 0) >= 6 && ($0.newNumber ?? 0) <= 20 && $0.kind == .context }
        #expect(run.map(\.newNumber) == [6, 7, 8, 9, 10])
    }

    @Test(.blockingWork) func readLinesKeepsCarriageReturnsAndSkipsBinaryFiles() throws {
        let folder = try Fixtures.temporaryDirectory("diff-layout")
        let text = folder.appendingPathComponent("crlf.txt")
        try Data("a\r\nb\n".utf8).write(to: text)
        #expect(DiffLayout.readLines(of: text) == ["a\r", "b"])

        let binary = folder.appendingPathComponent("a.bin")
        try Data([0x41, 0x00, 0x42]).write(to: binary)
        #expect(DiffLayout.readLines(of: binary) == nil)
        #expect(DiffLayout.readLines(of: folder.appendingPathComponent("missing.txt")) == nil)
    }
}
