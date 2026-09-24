import Foundation

/// `EDIT-01`'s Tab: the indentation a file already uses.
public enum Indentation {
    /// Lines read to decide: enough for any file's habit, and bounded for a large one.
    static let sampleLines = 5_000

    /// A tab when more indented lines start with one than with spaces; otherwise the most common step by which the
    /// spaces that start a line grow from one line to the next. nil when no line is indented. A step of one space (a
    /// block comment's " * ") counts only when there is no other.
    public static func detect(in text: String) -> String? {
        var tabbed = 0
        var spaced = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        for line in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).prefix(sampleLines) {
            var spaces = 0
            var startsWithTab = false
            var isBlank = true
            for byte in line {
                if byte == UInt8(ascii: " ") {
                    spaces += 1
                } else if byte == UInt8(ascii: "\t") {
                    if spaces == 0 { startsWithTab = true }
                    break
                } else {
                    isBlank = byte == UInt8(ascii: "\r")
                    break
                }
            }
            if isBlank && !startsWithTab { continue }
            if startsWithTab {
                tabbed += 1
                continue
            }
            if spaces > 0 { spaced += 1 }
            if spaces > previous, spaces - previous <= 8 { steps[spaces - previous, default: 0] += 1 }
            previous = spaces
        }
        if tabbed > spaced { return "\t" }
        guard spaced > 0 else { return nil }
        let wider = steps.filter { $0.key > 1 }
        let pool = wider.isEmpty ? steps : wider
        // The most common step; a tie goes to the narrower one.
        guard let step = pool.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key else { return nil }
        return String(repeating: " ", count: step)
    }
}

/// Where each line of a text starts, in UTF-16 offsets (`NSString`'s unit), for the editor's line numbers
/// (`EDIT-01`). "\r\n" is one line break and a lone "\r" is one too, as the text view lays them out.
public enum LineStarts {
    public static func of(_ units: [UInt16]) -> [Int] {
        var starts = [0]
        let newline = UInt16(UInt8(ascii: "\n"))
        let carriageReturn = UInt16(UInt8(ascii: "\r"))
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == newline {
                starts.append(index + 1)
            } else if unit == carriageReturn, index + 1 >= units.count || units[index + 1] != newline {
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }

    public static func of(_ text: String) -> [Int] {
        of(Array(text.utf16))
    }

    /// The 0-based line holding `offset`: the last start at or before it.
    public static func line(containing offset: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return max(low, 0)
    }
}

/// `EDIT-04`'s change bars: the editor's lines against the file at the base. An added line, a modified one (a line
/// that replaced removed ones), and where removed lines were, as the design's mock marks them.
public struct ChangeBars: Equatable, Sendable {
    public enum Mark: Equatable, Sendable {
        case added, modified
    }

    /// By the text's 0-based line.
    public var marks: [Int: Mark] = [:]
    /// Lines with base lines removed right above them: the small triangle at their top edge.
    public var deletionsAbove: Set<Int> = []
    /// Base lines removed after the text's last line.
    public var deletionAtEnd = false

    public init(marks: [Int: Mark] = [:], deletionsAbove: Set<Int> = [], deletionAtEnd: Bool = false) {
        self.marks = marks
        self.deletionsAbove = deletionsAbove
        self.deletionAtEnd = deletionAtEnd
    }

    /// Past this many lines between the common start and end of both texts, the lines between are all marked modified
    /// rather than diffed: a minimal diff of two long unrelated texts costs seconds and a lot of memory.
    static let diffLimit = 2_000

    /// The bars of `text` against `base`, both split on "\n" as the diff splits them (a final newline adds no line).
    public static func compute(base: String, text: String) -> ChangeBars {
        compute(base: DiffParser.lines(of: base), text: DiffParser.lines(of: text))
    }

    public static func compute(base: [String], text: [String]) -> ChangeBars {
        var bars = ChangeBars()
        // What both keep at their start and end is unchanged; only the middle is diffed.
        var prefix = 0
        while prefix < base.count, prefix < text.count, base[prefix] == text[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < base.count - prefix, suffix < text.count - prefix,
              base[base.count - 1 - suffix] == text[text.count - 1 - suffix] { suffix += 1 }
        let oldMiddle = Array(base[prefix..<(base.count - suffix)])
        let newMiddle = Array(text[prefix..<(text.count - suffix)])
        if oldMiddle.isEmpty && newMiddle.isEmpty { return bars }

        var pendingRemovals = 0
        let afterMiddle = prefix + newMiddle.count
        if oldMiddle.count + newMiddle.count > diffLimit {
            for line in prefix..<afterMiddle { bars.marks[line] = oldMiddle.isEmpty ? .added : .modified }
            pendingRemovals = newMiddle.isEmpty ? oldMiddle.count : 0
        } else {
            var removed = Set<Int>()
            var inserted = Set<Int>()
            for change in newMiddle.difference(from: oldMiddle) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            // Removed lines come before the lines inserted in their place, so an insertion right after a removal is a
            // modified line.
            var old = 0
            var new = 0
            while old < oldMiddle.count || new < newMiddle.count {
                if old < oldMiddle.count, removed.contains(old) {
                    pendingRemovals += 1
                    old += 1
                } else if new < newMiddle.count, inserted.contains(new) {
                    bars.marks[prefix + new] = pendingRemovals > 0 ? .modified : .added
                    if pendingRemovals > 0 { pendingRemovals -= 1 }
                    new += 1
                } else {
                    if pendingRemovals > 0 { bars.deletionsAbove.insert(prefix + new) }
                    pendingRemovals = 0
                    old += 1
                    new += 1
                }
            }
        }
        if pendingRemovals > 0 {
            if afterMiddle < text.count { bars.deletionsAbove.insert(afterMiddle) } else { bars.deletionAtEnd = true }
        }
        return bars
    }
}
