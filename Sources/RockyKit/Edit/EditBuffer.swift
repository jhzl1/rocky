import CryptoKit
import Foundation

/// What a file on disk was when Rocky read or wrote it (`EDIT-03`): its modification date and a SHA-256 of its bytes.
/// A save compares the file's stamp with the buffer's, so an edit never overwrites a change it has not seen.
public struct FileStamp: Equatable, Sendable {
    public let modificationDate: Date?
    /// nil for a missing file, or one too large to be read.
    public let contentHash: Data?

    public init(modificationDate: Date?, contentHash: Data?) {
        self.modificationDate = modificationDate
        self.contentHash = contentHash
    }

    /// The stamp of a file holding `data`, modified at `modificationDate`.
    public init(data: Data, modificationDate: Date?) {
        self.init(modificationDate: modificationDate, contentHash: Data(SHA256.hash(data: data)))
    }

    /// A file that is not there.
    public static let missing = FileStamp(modificationDate: nil, contentHash: nil)
}

/// What a change on disk did to a buffer (`EDIT-03`).
public enum DiskChangeOutcome: Equatable, Sendable {
    /// The buffer had no unsaved edits and took the file's new text.
    case reloaded
    /// The buffer has unsaved edits, which stay; the next save waits for Reload or Keep Mine.
    case conflict
    /// Nothing the user sees changed: the file holds what the buffer loaded, or the unsaved text itself.
    case none
}

/// One file's text in the editor against the file on disk (`EDIT-02`, `EDIT-03`; Review Focus 3): a save never
/// overwrites a version of the file the buffer has not seen, unless the user chose Keep Mine over that very version.
public struct EditBuffer: Equatable, Sendable {
    public var text: String
    /// What was on disk when the buffer loaded it or last saved.
    public private(set) var loaded: String
    public private(set) var loadedStamp: FileStamp
    /// The file changed on disk under unsaved edits, and the user has not picked Reload or Keep Mine yet.
    public private(set) var conflict = false
    /// Keep Mine was picked: the next save may overwrite `disk`.
    public private(set) var keepsMine = false
    /// The file's version the buffer has not taken: the one a conflict is about, which Reload takes and Keep Mine lets a
    /// save overwrite.
    public private(set) var disk: DiskVersion?

    public struct DiskVersion: Equatable, Sendable {
        public let text: String
        public let stamp: FileStamp
    }

    public init(text: String, stamp: FileStamp) {
        self.text = text
        self.loaded = text
        self.loadedStamp = stamp
    }

    public var isDirty: Bool {
        text != loaded
    }

    /// The newest version of the file the buffer knows about: a check of the disk that finds this date has nothing
    /// new to read.
    public var latestStamp: FileStamp {
        disk?.stamp ?? loadedStamp
    }

    /// The file on disk now holds `newText` (`EDIT-03`). A clean buffer takes it; a buffer with unsaved edits keeps
    /// them and records the conflict. The version already recorded, reported again, changes nothing, so a Keep Mine
    /// stands until the file changes once more.
    public mutating func diskChanged(to newText: String, stamp: FileStamp) -> DiskChangeOutcome {
        if let disk, disk.stamp == stamp { return conflict ? .conflict : .none }
        if newText == loaded {
            // Touched, or written back with the text the buffer loaded: nothing to take and nothing in conflict.
            loadedStamp = stamp
            clearDisk()
            return .none
        }
        if !isDirty {
            text = newText
            loaded = newText
            loadedStamp = stamp
            clearDisk()
            return .reloaded
        }
        if newText == text {
            // The file now holds exactly the unsaved text: nothing is left to save.
            loaded = newText
            loadedStamp = stamp
            clearDisk()
            return .none
        }
        disk = DiskVersion(text: newText, stamp: stamp)
        conflict = true
        keepsMine = false
        return .conflict
    }

    /// `EDIT-03`'s Reload: drops the unsaved edits for the file's version on disk.
    public mutating func reload() {
        guard let disk else { return }
        text = disk.text
        loaded = disk.text
        loadedStamp = disk.stamp
        clearDisk()
    }

    /// `EDIT-03`'s Keep Mine: the edits stay and the next save overwrites the version on disk.
    public mutating func keepMine() {
        guard disk != nil else { return }
        conflict = false
        keepsMine = true
    }

    /// Whether a save may write over the file as it is now (`current`): it is still what the buffer loaded, or it is
    /// the version the user chose Keep Mine over. A stale stamp without Keep Mine blocks the save.
    public func canSave(current: FileStamp) -> Bool {
        current == loadedStamp || (keepsMine && current == disk?.stamp)
    }

    /// `written` is on disk now, as `stamp`. Text typed while the file was written stays unsaved.
    public mutating func saved(_ written: String, stamp: FileStamp) {
        loaded = written
        loadedStamp = stamp
        clearDisk()
    }

    private mutating func clearDisk() {
        disk = nil
        conflict = false
        keepsMine = false
    }
}

/// A text file open in the editor (`EDIT-01`): its buffer and what its tab shows around it.
public struct EditorDocument: Equatable, Sendable {
    public var buffer: EditBuffer
    public let format: TextFormat
    /// Over `TextFile.editableLimit`: shown in plain text, never edited (`EDIT-01`, `FIL-06`'s 2–20 MB).
    public let isReadOnly: Bool
    /// In bytes, as last read or written.
    public var size: Int
    /// When a change on disk reloaded the clean buffer; `AppModel` clears it 2 s later. `EDIT-03`'s "Reloaded" shows
    /// meanwhile.
    public var reloadedAt: Date?
    /// `EDIT-03`'s agent-working banner was closed in this file's tab.
    public var hidesAgentBanner = false

    public init(snapshot: TextFile.Snapshot, text: String) {
        buffer = EditBuffer(text: text, stamp: snapshot.stamp)
        format = snapshot.format
        isReadOnly = snapshot.size > TextFile.editableLimit
        size = snapshot.size
    }
}

/// A file's place in the editor (`AppModel.editors`).
public enum EditorState: Equatable, Sendable {
    case loading
    /// No file at the path (deleted, or never there).
    case missing
    /// Not text Rocky edits: binary, not UTF-8, or over `TextFile.readableLimit`. Its tab shows it as before M3.
    case unavailable(size: Int)
    case document(EditorDocument)

    init(_ snapshot: TextFile.Snapshot) {
        if !snapshot.exists {
            self = .missing
        } else if let text = snapshot.text {
            self = .document(EditorDocument(snapshot: snapshot, text: text))
        } else {
            self = .unavailable(size: snapshot.size)
        }
    }

    public var document: EditorDocument? {
        if case .document(let document) = self { return document }
        return nil
    }
}

/// A worktree file's text at the workspace's base, for the editor's change bars (`EDIT-04`).
public struct EditorBase: Equatable, Sendable {
    public struct Key: Hashable, Sendable {
        /// The base commit (`WorkspaceChanges.base`).
        public let commit: String
        /// The file's path at the base (a rename's old path); nil for a file the base lacks, whose every line is new.
        public let path: String?

        public init(commit: String, path: String?) {
            self.commit = commit
            self.path = path
        }
    }

    public let key: Key
    /// Empty for a file the base lacks; nil when git has no text for it (an ignored file, a binary one), which shows
    /// no bars. Its line endings are normalized the way the editor's text is (`TextFormat.decode`), so a change of
    /// line endings alone shows no bar.
    public let text: String?
}
