import Foundation

/// What a file tab shows for a file (`FIL-06`), from its size and its first bytes, before anything else is read:
/// text up to 2 MB in the editor, text of 2–20 MB read-only, nothing loaded past 20 MB, and a card for binary files.
/// Images and PDFs are decided by their kind first (`FileKind` in RockyUI) and never reach this.
public enum FileContent: Equatable, Sendable {
    /// Up to `editableLimit`: the editor.
    case text
    /// Over `editableLimit`, up to `readableLimit`: the read-only editor, in plain text.
    case largeText
    /// Over `readableLimit`: not read at all.
    case tooLarge
    /// A NUL byte in the first `sniffLength` bytes.
    case binary

    public static let editableLimit = 2_000_000
    public static let readableLimit = 20_000_000
    public static let sniffLength = 8_192

    /// `size` comes from the file's attributes; `head` is its first bytes, up to `sniffLength` (more are ignored), and is
    /// not looked at for a file over `readableLimit`, which is never read.
    public static func classify(size: Int, head: Data) -> FileContent {
        if size > readableLimit { return .tooLarge }
        if head.prefix(sniffLength).contains(0) { return .binary }
        return size > editableLimit ? .largeText : .text
    }
}
