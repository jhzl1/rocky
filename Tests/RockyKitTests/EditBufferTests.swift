import Foundation
import Testing
@testable import RockyKit

/// `EDIT-02` and `EDIT-03`'s rules for a buffer against its file on disk (Review Focus 3: a save never overwrites a
/// version of the file the buffer has not seen, unless the user chose Keep Mine over it).
struct EditBufferTests {
    private let loadedStamp = FileStamp(data: Data("hello\n".utf8), modificationDate: Date(timeIntervalSince1970: 1))
    private let agentStamp = FileStamp(data: Data("hello agent\n".utf8), modificationDate: Date(timeIntervalSince1970: 2))
    private let laterStamp = FileStamp(data: Data("hello later\n".utf8), modificationDate: Date(timeIntervalSince1970: 3))

    private func loaded() -> EditBuffer {
        EditBuffer(text: "hello\n", stamp: loadedStamp)
    }

    /// A buffer with unsaved edits whose file the agent changed.
    private func conflicted() -> EditBuffer {
        var buffer = loaded()
        buffer.text = "hello mine\n"
        _ = buffer.diskChanged(to: "hello agent\n", stamp: agentStamp)
        return buffer
    }

    @Test func aCleanBufferReloads() {
        var buffer = loaded()
        #expect(buffer.diskChanged(to: "hello agent\n", stamp: agentStamp) == .reloaded)
        #expect(buffer.text == "hello agent\n")
        #expect(buffer.loaded == "hello agent\n")
        #expect(buffer.loadedStamp == agentStamp)
        #expect(!buffer.isDirty)
        #expect(!buffer.conflict)
    }

    @Test func aDirtyBufferConflicts() {
        var buffer = loaded()
        buffer.text = "hello mine\n"
        #expect(buffer.isDirty)
        #expect(buffer.diskChanged(to: "hello agent\n", stamp: agentStamp) == .conflict)
        #expect(buffer.conflict)
        #expect(buffer.text == "hello mine\n")
        #expect(buffer.loadedStamp == loadedStamp)
        #expect(buffer.disk == EditBuffer.DiskVersion(text: "hello agent\n", stamp: agentStamp))
    }

    @Test func reloadDropsTheEdits() {
        var buffer = conflicted()
        buffer.reload()
        #expect(buffer.text == "hello agent\n")
        #expect(!buffer.isDirty)
        #expect(!buffer.conflict)
        #expect(buffer.loadedStamp == agentStamp)
        #expect(buffer.disk == nil)
    }

    @Test func keepMineLetsTheNextSaveThrough() {
        var buffer = conflicted()
        #expect(!buffer.canSave(current: agentStamp))
        buffer.keepMine()
        #expect(buffer.keepsMine)
        #expect(!buffer.conflict)
        #expect(buffer.text == "hello mine\n")
        #expect(buffer.canSave(current: agentStamp))
        buffer.saved("hello mine\n", stamp: laterStamp)
        #expect(!buffer.keepsMine)
        #expect(buffer.loadedStamp == laterStamp)
    }

    @Test func aStaleStampBlocksTheSaveWithoutKeepMine() {
        let buffer = loaded()
        #expect(buffer.canSave(current: loadedStamp))
        #expect(!buffer.canSave(current: agentStamp))
        #expect(!buffer.canSave(current: .missing))
    }

    @Test func savingClearsTheDirtyState() {
        var buffer = loaded()
        buffer.text = "hello world\n"
        buffer.saved("hello world\n", stamp: laterStamp)
        #expect(!buffer.isDirty)
        #expect(buffer.loaded == "hello world\n")
        #expect(buffer.loadedStamp == laterStamp)
        #expect(buffer.canSave(current: laterStamp))
    }

    /// Keep Mine is about the version the user saw: one written after it blocks the save again, and shows the conflict.
    @Test func keepMineCoversOnlyTheVersionItWasChosenOver() {
        var buffer = conflicted()
        buffer.keepMine()
        #expect(!buffer.canSave(current: laterStamp))
        #expect(buffer.diskChanged(to: "hello later\n", stamp: laterStamp) == .conflict)
        #expect(buffer.conflict)
        #expect(!buffer.keepsMine)
    }

    /// Each check of the disk may report the version already recorded: a Keep Mine stands.
    @Test func theVersionAlreadySeenChangesNothing() {
        var buffer = conflicted()
        #expect(buffer.diskChanged(to: "hello agent\n", stamp: agentStamp) == .conflict)
        buffer.keepMine()
        #expect(buffer.diskChanged(to: "hello agent\n", stamp: agentStamp) == .none)
        #expect(buffer.keepsMine)
        #expect(buffer.canSave(current: agentStamp))
    }

    /// A file touched, or written back with the text the buffer loaded, only moves the stamp, so the next save goes
    /// through.
    @Test func aTouchedFileOnlyMovesTheStamp() {
        var buffer = loaded()
        buffer.text = "hello mine\n"
        let touched = FileStamp(data: Data("hello\n".utf8), modificationDate: Date(timeIntervalSince1970: 5))
        #expect(buffer.diskChanged(to: "hello\n", stamp: touched) == .none)
        #expect(!buffer.conflict)
        #expect(buffer.isDirty)
        #expect(buffer.canSave(current: touched))
    }

    /// The agent wrote exactly the unsaved text: nothing is left to save.
    @Test func theFileTakingTheUnsavedTextCleansTheBuffer() {
        var buffer = loaded()
        buffer.text = "hello agent\n"
        #expect(buffer.diskChanged(to: "hello agent\n", stamp: agentStamp) == .none)
        #expect(!buffer.isDirty)
        #expect(!buffer.conflict)
    }

    @Test func textTypedDuringASaveStaysUnsaved() {
        var buffer = loaded()
        buffer.text = "hello wor"
        let written = buffer.text
        buffer.text = "hello world\n"
        buffer.saved(written, stamp: laterStamp)
        #expect(buffer.isDirty)
        #expect(buffer.loaded == "hello wor")
    }
}

/// `EDIT-02`'s "keeping its line endings and final newline": the bytes a file is read from are the bytes it is saved as.
struct TextFormatTests {
    @Test func aCRLFFileEditsWithNewlinesAndSavesWithCRLF() throws {
        let file = Data("one\r\ntwo\r\n".utf8)
        let decoded = try #require(TextFormat.decode(file))
        #expect(decoded.text == "one\ntwo\n")
        #expect(decoded.format == TextFormat(lineEnding: .crlf))
        #expect(decoded.format.encode(decoded.text) == file)
        #expect(decoded.format.encode("one\ntwo\nthree\n") == Data("one\r\ntwo\r\nthree\r\n".utf8))
    }

    /// A file that mixes both keeps its "\r"s in the text, so every line is written back as it was.
    @Test func aMixedFileKeepsEachLinesEnding() throws {
        let file = Data("one\r\ntwo\nthree".utf8)
        let decoded = try #require(TextFormat.decode(file))
        #expect(decoded.format.lineEnding == .lf)
        #expect(decoded.text == "one\r\ntwo\nthree")
        #expect(decoded.format.encode(decoded.text) == file)
    }

    @Test func aByteOrderMarkRoundTrips() throws {
        let file = Data([0xEF, 0xBB, 0xBF] + Array("hello\n".utf8))
        let decoded = try #require(TextFormat.decode(file))
        #expect(decoded.text == "hello\n")
        #expect(decoded.format.hasByteOrderMark)
        #expect(decoded.format.encode(decoded.text) == file)
    }

    @Test func theFinalNewlineIsNeitherAddedNorDropped() throws {
        for file in ["one\ntwo", "one\ntwo\n", "one\r\ntwo", "one\r\ntwo\r\n", ""] {
            let data = Data(file.utf8)
            let decoded = try #require(TextFormat.decode(data))
            #expect(decoded.format.encode(decoded.text) == data)
        }
    }

    @Test func bytesThatAreNotUTF8AreNotText() {
        #expect(TextFormat.decode(Data([0x68, 0xFF, 0xFE, 0x69])) == nil)
    }
}

/// `EDIT-02` and `FIL-06` on disk: what `TextFile` reads, and a save that keeps a link a link.
@Suite(.blockingWork)
struct TextFileTests {
    /// `WorktreeLinker`'s `.env` links: the save writes the main clone's file, and the worktree's entry stays a link.
    @Test func savingASymlinkWritesItsTargetAndKeepsTheLink() throws {
        let folder = try Fixtures.temporaryDirectory("edit")
        let target = folder.appendingPathComponent("main.env")
        try Data("A=1\n".utf8).write(to: target)
        let link = folder.appendingPathComponent("worktree.env")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(TextFile.snapshot(of: link).text == "A=1\n")
        let stamp = try TextFile.write(Data("A=2\n".utf8), to: link)

        let kind = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(kind == .typeSymbolicLink)
        #expect(try String(contentsOf: target, encoding: .utf8) == "A=2\n")
        #expect(TextFile.snapshot(of: link).stamp == stamp)
    }

    /// The atomic write keeps what the file had: a script stays executable.
    @Test func savingKeepsTheFilesPermissions() throws {
        let script = try Fixtures.temporaryDirectory("edit").appendingPathComponent("run.sh")
        try Data("echo one\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        try TextFile.write(Data("echo two\n".utf8), to: script)

        #expect(try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int == 0o755)
        #expect(try String(contentsOf: script, encoding: .utf8) == "echo two\n")
    }

    @Test func aMissingFileIsMissingAndASaveCreatesIt() throws {
        let file = try Fixtures.temporaryDirectory("edit").appendingPathComponent("later.md")
        let snapshot = TextFile.snapshot(of: file)
        #expect(!snapshot.exists)
        #expect(snapshot.stamp == .missing)
        #expect(TextFile.modificationDate(of: file) == nil)

        try TextFile.write(Data("now\n".utf8), to: file)
        #expect(TextFile.snapshot(of: file).text == "now\n")
    }

    /// FIL-06's binary rule: a NUL byte in the first 8 KB. The file still has a stamp, so a save can tell it changed.
    @Test func aBinaryFileHasAStampAndNoText() throws {
        let file = try Fixtures.temporaryDirectory("edit").appendingPathComponent("image.bin")
        try Data([0x89, 0x50, 0x00, 0x47]).write(to: file)
        let snapshot = TextFile.snapshot(of: file)
        #expect(snapshot.exists)
        #expect(snapshot.text == nil)
        #expect(snapshot.stamp.contentHash != nil)
        #expect(EditorState(snapshot) == .unavailable(size: 4))
    }

    /// EDIT-01's 2 MB rule: a larger text file opens read-only.
    @Test func textOver2MBOpensReadOnly() throws {
        let folder = try Fixtures.temporaryDirectory("edit")
        let small = folder.appendingPathComponent("small.log")
        let large = folder.appendingPathComponent("large.log")
        try Data(repeating: UInt8(ascii: "a"), count: TextFile.editableLimit).write(to: small)
        try Data(repeating: UInt8(ascii: "a"), count: TextFile.editableLimit + 1).write(to: large)

        #expect(EditorState(TextFile.snapshot(of: small)).document?.isReadOnly == false)
        #expect(EditorState(TextFile.snapshot(of: large)).document?.isReadOnly == true)
    }
}
