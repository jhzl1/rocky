import CoreServices
import Foundation
import Testing
@testable import RockyKit

/// The batches a watcher reported, from FSEvents' queue.
private final class FolderEventsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [FolderEvents] = []

    func append(_ events: FolderEvents) {
        lock.withLock { batches.append(events) }
    }

    var folders: Set<String> {
        lock.withLock { batches.reduce(into: Set<String>()) { $0.formUnion($1.folders) } }
    }
}

/// `GIT-01`'s and `FIL-07`'s FSEvents stream.
struct FileWatcherTests {
    /// FIL-07: the event names the new file's folder, resolved the way FSEvents reports it (`/private/var/…`).
    @Test func reportsTheFolderOfANewFile() async throws {
        let root = try Fixtures.temporaryDirectory("watcher")
        let folder = root.appendingPathComponent("src/api", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let box = FolderEventsBox()
        let watcher = FileWatcher(paths: [root], excluding: FileWatcher.excludedFolders, debounce: .milliseconds(100)) {
            box.append($0)
        }
        defer { watcher.stop() }
        // FSEvents starts reporting a moment after the stream starts.
        try await Task.sleep(for: .milliseconds(200))

        try Data("new\n".utf8).write(to: folder.appendingPathComponent("new.ts"))

        let expected = FileWatcher.canonicalPath(folder)
        #expect(expected.hasPrefix("/private/") || !root.path.hasPrefix("/var/"))
        for _ in 0..<60 where !box.folders.contains(expected) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(box.folders.contains(expected))
    }

    /// GIT-01: `node_modules` anywhere and `.git/objects` never reach the model; a rescan names a subtree.
    @Test func excludedFoldersAreDroppedAndRescansNameSubtrees() {
        let none = FSEventStreamEventFlags(kFSEventStreamEventFlagNone)
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let batch = FileWatcher.EventHandler.folderEvents(
            [
                (path: "/w/src/", flags: none),
                (path: "/w/node_modules/react/", flags: none),
                (path: "/w/packages/ui/node_modules/", flags: none),
                (path: "/w/.git/objects/ab/", flags: none),
                (path: "/repo/.git/worktrees/tokyo/", flags: none),
                (path: "/w/dist/", flags: rescan),
            ],
            roots: ["/w", "/repo/.git/worktrees/tokyo"],
            excluded: FileWatcher.excludedFolders
        )
        #expect(batch.folders == ["/w/src", "/repo/.git/worktrees/tokyo"])
        #expect(batch.subtrees == ["/w/dist"])
    }
}
