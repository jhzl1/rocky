import Foundation

/// `AGT-03`'s failure logs: the last lines of each failed job's log, saved under
/// `Application Support/Rocky/ci-logs/<workspace id>/<check name>.log` (outside the worktree) and attached to the prompt.
/// Blocking file work: call it off the main actor.
public enum CILogs {
    /// How much of a job's log the agent gets.
    public static let lineLimit = 1000

    /// A file name made of the check's letters and digits: "e2e / chromium" → "e2e-chromium.log". Nothing in it can
    /// climb out of the folder or hide the file.
    public static func fileName(checkName: String) -> String {
        let words = checkName.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let stem = words.joined(separator: "-").prefix(100)
        return (stem.isEmpty ? "check" : String(stem)) + ".log"
    }

    /// The last `lines` lines of `file`, read backwards from its end in chunks, so a log of any size costs only its
    /// tail. A newline that ends the file ends its last line; it does not start another.
    public static func tail(of file: URL, lines: Int) throws -> String {
        guard lines > 0 else { return "" }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let chunkSize: UInt64 = 64 * 1024
        var data = Data()
        var offset = size
        var newlines = 0
        var endsWithNewline = false
        while offset > 0 {
            let length = min(chunkSize, offset)
            offset -= length
            try handle.seek(toOffset: offset)
            let chunk = try handle.read(upToCount: Int(length)) ?? Data()
            if data.isEmpty { endsWithNewline = chunk.last == newline }
            newlines += chunk.reduce(0) { $0 + ($1 == newline ? 1 : 0) }
            data = chunk + data
            if newlines - (endsWithNewline ? 1 : 0) >= lines { break }
        }
        var end = data.endIndex
        if endsWithNewline, end > data.startIndex { end = data.index(before: end) }
        var start = data.startIndex
        var seen = 0
        var index = end
        while index > data.startIndex {
            index = data.index(before: index)
            guard data[index] == newline else { continue }
            seen += 1
            if seen == lines {
                start = data.index(after: index)
                break
            }
        }
        return String(decoding: data[start..<data.endIndex], as: UTF8.self)
    }

    /// The workspace's log folder, emptied: the logs of an earlier Fix errors are deleted first.
    public static func freshFolder(for workspaceId: String, in root: URL) throws -> URL {
        let directory = folder(for: workspaceId, in: root)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Where a workspace's logs go; removing the workspace deletes it.
    public static func folder(for workspaceId: String, in root: URL) -> URL {
        root.appendingPathComponent(workspaceId, isDirectory: true)
    }

    /// Saves the last `lines` lines of `log` in `folder` under the check's file name. Two checks with one name get
    /// "name.log" and "name-2.log".
    public static func save(tailOf log: URL, checkName: String, in folder: URL, lines: Int = lineLimit) throws -> URL {
        let text = try tail(of: log, lines: lines)
        let name = fileName(checkName: checkName)
        let stem = String(name.dropLast(".log".count))
        var destination = folder.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(stem)-\(suffix).log")
            suffix += 1
        }
        try Data(text.utf8).write(to: destination)
        return destination
    }

    private static let newline = UInt8(ascii: "\n")
}
