import Foundation

/// A line a review comment can sit on (`CMT-01`): a side of the diff and the line's number on that side.
public struct CommentLine: Hashable, Sendable {
    public let side: DiffCommentRecord.Side
    public let number: Int

    public init(side: DiffCommentRecord.Side, number: Int) {
        self.side = side
        self.number = number
    }
}

extension DiffLine {
    /// Where a comment on this row goes: a removed row's old number, any other row's new number (`CMT-01`).
    public var commentLine: CommentLine? {
        if kind == .removed { return oldNumber.map { CommentLine(side: .old, number: $0) } }
        return newNumber.map { CommentLine(side: .new, number: $0) }
    }
}

/// Where a file's comments go in its diff tab (`CMT-02`, `CMT-04`).
public struct CommentPlacement: Equatable, Sendable {
    /// Pending and sent comments under the row of their last line, by `DiffRow.id`, oldest first.
    public var underRows: [String: [DiffCommentRecord]] = [:]
    /// The row the composer opens under, when it has one.
    public var draftRowId: String?
    /// Outdated comments, collapsed at the top of the diff.
    public var outdated: [DiffCommentRecord] = []
    /// Pending and sent comments whose last line has no row (the file changed since the diff was read), drawn at the
    /// top so none goes missing.
    public var unplaced: [DiffCommentRecord] = []

    public init() {}
}

/// Keeps review comments on their lines as the worktree file changes (`CMT-04`). Pure: the file's lines come in.
public enum CommentAnchor {
    /// How many lines above and below its snippet a comment keeps (`CMT-03`'s context).
    public static let contextLineCount = 3

    /// The text a new comment keeps of its side: the lines of `range`, and up to `contextLineCount` lines on each side.
    public struct Capture: Equatable, Sendable {
        public var snippet: [String]
        public var contextBefore: [String]
        public var contextAfter: [String]

        public init(snippet: [String], contextBefore: [String] = [], contextAfter: [String] = []) {
            self.snippet = snippet
            self.contextBefore = contextBefore
            self.contextAfter = contextAfter
        }
    }

    /// Where `snippet`, last seen at line `start` (1-based), is in `lines` now: at its own lines if they are unchanged,
    /// else at the match nearest them (the one above on a tie). nil when it is nowhere, or a commented line changed.
    public static func relocate(snippet: [String], start: Int, in lines: [String]) -> ClosedRange<Int>? {
        let count = snippet.count
        guard count > 0, lines.count >= count else { return nil }
        let original = start - 1
        func matches(at index: Int) -> Bool {
            guard index >= 0, index + count <= lines.count else { return false }
            for offset in 0..<count where lines[index + offset] != snippet[offset] {
                return false
            }
            return true
        }
        if matches(at: original) { return start...(start + count - 1) }
        var best: Int?
        for index in 0...(lines.count - count) where lines[index] == snippet[0] && matches(at: index) {
            if let found = best, abs(index - original) >= abs(found - original) { continue }
            best = index
        }
        return best.map { ($0 + 1)...($0 + count) }
    }

    /// `CMT-04` after a change: each pending or sent comment on the new side moves to where `relocate` finds its snippet
    /// in its file, or turns outdated, keeping its text and last lines. Old-side comments are on the base, which does
    /// not change, and outdated ones stay outdated. `lines` gives a file's current lines by its worktree-relative path,
    /// an empty list for a file that is gone, or nil when it cannot tell, which leaves the file's comments as they are.
    /// Returns the comments that changed.
    public static func reanchor(_ comments: [DiffCommentRecord], lines: (String) -> [String]?) -> [DiffCommentRecord] {
        var files: [String: [String]?] = [:]
        var changed: [DiffCommentRecord] = []
        for comment in comments where comment.side == .new && comment.state != .outdated && !comment.snippet.isEmpty {
            let current: [String]?
            if let known = files[comment.path] {
                current = known
            } else {
                current = lines(comment.path)
                files[comment.path] = current
            }
            guard let current else { continue }
            var moved = comment
            if let range = relocate(snippet: comment.snippet, start: comment.startLine, in: current) {
                moved.startLine = range.lowerBound
                moved.endLine = range.upperBound
            } else {
                moved.state = .outdated
            }
            if moved != comment { changed.append(moved) }
        }
        return changed
    }

    /// The text a new comment on `range` of `side` keeps (`CMT-03`). The new side reads the worktree file when it is
    /// loaded (`newLines`), so a range across a collapsed run keeps every line; otherwise, and on the old side, it reads
    /// the rows' lines, and a line no row shows is left out.
    public static func capture(_ range: ClosedRange<Int>, side: DiffCommentRecord.Side, rows: [DiffRow], newLines: [String]?) -> Capture {
        let text: (Int) -> String?
        if side == .new, let newLines {
            text = { number in number >= 1 && number <= newLines.count ? newLines[number - 1] : nil }
        } else {
            var byNumber: [Int: String] = [:]
            for row in rows {
                guard case .line(let line) = row, let number = side == .new ? line.newNumber : line.oldNumber else { continue }
                if byNumber[number] == nil { byNumber[number] = line.text }
            }
            let found = byNumber
            text = { found[$0] }
        }
        let first = max(1, range.lowerBound - contextLineCount)
        let before = first..<max(first, range.lowerBound)
        let after = (range.upperBound + 1)...(range.upperBound + contextLineCount)
        return Capture(
            snippet: range.compactMap(text),
            contextBefore: before.compactMap(text),
            contextAfter: after.compactMap(text)
        )
    }

    /// Where `comments` of one file go among `rows` (`CMT-02`): each pending or sent one under the row of its last line
    /// on its side, and the composer under the row of `draft`. An old-side comment whose removed line came back sits
    /// under that line's context row.
    public static func placement(of comments: [DiffCommentRecord], draft: CommentLine? = nil, in rows: [DiffRow]) -> CommentPlacement {
        var rowIds: [CommentLine: String] = [:]
        var restored: [Int: String] = [:]
        for row in rows {
            guard case .line(let line) = row, let at = line.commentLine else { continue }
            if rowIds[at] == nil { rowIds[at] = row.id }
            if line.kind == .context, let old = line.oldNumber, restored[old] == nil { restored[old] = row.id }
        }
        func rowId(_ at: CommentLine) -> String? {
            rowIds[at] ?? (at.side == .old ? restored[at.number] : nil)
        }
        var placement = CommentPlacement()
        for comment in comments {
            if comment.state == .outdated {
                placement.outdated.append(comment)
            } else if let id = rowId(CommentLine(side: comment.side, number: comment.endLine)) {
                placement.underRows[id, default: []].append(comment)
            } else {
                placement.unplaced.append(comment)
            }
        }
        placement.draftRowId = draft.flatMap(rowId)
        return placement
    }
}
