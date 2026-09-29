import Foundation

/// KIT-17, Decision 8 of M2.9: reads a background task's output as it arrives, a line at a time with its ANSI escapes
/// removed, and says when a line matches the task's `beginsPattern` or `endsPattern` (TSK-05). Pure: the runner feeds it
/// the PTY's chunks, attached before the process starts so no line is missed.
///
/// A line is what ends in "\n" or "\r" (a progress line rewritten in place is a line each time). The part after the last
/// break is matched too, since a server may print "ready in 812 ms" and then wait without a newline; each line reports a
/// pattern once. The echo line Rocky prints first ("> command", TSK-03) is not the task's output, as VS Code's
/// "Executing task" line is not: a command that names its own pattern must not end its wait.
public struct TaskOutputWatcher {
    public enum Match: Equatable, Sendable {
        case begins, ends
    }

    private let begins: NSRegularExpression?
    private let ends: NSRegularExpression?
    private var pending: [UInt8] = []
    /// What the pending, unfinished line already reported.
    private var pendingMatches: [Match] = []
    /// The echo line, until the first line has come.
    private var ignoredFirstLine: String?

    /// A line longer than this keeps only its end: a process that never writes a newline must not grow the buffer.
    static let maxLineBytes = 64 * 1024

    /// Throws when a pattern is not a regular expression; `VSCodeTasks.plan` has already refused such a task (TSK-07).
    public init(beginsPattern: String?, endsPattern: String?, ignoringFirstLine firstLine: String? = nil) throws {
        begins = try beginsPattern.map { try NSRegularExpression(pattern: $0) }
        ends = try endsPattern.map { try NSRegularExpression(pattern: $0) }
        ignoredFirstLine = firstLine
    }

    /// The patterns this chunk's lines matched, in order.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [Match] {
        var matches: [Match] = []
        for byte in bytes {
            guard byte == 0x0A || byte == 0x0D else {
                pending.append(byte)
                continue
            }
            let line = Self.line(pending)
            pending.removeAll(keepingCapacity: true)
            if let ignored = ignoredFirstLine {
                ignoredFirstLine = nil
                if line == ignored { continue }
            }
            matches += lineMatches(line).filter { !pendingMatches.contains($0) }
            pendingMatches = []
        }
        if pending.count > Self.maxLineBytes {
            pending.removeFirst(pending.count - Self.maxLineBytes)
        }
        if !pending.isEmpty {
            let line = Self.line(pending)
            // Maybe the echo line, not whole yet: it is known once it ends.
            if let ignored = ignoredFirstLine, ignored.hasPrefix(line) { return matches }
            let found = lineMatches(line).filter { !pendingMatches.contains($0) }
            pendingMatches += found
            matches += found
        }
        return matches
    }

    private func lineMatches(_ line: String) -> [Match] {
        guard !line.isEmpty else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        var matches: [Match] = []
        if let begins, begins.firstMatch(in: line, range: range) != nil { matches.append(.begins) }
        if let ends, ends.firstMatch(in: line, range: range) != nil { matches.append(.ends) }
        return matches
    }

    private static func line(_ bytes: [UInt8]) -> String {
        stripANSI(String(decoding: bytes, as: UTF8.self))
    }

    /// The text without its terminal escapes: colors and cursor moves (CSI), titles and links (OSC), character sets,
    /// and the two-character ones.
    public static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacing(
            /\x{1B}\[[0-?]*[ -\/]*[@-~]|\x{1B}\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)?|\x{1B}[()*+].|\x{1B}[@-Z\\-_]/,
            with: ""
        )
    }
}
