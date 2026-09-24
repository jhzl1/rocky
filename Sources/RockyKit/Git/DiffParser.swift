import Foundation

/// One line of a hunk (`GIT-02`): a context line has both numbers, an added line only the new one, a removed line only
/// the old one. `text` is the line without its marker and without its newline; a CRLF file's lines keep their `\r`.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case context, added, removed
    }

    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String

    public init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

/// `\ No newline at end of file` under a hunk's last old-side line, its last new-side line, or both (a context line).
public struct NoNewlineAtEnd: Equatable, Sendable {
    public var old: Bool
    public var new: Bool

    public init(old: Bool = false, new: Bool = false) {
        self.old = old
        self.new = new
    }
}

/// One `@@ -oldStart,oldCount +newStart,newCount @@` block and its lines.
public struct Hunk: Equatable, Sendable {
    /// The whole `@@` line, with the function context git adds after it.
    public let header: String
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public var lines: [DiffLine]
    public var noNewlineAtEnd: NoNewlineAtEnd

    public init(
        header: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [DiffLine] = [],
        noNewlineAtEnd: NoNewlineAtEnd = NoNewlineAtEnd()
    ) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
        self.noNewlineAtEnd = noNewlineAtEnd
    }
}

/// `old mode` and `new mode` as git prints them, for example "100644" and "100755" (`DIFF-03`'s mode-only case).
public struct ModeChange: Equatable, Sendable {
    public let old: String
    public let new: String

    public init(old: String, new: String) {
        self.old = old
        self.new = new
    }
}

/// One file of a workspace's changes (`GIT-01`, `GIT-02`).
public struct FileDiff: Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable {
        case added, modified, deleted
        case renamed(from: String)

        /// `CHG-03`'s status letter: A, M, D or R.
        public var letter: String {
            switch self {
            case .added: "A"
            case .modified: "M"
            case .deleted: "D"
            case .renamed: "R"
            }
        }
    }

    /// `DIFF-03`'s large diff: over 1,500 changed lines, or a patch (an untracked file) over 1 MB.
    public static let largeLineCount = 1_500
    public static let largeByteCount = 1_000_000

    /// The worktree-relative path, the new one for a rename.
    public var path: String
    public var status: Status
    public var isBinary: Bool
    public var modeChange: ModeChange?
    public var hunks: [Hunk]
    public var additions: Int
    public var deletions: Int
    /// The file has changes not committed yet: staged, unstaged or untracked. A file with committed changes and
    /// uncommitted ones is uncommitted (`CHG-03`).
    public var isUncommitted: Bool
    /// Not in the index: `GIT-05` sends it to the Trash rather than restoring it.
    public var isUntracked: Bool
    public var isLarge: Bool

    public var id: String { path }

    /// The path before a rename; nil otherwise.
    public var oldPath: String? {
        if case .renamed(let from) = status { return from }
        return nil
    }

    public init(
        path: String,
        status: Status,
        isBinary: Bool = false,
        modeChange: ModeChange? = nil,
        hunks: [Hunk] = [],
        additions: Int = 0,
        deletions: Int = 0,
        isUncommitted: Bool = false,
        isUntracked: Bool = false,
        isLarge: Bool = false
    ) {
        self.path = path
        self.status = status
        self.isBinary = isBinary
        self.modeChange = modeChange
        self.hunks = hunks
        self.additions = additions
        self.deletions = deletions
        self.isUncommitted = isUncommitted
        self.isUntracked = isUntracked
        self.isLarge = isLarge
    }
}

/// Added and removed lines: a workspace's in the sidebar (`GIT-03`), a file's in the Changes tab (`CHG-03`). `files`
/// is the number of changed files, the count on the Changes pill (`CHG-01`), known even while the tab is hidden.
public struct DiffStat: Equatable, Sendable {
    public var additions: Int
    public var deletions: Int
    public var files: Int

    public init(additions: Int = 0, deletions: Int = 0, files: Int = 0) {
        self.additions = additions
        self.deletions = deletions
        self.files = files
    }

    public var isEmpty: Bool { additions == 0 && deletions == 0 }

    /// `GIT-03`'s numbers: thousands as "2.3k", "12k" for 12,000.
    public static func abbreviated(_ count: Int) -> String {
        guard count >= 1_000 else { return String(count) }
        let thousands = String(format: "%.1f", Double(count) / 1_000)
        return (thousands.hasSuffix(".0") ? String(thousands.dropLast(2)) : thousands) + "k"
    }
}

/// What a workspace changed against its base (`GIT-01`): committed, staged, unstaged and untracked, one entry per file.
public struct WorkspaceChanges: Equatable, Sendable {
    /// The merge-base commit the diff is against.
    public var base: String
    /// In path order.
    public var files: [FileDiff]
    public var additions: Int
    public var deletions: Int

    public init(base: String, files: [FileDiff]) {
        self.base = base
        self.files = files
        self.additions = files.reduce(0) { $0 + $1.additions }
        self.deletions = files.reduce(0) { $0 + $1.deletions }
    }

    public var stat: DiffStat { DiffStat(additions: additions, deletions: deletions, files: files.count) }

    /// `CHG-03`'s sections: files with uncommitted changes, then files changed only by commits of the branch.
    public var uncommitted: [FileDiff] { files.filter(\.isUncommitted) }
    public var committed: [FileDiff] { files.filter { !$0.isUncommitted } }

    /// The files in the Changes tab's order, Uncommitted first: the order ⌥⌘↓ / ⌥⌘↑ walk (`CHG-03`).
    public var listOrder: [FileDiff] { uncommitted + committed }

    public func file(at path: String) -> FileDiff? {
        files.first { $0.path == path }
    }

    /// The file `step` places after `path` in `listOrder` (-1: before). From no file, or one no longer listed, ↓ goes
    /// to the first file and ↑ to the last. nil at either end and with no files.
    public func file(after path: String?, step: Int) -> FileDiff? {
        let order = listOrder
        guard !order.isEmpty else { return nil }
        guard let path, let index = order.firstIndex(where: { $0.path == path }) else {
            return step >= 0 ? order.first : order.last
        }
        let next = index + step
        return order.indices.contains(next) ? order[next] : nil
    }
}

/// `GIT-02`: the patch of `git diff --no-color --no-ext-diff --find-renames` into one `FileDiff` per file. Pure: the
/// uncommitted flag comes from `GitChangesService`, which knows the worktree's status.
public enum DiffParser {
    public static func parse(_ output: String) -> [FileDiff] {
        let lines = Self.lines(of: output)
        var files: [FileDiff] = []
        var file: FileBuilder?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git ") {
                if let finished = file?.finish() { files.append(finished) }
                file = FileBuilder(header: line)
                index += 1
                continue
            }
            guard file != nil else {
                index += 1
                continue
            }
            if let range = HunkRange(line) {
                index = file!.readHunk(range, header: line, lines: lines, from: index + 1)
                continue
            }
            file!.readHeaderLine(line)
            index += 1
        }
        if let finished = file?.finish() { files.append(finished) }
        return files
    }

    /// Split on the newline byte, not on `Character`: Swift reads "\r\n" as one character, so a CRLF file would stay
    /// one line. A final newline leaves no empty last line.
    static func lines(of output: String) -> [String] {
        var lines = output.utf8
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// A path as git prints it: C-quoted with `\"`, `\\`, `\t`, `\n` and octal bytes when it holds unusual
    /// characters, as is otherwise.
    static func unquote(_ text: Substring) -> String {
        guard text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 else { return String(text) }
        let bytes = Array(text.utf8.dropFirst().dropLast())
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < bytes.count else {
                result.append(byte)
                index += 1
                continue
            }
            let next = bytes[index + 1]
            switch next {
            case UInt8(ascii: "n"): result.append(0x0A)
            case UInt8(ascii: "t"): result.append(0x09)
            case UInt8(ascii: "r"): result.append(0x0D)
            case UInt8(ascii: "a"): result.append(0x07)
            case UInt8(ascii: "b"): result.append(0x08)
            case UInt8(ascii: "f"): result.append(0x0C)
            case UInt8(ascii: "v"): result.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Up to three octal digits: one byte of a UTF-8 sequence.
                var value = 0
                var digits = 0
                while digits < 3, index + 1 + digits < bytes.count,
                      (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(bytes[index + 1 + digits]) {
                    value = value * 8 + Int(bytes[index + 1 + digits] - UInt8(ascii: "0"))
                    digits += 1
                }
                result.append(UInt8(truncatingIfNeeded: value))
                index += 1 + digits
                continue
            default: result.append(next)
            }
            index += 2
        }
        return String(decoding: result, as: UTF8.self)
    }
}

/// `@@ -oldStart[,oldCount] +newStart[,newCount] @@`; a missing count is 1.
private struct HunkRange {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int

    init?(_ line: String) {
        guard line.hasPrefix("@@ -") else { return nil }
        let rest = line.dropFirst(4)
        guard let end = rest.range(of: " @@") else { return nil }
        let sides = rest[..<end.lowerBound].split(separator: " ")
        guard sides.count == 2, sides[1].hasPrefix("+"),
              let old = Self.side(sides[0]), let new = Self.side(sides[1].dropFirst()) else { return nil }
        (oldStart, oldCount) = old
        (newStart, newCount) = new
    }

    private static func side(_ text: Substring) -> (start: Int, count: Int)? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
        if parts.count == 1 { return (start, 1) }
        guard parts.count == 2, let count = Int(parts[1]) else { return nil }
        return (start, count)
    }
}

/// One file's section of the patch while it is read.
private struct FileBuilder {
    let header: String
    var isNew = false
    var isDeleted = false
    var isBinary = false
    var oldMode: String?
    var newMode: String?
    var renameFrom: String?
    var renameTo: String?
    /// From `---` and `+++`; nil for `/dev/null`.
    var minusPath: String?
    var plusPath: String?
    var hunks: [Hunk] = []
    /// The section's size in the patch, for `DIFF-03`'s 1 MB.
    var bytes: Int

    init(header: String) {
        self.header = header
        self.bytes = header.utf8.count + 1
    }

    mutating func readHeaderLine(_ line: String) {
        bytes += line.utf8.count + 1
        if let mode = Self.rest(of: line, after: "new file mode ") {
            isNew = true
            newMode = String(mode)
        } else if let mode = Self.rest(of: line, after: "deleted file mode ") {
            isDeleted = true
            oldMode = String(mode)
        } else if let mode = Self.rest(of: line, after: "old mode ") {
            oldMode = String(mode)
        } else if let mode = Self.rest(of: line, after: "new mode ") {
            newMode = String(mode)
        } else if let name = Self.rest(of: line, after: "rename from ") {
            renameFrom = DiffParser.unquote(name)
        } else if let name = Self.rest(of: line, after: "rename to ") {
            renameTo = DiffParser.unquote(name)
        } else if let name = Self.rest(of: line, after: "--- ") {
            minusPath = Self.patchPath(name, prefix: "a/")
        } else if let name = Self.rest(of: line, after: "+++ ") {
            plusPath = Self.patchPath(name, prefix: "b/")
        } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
            isBinary = true
        }
    }

    /// What follows an ASCII `prefix`, cut by bytes: cut by `Character`, a path starting with a combining mark would
    /// lose it together with the prefix's last space.
    private static func rest(of line: String, after prefix: String) -> Substring? {
        guard line.hasPrefix(prefix) else { return nil }
        return Substring(String(decoding: line.utf8.dropFirst(prefix.utf8.count), as: UTF8.self))
    }

    /// Reads a hunk's lines by its counts, so a context line that lost its leading space still counts, and returns the
    /// index of the first line after it.
    mutating func readHunk(_ range: HunkRange, header: String, lines: [String], from start: Int) -> Int {
        bytes += header.utf8.count + 1
        var hunk = Hunk(header: header, oldStart: range.oldStart, oldCount: range.oldCount, newStart: range.newStart, newCount: range.newCount)
        var oldLeft = range.oldCount
        var newLeft = range.newCount
        var oldNumber = range.oldStart
        var newNumber = range.newStart
        var index = start
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("\\") {
                // "\ No newline at end of file" belongs to the line before it.
                switch hunk.lines.last?.kind {
                case .removed: hunk.noNewlineAtEnd.old = true
                case .added: hunk.noNewlineAtEnd.new = true
                case .context:
                    hunk.noNewlineAtEnd.old = true
                    hunk.noNewlineAtEnd.new = true
                case nil: break
                }
                bytes += line.utf8.count + 1
                index += 1
                continue
            }
            guard oldLeft > 0 || newLeft > 0 else { break }
            let marker = line.utf8.first
            // The marker is one ASCII byte; cutting by `Character` would take a leading combining mark with it.
            let text = String(decoding: line.utf8.dropFirst(), as: UTF8.self)
            if marker == UInt8(ascii: "+"), newLeft > 0 {
                hunk.lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNumber, text: text))
                newNumber += 1
                newLeft -= 1
            } else if marker == UInt8(ascii: "-"), oldLeft > 0 {
                hunk.lines.append(DiffLine(kind: .removed, oldNumber: oldNumber, newNumber: nil, text: text))
                oldNumber += 1
                oldLeft -= 1
            } else if marker == nil || marker == UInt8(ascii: " "), oldLeft > 0, newLeft > 0 {
                hunk.lines.append(DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: text))
                oldNumber += 1
                newNumber += 1
                oldLeft -= 1
                newLeft -= 1
            } else {
                // Not a line of this hunk: the patch is cut short or malformed. Keep what was read.
                break
            }
            bytes += line.utf8.count + 1
            index += 1
        }
        hunks.append(hunk)
        return index
    }

    func finish() -> FileDiff {
        let fromHeader = Self.headerPaths(header)
        let newPath = renameTo ?? plusPath ?? fromHeader?.new
        let oldPath = renameFrom ?? minusPath ?? fromHeader?.old
        let status: FileDiff.Status
        if isNew {
            status = .added
        } else if isDeleted {
            status = .deleted
        } else if let renameFrom {
            status = .renamed(from: renameFrom)
        } else {
            status = .modified
        }
        let path = (isDeleted ? oldPath : newPath) ?? newPath ?? oldPath ?? ""
        var additions = 0
        var deletions = 0
        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .added: additions += 1
                case .removed: deletions += 1
                case .context: break
                }
            }
        }
        var modeChange: ModeChange?
        if !isNew, !isDeleted, let oldMode, let newMode, oldMode != newMode {
            modeChange = ModeChange(old: oldMode, new: newMode)
        }
        return FileDiff(
            path: path,
            status: status,
            isBinary: isBinary,
            modeChange: modeChange,
            hunks: hunks,
            additions: additions,
            deletions: deletions,
            isLarge: additions + deletions > FileDiff.largeLineCount || bytes > FileDiff.largeByteCount
        )
    }

    /// `--- a/path` or `+++ b/path`: nil for `/dev/null`. git ends a name holding a space with a tab.
    private static func patchPath(_ text: Substring, prefix: String) -> String? {
        var name = text
        if name.hasSuffix("\t") { name = name.dropLast() }
        guard name != "/dev/null" else { return nil }
        let path = DiffParser.unquote(name)
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// `diff --git a/old b/new`, which is all a binary or mode-only change has. Unquoted names are split where the two
    /// halves are the same path, since a name can hold " b/".
    private static func headerPaths(_ header: String) -> (old: String, new: String)? {
        let names = header.dropFirst("diff --git ".count)
        if names.hasPrefix("\"") {
            // Quoted: "a/…" "b/…", or one of the two quoted.
            guard let close = Self.closingQuote(in: names) else { return nil }
            let old = DiffParser.unquote(names[...close])
            let new = DiffParser.unquote(names[names.index(after: close)...].drop { $0 == " " })
            return (Self.dropPrefix(old, "a/"), Self.dropPrefix(new, "b/"))
        }
        let bytes = Array(names.utf8)
        if bytes.count > 5, (bytes.count - 5) % 2 == 0 {
            let half = (bytes.count - 5) / 2
            let old = bytes[2..<(2 + half)]
            let separator = bytes[(2 + half)..<(5 + half)]
            let new = bytes[(5 + half)...]
            if Array(old) == Array(new), Array(separator) == Array(" b/".utf8) {
                let path = String(decoding: old, as: UTF8.self)
                return (path, path)
            }
        }
        if let separator = names.range(of: " b/") {
            let old = String(names[..<separator.lowerBound])
            let new = String(names[separator.upperBound...])
            return (Self.dropPrefix(old, "a/"), new)
        }
        return nil
    }

    private static func closingQuote(in text: Substring) -> Substring.Index? {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if text[index] == "\"" { return index }
            index = text.index(after: index)
        }
        return nil
    }

    private static func dropPrefix(_ path: String, _ prefix: String) -> String {
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
