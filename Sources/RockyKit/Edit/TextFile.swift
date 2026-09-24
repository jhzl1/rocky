import Foundation

/// How a text file is written back (`EDIT-02`): its line endings and whether it starts with a UTF-8 byte order mark.
/// The editor works on "\n" lines; a save writes them the way the file had them, and never adds or drops a final
/// newline.
public struct TextFormat: Equatable, Sendable {
    public enum LineEnding: Equatable, Sendable {
        case lf, crlf
    }

    public var lineEnding: LineEnding
    public var hasByteOrderMark: Bool

    public init(lineEnding: LineEnding = .lf, hasByteOrderMark: Bool = false) {
        self.lineEnding = lineEnding
        self.hasByteOrderMark = hasByteOrderMark
    }

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    /// A file's bytes as the editor's text, and the format that writes that text back as the same bytes; nil when they
    /// are not UTF-8. A file whose every line ends in "\r\n" is CRLF and its text has "\n" alone. A file that mixes
    /// both keeps its "\r"s in the text, so each line is written back with the ending it had.
    public static func decode(_ data: Data) -> (text: String, format: TextFormat)? {
        let hasMark = data.starts(with: byteOrderMark)
        let body = hasMark ? Data(data.dropFirst(byteOrderMark.count)) : data
        guard var text = String(data: body, encoding: .utf8) else { return nil }
        let isCRLF = Self.isCRLF(body)
        if isCRLF {
            text = String(decoding: droppingCarriageReturns(body), as: UTF8.self)
        }
        return (text, TextFormat(lineEnding: isCRLF ? .crlf : .lf, hasByteOrderMark: hasMark))
    }

    /// The editor's text as the file's bytes: "\n" back to "\r\n" in a CRLF file (a "\r\n" already there stays one), and
    /// the byte order mark the file started with.
    public func encode(_ text: String) -> Data {
        var data = Data()
        data.reserveCapacity(text.utf8.count + (hasByteOrderMark ? 3 : 0))
        if hasByteOrderMark { data.append(contentsOf: Self.byteOrderMark) }
        guard lineEnding == .crlf else {
            data.append(contentsOf: text.utf8)
            return data
        }
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == Self.newline, previous != Self.carriageReturn { data.append(Self.carriageReturn) }
            data.append(byte)
            previous = byte
        }
        return data
    }

    /// Every newline is preceded by a carriage return, and there is at least one.
    private static func isCRLF(_ bytes: Data) -> Bool {
        var previous: UInt8 = 0
        var newlines = 0
        for byte in bytes {
            if byte == newline {
                guard previous == carriageReturn else { return false }
                newlines += 1
            }
            previous = byte
        }
        return newlines > 0
    }

    /// The bytes without each "\r" that comes right before a "\n".
    private static func droppingCarriageReturns(_ bytes: Data) -> Data {
        var result = Data()
        result.reserveCapacity(bytes.count)
        var pendingReturn = false
        for byte in bytes {
            if pendingReturn, byte != newline { result.append(carriageReturn) }
            pendingReturn = byte == carriageReturn
            if !pendingReturn { result.append(byte) }
        }
        if pendingReturn { result.append(carriageReturn) }
        return result
    }
}

/// Reading and writing the editor's files (`EDIT-01`…`EDIT-03`). Blocking: callers use `Task.blocking`.
public enum TextFile {
    /// Text up to this size opens editable (`EDIT-01`'s 2 MB rule); up to `readableLimit` it opens read-only. The limits
    /// are `FileContent`'s (`FIL-06`).
    public static let editableLimit = FileContent.editableLimit
    public static let readableLimit = FileContent.readableLimit
    /// A NUL byte in the first 8 KB makes a file binary (`FIL-06`).
    public static let sniffLength = FileContent.sniffLength

    /// A file as it is on disk now.
    public struct Snapshot: Equatable, Sendable {
        public let stamp: FileStamp
        /// In bytes; 0 for a missing file.
        public let size: Int
        /// nil when the file is missing, binary, not UTF-8, or over `readableLimit` (which is not read at all).
        public let text: String?
        public let format: TextFormat

        public init(stamp: FileStamp, size: Int, text: String?, format: TextFormat = TextFormat()) {
            self.stamp = stamp
            self.size = size
            self.text = text
            self.format = format
        }

        public var exists: Bool {
            stamp != .missing
        }

        static let missing = Snapshot(stamp: .missing, size: 0, text: nil)
    }

    /// The file a save writes for `url`: a symbolic link's target, so an atomic write never turns the link into a copy
    /// (`WorktreeLinker`'s `.env` links).
    public static func target(of url: URL) -> URL {
        url.resolvingSymlinksInPath()
    }

    /// The file's modification date, without reading it; nil when it is missing.
    public static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: target(of: url).path))?[.modificationDate] as? Date
    }

    /// Reads the file the way `FIL-06` says: its size from its attributes first, so a file over `readableLimit` is never
    /// read; then its first `sniffLength` bytes, and the rest only when they are not binary (`FileContent.classify`). A
    /// binary file's stamp hashes those first bytes, with its date. Text that is not UTF-8 has no text either. A folder
    /// counts as missing.
    public static func snapshot(of url: URL) -> Snapshot {
        let file = target(of: url)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType != .typeDirectory else { return .missing }
        let size = attributes[.size] as? Int ?? 0
        let date = attributes[.modificationDate] as? Date
        let unread = Snapshot(stamp: FileStamp(modificationDate: date, contentHash: nil), size: size, text: nil)
        guard size <= readableLimit, let handle = try? FileHandle(forReadingFrom: file) else { return unread }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: sniffLength) ?? Data() else { return unread }
        switch FileContent.classify(size: size, head: head) {
        case .binary, .tooLarge:
            return Snapshot(stamp: FileStamp(data: head, modificationDate: date), size: size, text: nil)
        case .text, .largeText:
            guard let rest = try? handle.readToEnd() ?? Data() else { return unread }
            let data = head + rest
            let stamp = FileStamp(data: data, modificationDate: date)
            // A file that grew past the limit, or turned binary, since its attributes were read.
            guard data.count <= readableLimit, !data.prefix(sniffLength).contains(0), let decoded = TextFormat.decode(data) else {
                return Snapshot(stamp: stamp, size: data.count, text: nil)
            }
            return Snapshot(stamp: stamp, size: data.count, text: decoded.text, format: decoded.format)
        }
    }

    /// Writes `data` over the file at `url` in one step (`EDIT-02`): at a link's target, keeping the file's permissions
    /// and extended attributes (`FileManager.replaceItemAt`), so a script stays executable. A file that is gone is
    /// created. Returns the file's new stamp.
    @discardableResult
    public static func write(_ data: Data, to url: URL) throws -> FileStamp {
        let file = target(of: url)
        let manager = FileManager.default
        if manager.fileExists(atPath: file.path) {
            let scratch = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: file, create: true)
            defer { try? manager.removeItem(at: scratch) }
            let staged = scratch.appendingPathComponent(file.lastPathComponent)
            try data.write(to: staged)
            _ = try manager.replaceItemAt(file, withItemAt: staged)
        } else {
            try data.write(to: file, options: .atomic)
        }
        let date = (try? manager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        return FileStamp(data: data, modificationDate: date)
    }
}
