import Foundation

/// A line a comment can be on (`CMT-01`): a side of the diff and the line's number on that side.
public struct CommentLine: Hashable, Sendable {
    /// The worktree file's lines, which added and context rows show, or the base's, which removed rows show. A range
    /// never mixes them (`CMT-01`).
    public enum Side: String, Hashable, Sendable {
        case new, old
    }

    public let side: Side
    public let number: Int

    public init(side: Side, number: Int) {
        self.side = side
        self.number = number
    }
}

extension DiffLine {
    /// Where a comment on this row goes: a removed row's old number, any other row's new number (`CMT-01`), the one
    /// number `DIFF-02`'s column shows.
    public var commentLine: CommentLine? {
        if kind == .removed { return oldNumber.map { CommentLine(side: .old, number: $0) } }
        return newNumber.map { CommentLine(side: .new, number: $0) }
    }
}
