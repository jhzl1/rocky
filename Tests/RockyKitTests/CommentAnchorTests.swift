import Foundation
import Testing
@testable import RockyKit

/// CMT-04 (Review Focus 2): a comment stays on its lines when lines are inserted above it, and turns Outdated when its
/// lines change. Also what a new comment keeps of its lines (CMT-03) and where the diff draws it (CMT-02).
struct CommentAnchorTests {
    private static let file = ["import a", "", "func operation() {", "  return 1", "}", "", "func other() {}"]
    /// Lines 3–5 of `file`.
    private static let snippet = ["func operation() {", "  return 1", "}"]
    private static let day = Date(timeIntervalSince1970: 1_790_000_000)

    private static func comment(
        _ id: String,
        path: String = "a.ts",
        side: DiffCommentRecord.Side = .new,
        lines: ClosedRange<Int>,
        snippet: [String],
        state: DiffCommentRecord.State = .pending
    ) -> DiffCommentRecord {
        DiffCommentRecord(
            id: id,
            workspaceId: "w1",
            path: path,
            side: side,
            startLine: lines.lowerBound,
            endLine: lines.upperBound,
            snippet: snippet,
            body: "Comment \(id)",
            state: state,
            createdAt: Self.day
        )
    }

    // MARK: relocate

    @Test func unchangedLinesKeepTheRange() {
        #expect(CommentAnchor.relocate(snippet: Self.snippet, start: 3, in: Self.file) == 3...5)
    }

    @Test func linesInsertedAboveShiftTheRange() {
        let file = ["// header", "// more"] + Self.file
        #expect(CommentAnchor.relocate(snippet: Self.snippet, start: 3, in: file) == 5...7)
        let fewer = Array(Self.file.dropFirst(2))
        #expect(CommentAnchor.relocate(snippet: Self.snippet, start: 3, in: fewer) == 1...3)
    }

    @Test func anEditedCommentedLineIsOutdated() {
        var file = Self.file
        file[3] = "  return 2"
        #expect(CommentAnchor.relocate(snippet: Self.snippet, start: 3, in: file) == nil)
        // A line inserted inside the range breaks it too.
        var split = Self.file
        split.insert("  log()", at: 4)
        #expect(CommentAnchor.relocate(snippet: Self.snippet, start: 3, in: split) == nil)
    }

    /// Copies at lines 2 and 8: from line 6 the second is nearer; from line 5 both are 3 away and the one above wins.
    @Test func theSnippetTwiceGoesToTheNearestMatch() {
        let file = ["a", "x()", "y()", "b", "c", "d", "e", "x()", "y()", "f"]
        #expect(CommentAnchor.relocate(snippet: ["x()", "y()"], start: 6, in: file) == 8...9)
        #expect(CommentAnchor.relocate(snippet: ["x()", "y()"], start: 5, in: file) == 2...3)
        #expect(CommentAnchor.relocate(snippet: ["x()", "y()"], start: 8, in: file) == 8...9)
    }

    @Test func theSnippetAtTheEndOfTheFile() {
        let file = ["one", "two", "three"]
        #expect(CommentAnchor.relocate(snippet: ["two", "three"], start: 2, in: file) == 2...3)
        #expect(CommentAnchor.relocate(snippet: ["two", "three"], start: 2, in: ["zero"] + file) == 3...4)
        // The file lost its last line.
        #expect(CommentAnchor.relocate(snippet: ["two", "three"], start: 2, in: ["one", "two"]) == nil)
        #expect(CommentAnchor.relocate(snippet: ["two", "three"], start: 2, in: []) == nil)
    }

    // MARK: reanchor

    /// Only pending and sent comments of the new side move; one whose file cannot be read stays as it is, and one whose
    /// file is gone turns outdated with its last lines.
    @Test func reanchorMovesNewSideCommentsAndOutdatesTheOnesThatLostTheirLines() {
        let shifted = Self.comment("shifted", lines: 3...5, snippet: Self.snippet)
        let sent = Self.comment("sent", lines: 1...1, snippet: ["import a"], state: .sent)
        let edited = Self.comment("edited", path: "b.ts", lines: 1...1, snippet: ["let x = 1"])
        let gone = Self.comment("gone", path: "c.ts", lines: 2...2, snippet: ["x"])
        let removedSide = Self.comment("removed", side: .old, lines: 3...3, snippet: ["old line"])
        let outdated = Self.comment("outdated", lines: 1...1, snippet: ["nope"], state: .outdated)
        let unread = Self.comment("unread", path: "big.bin", lines: 1...1, snippet: ["x"])
        let files: [String: [String]] = ["a.ts": ["// new"] + Self.file, "b.ts": ["let x = 2"], "c.ts": []]

        let changed = CommentAnchor.reanchor([shifted, sent, edited, gone, removedSide, outdated, unread]) { files[$0] }

        var movedShifted = shifted
        movedShifted.startLine = 4
        movedShifted.endLine = 6
        var movedSent = sent
        movedSent.startLine = 2
        movedSent.endLine = 2
        var outdatedEdit = edited
        outdatedEdit.state = .outdated
        var outdatedGone = gone
        outdatedGone.state = .outdated
        #expect(changed == [movedShifted, movedSent, outdatedEdit, outdatedGone])
    }

    @Test func reanchorReadsEachFileOnce() {
        var reads: [String] = []
        let comments = [
            Self.comment("one", lines: 1...1, snippet: ["import a"]),
            Self.comment("two", lines: 3...5, snippet: Self.snippet),
        ]
        let changed = CommentAnchor.reanchor(comments) { path in
            reads.append(path)
            return Self.file
        }
        #expect(changed.isEmpty)
        #expect(reads == ["a.ts"])
    }

    // MARK: capture

    @Test func captureKeepsTheLinesAndThreeAroundThem() {
        let lines = (1...10).map { "n\($0)" }
        #expect(CommentAnchor.capture(4...5, side: .new, rows: [], newLines: lines) == CommentAnchor.Capture(
            snippet: ["n4", "n5"],
            contextBefore: ["n1", "n2", "n3"],
            contextAfter: ["n6", "n7", "n8"]
        ))
        let edges = CommentAnchor.capture(1...10, side: .new, rows: [], newLines: lines)
        #expect(edges.snippet == lines)
        #expect(edges.contextBefore.isEmpty)
        #expect(edges.contextAfter.isEmpty)
    }

    /// The old side, and the new side of a file not read (an added file is all rows), take their text from the rows.
    @Test func captureReadsTheRowsOfTheOldSide() {
        let rows = Self.rows
        #expect(CommentAnchor.capture(2...2, side: .old, rows: rows, newLines: nil) == CommentAnchor.Capture(
            snippet: ["gone"],
            contextBefore: ["keep"],
            contextAfter: ["end"]
        ))
        #expect(CommentAnchor.capture(2...2, side: .new, rows: rows, newLines: nil) == CommentAnchor.Capture(
            snippet: ["came"],
            contextBefore: ["keep"],
            contextAfter: ["end"]
        ))
    }

    // MARK: placement

    /// Line 1 unchanged, line 2 replaced ("gone" → "came"), line 3 unchanged.
    private static let rows: [DiffRow] = [
        .hunk(index: 0, header: "@@ -1,3 +1,3 @@"),
        .line(DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "keep")),
        .line(DiffLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "gone")),
        .line(DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "came")),
        .line(DiffLine(kind: .context, oldNumber: 3, newNumber: 3, text: "end")),
    ]

    @Test func aCommentSitsUnderTheRowOfItsLastLineOnItsSide() {
        let range = Self.comment("range", lines: 1...2, snippet: ["keep", "came"])
        let removed = Self.comment("removed", side: .old, lines: 2...2, snippet: ["gone"])
        // An old-side comment whose removed line is back: under that line's context row.
        let restored = Self.comment("restored", side: .old, lines: 3...3, snippet: ["end"])
        let outdated = Self.comment("outdated", lines: 1...1, snippet: ["nope"], state: .outdated)
        let beyond = Self.comment("beyond", lines: 9...9, snippet: ["x"], state: .sent)

        let placement = CommentAnchor.placement(
            of: [range, removed, restored, outdated, beyond],
            draft: CommentLine(side: .new, number: 1),
            in: Self.rows
        )

        #expect(placement.underRows == ["l0:2": [range], "l2:0": [removed], "l3:3": [restored]])
        #expect(placement.outdated == [outdated])
        #expect(placement.unplaced == [beyond])
        #expect(placement.draftRowId == "l1:1")
        #expect(CommentAnchor.placement(of: [], draft: CommentLine(side: .old, number: 9), in: Self.rows).draftRowId == nil)
    }

    @Test func aRowsCommentLineIsItsSidesNumber() {
        #expect(DiffLine(kind: .removed, oldNumber: 4, newNumber: nil, text: "").commentLine == CommentLine(side: .old, number: 4))
        #expect(DiffLine(kind: .added, oldNumber: nil, newNumber: 7, text: "").commentLine == CommentLine(side: .new, number: 7))
        #expect(DiffLine(kind: .context, oldNumber: 4, newNumber: 7, text: "").commentLine == CommentLine(side: .new, number: 7))
    }
}
