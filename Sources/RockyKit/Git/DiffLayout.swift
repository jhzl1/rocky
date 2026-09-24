import Foundation

/// An unchanged run of a diff tab (`DIFF-02`): the lines before hunk `hunkIndex`, or, when `hunkIndex` is the file's
/// hunk count, the lines after its last hunk. Collapsed to one row until it is expanded.
public struct DiffGap: Hashable, Sendable {
    public let hunkIndex: Int

    public init(hunkIndex: Int) {
        self.hunkIndex = hunkIndex
    }
}

/// One row of a diff tab's unified diff (`DIFF-02`), in the order it is drawn.
public enum DiffRow: Equatable, Sendable, Identifiable {
    /// A hunk's whole `@@` line.
    case hunk(index: Int, header: String)
    /// A line of a hunk, or of an expanded unchanged run (a context line).
    case line(DiffLine)
    /// A collapsed unchanged run of `count` lines.
    case gap(DiffGap, count: Int)

    /// Unique within a file: new numbers never repeat among the lines that have one, nor old numbers among theirs.
    public var id: String {
        switch self {
        case .hunk(let index, _): "h\(index)"
        case .line(let line): "l\(line.oldNumber ?? 0):\(line.newNumber ?? 0)"
        case .gap(let gap, _): "g\(gap.hunkIndex)"
        }
    }

    /// The id of the first hunk's header row, where `DIFF-05` scrolls a diff opened from a badge.
    public static let firstHunkId = "h0"
}

extension FileDiff {
    /// `DIFF-03`: a deleted or binary file has no Edit mode.
    public var isEditable: Bool {
        status != .deleted && !isBinary
    }

    /// `DIFF-03`'s "Large diff · 3,214 lines": the changed lines.
    public var changedLineCount: Int {
        additions + deletions
    }
}

/// Lays a `FileDiff` out as the rows of its diff tab (`DIFF-02`, `DIFF-03`). Pure, so the unchanged runs, whose
/// lines git leaves out of the patch, are counted and numbered in tests.
public enum DiffLayout {
    /// Worktree files larger than this are not read for their unchanged runs: they would be read on every refresh.
    public static let maxReadBytes = 20_000_000

    /// The rows of `file`: before each hunk the unchanged run since the previous one, then its header and its lines,
    /// then the run after the last hunk. A run is one gap row unless `expanded` holds it.
    ///
    /// `newLines` is the worktree file, which is the diff's new side (`git diff <base>` compares the base with the
    /// worktree), split like the patch; nil while it is not read. Without it the runs between hunks still show their
    /// count, an expanded run stays a gap row, and the run after the last hunk, whose length only the file knows, is
    /// left out. An untracked file over 1 MB has no hunks (Task 1): with its lines, every line is an added row.
    public static func rows(for file: FileDiff, newLines: [String]?, expanded: Set<DiffGap>) -> [DiffRow] {
        if file.hunks.isEmpty {
            guard file.status == .added, !file.isBinary, let newLines else { return [] }
            return newLines.enumerated().map { .line(DiffLine(kind: .added, oldNumber: nil, newNumber: $0.offset + 1, text: $0.element)) }
        }
        var rows: [DiffRow] = []
        rows.reserveCapacity(file.hunks.reduce(0) { $0 + $1.lines.count + 2 })
        // The first new-side and old-side lines no row shows yet.
        var nextNew = 1
        var nextOld = 1
        for (index, hunk) in file.hunks.enumerated() {
            let newStart = Self.start(hunk.newStart, count: hunk.newCount)
            let oldStart = Self.start(hunk.oldStart, count: hunk.oldCount)
            let count = newStart - nextNew
            if count > 0 {
                // The run ends right above the hunk on both sides, so its old numbers count back from the hunk's.
                appendRun(DiffGap(hunkIndex: index), newFrom: nextNew, oldFrom: oldStart - count, count: count, newLines: newLines, expanded: expanded, to: &rows)
            }
            rows.append(.hunk(index: index, header: hunk.header))
            rows.append(contentsOf: hunk.lines.map(DiffRow.line))
            nextNew = newStart + hunk.newCount
            nextOld = oldStart + hunk.oldCount
        }
        if let newLines {
            let count = newLines.count - nextNew + 1
            if count > 0 {
                appendRun(DiffGap(hunkIndex: file.hunks.count), newFrom: nextNew, oldFrom: nextOld, count: count, newLines: newLines, expanded: expanded, to: &rows)
            }
        }
        return rows
    }

    /// Where a side of a hunk starts. An empty side (`+0,0` of a deleted file, `-5,0` of lines inserted after line 5)
    /// names the line before it.
    static func start(_ start: Int, count: Int) -> Int {
        count == 0 ? start + 1 : start
    }

    private static func appendRun(
        _ gap: DiffGap,
        newFrom: Int,
        oldFrom: Int,
        count: Int,
        newLines: [String]?,
        expanded: Set<DiffGap>,
        to rows: inout [DiffRow]
    ) {
        guard expanded.contains(gap), let newLines else {
            rows.append(.gap(gap, count: count))
            return
        }
        for offset in 0..<count {
            let newNumber = newFrom + offset
            // A file read after the diff can be shorter than the diff says: show what it has.
            guard newNumber >= 1, newNumber <= newLines.count else { break }
            rows.append(.line(DiffLine(kind: .context, oldNumber: oldFrom + offset, newNumber: newNumber, text: newLines[newNumber - 1])))
        }
    }

    /// The unchanged runs of `file` that hold any of `lines`, so a comment on a line that is not near a change any more
    /// is drawn with its run open (`CMT-02`). The new side counts runs as `rows` does; the old side numbers each run
    /// back from the hunk after it. The run after the last hunk needs the file's line count.
    public static func gaps(holding lines: Set<CommentLine>, in file: FileDiff, lineCount: Int?) -> Set<DiffGap> {
        guard !lines.isEmpty, !file.hunks.isEmpty else { return [] }
        var gaps: Set<DiffGap> = []
        func check(_ gap: DiffGap, newFrom: Int, oldFrom: Int, count: Int) {
            let holds = lines.contains { line in
                let from = line.side == .new ? newFrom : oldFrom
                return line.number >= from && line.number < from + count
            }
            if holds { gaps.insert(gap) }
        }
        var nextNew = 1
        var nextOld = 1
        for (index, hunk) in file.hunks.enumerated() {
            let newStart = Self.start(hunk.newStart, count: hunk.newCount)
            let oldStart = Self.start(hunk.oldStart, count: hunk.oldCount)
            let count = newStart - nextNew
            if count > 0 {
                check(DiffGap(hunkIndex: index), newFrom: nextNew, oldFrom: oldStart - count, count: count)
            }
            nextNew = newStart + hunk.newCount
            nextOld = oldStart + hunk.oldCount
        }
        if let lineCount, lineCount - nextNew + 1 > 0 {
            check(DiffGap(hunkIndex: file.hunks.count), newFrom: nextNew, oldFrom: nextOld, count: lineCount - nextNew + 1)
        }
        return gaps
    }

    /// Whether the diff tab needs the worktree file: a changed file with hunks has unchanged runs to count and expand
    /// (added and deleted files are one hunk), and an untracked file over 1 MB has no hunks until it is read.
    public static func needsNewLines(_ file: FileDiff) -> Bool {
        guard !file.isBinary, file.status != .deleted else { return false }
        if file.hunks.isEmpty { return file.status == .added && file.isLarge }
        return file.status != .added
    }

    /// The worktree file's lines, split as the patch splits them (a CRLF file's lines keep their `\r`); nil when it
    /// cannot be read, is over `maxReadBytes`, or is binary. Blocking: callers use `Task.blocking`.
    public static func readLines(of file: URL) -> [String]? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
              size <= maxReadBytes,
              let data = try? Data(contentsOf: file, options: .alwaysMapped),
              !GitChangesService.isBinary(data) else { return nil }
        return DiffParser.lines(of: String(decoding: data, as: UTF8.self))
    }
}
