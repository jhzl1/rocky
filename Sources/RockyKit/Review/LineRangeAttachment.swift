import Foundation

/// A comment's lines as a chat attachment (`CMT-05`, `CMT-06`): the file's absolute path and a fragment,
/// `/…/tokyo/src/openapi.ts#L18-25`, or `…#base-L12-13` for removed lines; one line has no "-<end>". It is the one entry
/// of the message's `attachments`, which hold absolute paths, so the chip's click resolves it like a file badge.
/// Absolute rather than `CMT-05`'s worktree-relative example (the plan's decision, 2026-09-24).
public struct LineRangeAttachment: Hashable, Sendable {
    public let path: String
    public let side: CommentLine.Side
    /// 1-based and inclusive, numbered on `side`.
    public let start: Int
    public let end: Int

    public init(path: String, side: CommentLine.Side, start: Int, end: Int) {
        self.path = path
        self.side = side
        self.start = start
        self.end = end
    }

    /// The last `#L<a>[-<b>]` or `#base-L<a>[-<b>]` of `entry`. nil for a plain path, and for a fragment that is not
    /// one: no number, a zero, an end before its start, or anything after the numbers.
    public init?(entry: String) {
        guard let hash = entry.lastIndex(of: "#") else { return nil }
        let path = String(entry[..<hash])
        var fragment = entry[entry.index(after: hash)...]
        let side: CommentLine.Side
        if fragment.hasPrefix(Self.oldPrefix) {
            side = .old
            fragment = fragment.dropFirst(Self.oldPrefix.count)
        } else if fragment.hasPrefix(Self.newPrefix) {
            side = .new
            fragment = fragment.dropFirst(Self.newPrefix.count)
        } else {
            return nil
        }
        let bounds = fragment.split(separator: "-", omittingEmptySubsequences: false)
        guard !path.isEmpty, (1...2).contains(bounds.count), let start = Self.number(bounds[0]) else { return nil }
        let end = bounds.count == 2 ? Self.number(bounds[1]) : start
        guard let end, end >= start else { return nil }
        self.init(path: path, side: side, start: start, end: end)
    }

    private static let newPrefix = "L"
    private static let oldPrefix = "base-L"

    /// What the message stores: the path and its fragment.
    public var entry: String {
        let prefix = side == .old ? Self.oldPrefix : Self.newPrefix
        return path + "#" + prefix + (start == end ? "\(start)" : "\(start)-\(end)")
    }

    /// `CMT-06`'s range after the file's name: "+18–25" on the new side, "−12–13" on the removed side, "+18" for one
    /// line.
    public var rangeLabel: String {
        (side == .old ? "−" : "+") + (start == end ? "\(start)" : "\(start)–\(end)")
    }

    public var lastLine: CommentLine {
        CommentLine(side: side, number: end)
    }

    /// A line number of the fragment: ASCII digits only, at least 1.
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text), value >= 1 else { return nil }
        return value
    }
}

extension ChatItem {
    /// A user message that is a comment on a diff's lines (`CMT-05`): its first attachment is a `LineRangeAttachment`
    /// entry and no other one is, since a message holds one chip at most. The rest are files attached next to the chip
    /// in the message box (`CMT-05`'s Resend). The transcript draws the chip over the text, never a file badge
    /// (`CMT-06`), and the message box's ↑ history brings the chip back with the text (user decision, 2026-09-25).
    public var lineRange: LineRangeAttachment? {
        guard kind == .user, let first = attachments.first, let range = LineRangeAttachment(entry: first),
              !attachments.dropFirst().contains(where: { LineRangeAttachment(entry: $0) != nil }) else { return nil }
        return range
    }

    /// The files of a user message, a line comment's chip left out.
    public var attachedFiles: [String] {
        lineRange == nil ? attachments : Array(attachments.dropFirst())
    }
}
