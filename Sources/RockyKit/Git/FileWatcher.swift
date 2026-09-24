import CoreServices
import Foundation

/// The folders one batch of file system events named (`FIL-07`), as canonical absolute paths without a trailing
/// slash, the way FSEvents reports them (`/private/var/…`, not `/var/…`).
public struct FolderEvents: Equatable, Sendable {
    /// Folders whose own entries changed: FSEvents' directory-level paths.
    public var folders: Set<String>
    /// Folders whose whole subtree must be read again: FSEvents asked for a rescan (`MustScanSubDirs`), or dropped
    /// events.
    public var subtrees: Set<String>

    public init(folders: Set<String> = [], subtrees: Set<String> = []) {
        self.folders = folders
        self.subtrees = subtrees
    }

    public var isEmpty: Bool { folders.isEmpty && subtrees.isEmpty }
}

/// A running watch of one workspace's folders, which `AppModel` stops when the workspace goes. `FileWatcher` in Rocky;
/// tests pass their own, and fire its events.
public protocol WorkspaceWatch: AnyObject, Sendable {
    func stop()
}

extension FileWatcher: WorkspaceWatch {}

/// One FSEvents stream over a few folders (`GIT-01`, `FIL-07`): no process and no timer at rest. FSEvents coalesces
/// the events of `debounce` into one batch (its latency) and calls `onChange` once per batch, on a queue of its own.
/// Events inside an excluded folder (`node_modules`, `.git/objects`) never reach `onChange`.
public final class FileWatcher: @unchecked Sendable {
    /// `GIT-01`'s 500 ms, which `FIL-07`'s `ls-files` shares.
    public static let debounce: Duration = .milliseconds(500)
    /// `GIT-01`: folders whose churn says nothing about a workspace's changes. Matched as whole path components
    /// anywhere under a watched folder, so a package's own `node_modules` is left out too.
    public static let excludedFolders = ["node_modules", ".git/objects"]

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let handler: EventHandler
    private let queue = DispatchQueue(label: "rocky.file-watcher", qos: .utility)

    /// `paths` are resolved once, here, to what FSEvents reports, so consumers compare like with like. `excluding`
    /// holds folder names or relative paths (`node_modules`, `.git/objects`).
    public init(paths: [URL], excluding: [String], debounce: Duration, onChange: @escaping @Sendable (FolderEvents) -> Void) {
        let roots = paths.map(Self.canonicalPath)
        handler = EventHandler(roots: roots, excluded: excluding, onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<EventHandler>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<EventHandler>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let handler = Unmanaged<EventHandler>.fromOpaque(info).takeUnretainedValue()
            // Without kFSEventStreamCreateFlagUseCFTypes the paths are C strings.
            let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var events: [(path: String, flags: FSEventStreamEventFlags)] = []
            events.reserveCapacity(count)
            for index in 0..<count {
                events.append((String(cString: names[index]), flags[index]))
            }
            handler.handle(events)
        }
        let components = debounce.components
        let latency = CFTimeInterval(components.seconds) + CFTimeInterval(components.attoseconds) / 1e18
        let created: FSEventStreamRef? = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        )
        guard let created else { return }
        // The kernel skips these at the top of each watched folder, so they do not even wake the queue. FSEvents takes
        // at most eight; nested ones are filtered in `EventHandler`.
        let exclusions = roots.flatMap { root in excluding.map { "\(root)/\($0)" } }.prefix(8)
        if !exclusions.isEmpty {
            _ = FSEventStreamSetExclusionPaths(created, Array(exclusions) as CFArray)
        }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    deinit {
        stop()
    }

    /// Stops the stream for good; later calls do nothing.
    public func stop() {
        let stopped: FSEventStreamRef? = lock.withLock {
            defer { stream = nil }
            return stream
        }
        guard let stopped else { return }
        FSEventStreamStop(stopped)
        FSEventStreamInvalidate(stopped)
        FSEventStreamRelease(stopped)
    }

    /// A workspace's watched folders (`GIT-01`): the worktree and its git directory, which the worktree's `.git` file
    /// names (`<repo>/.git/worktrees/<name>`). A main clone's `.git` is inside it already.
    public static func workspacePaths(worktree: URL) -> [URL] {
        var paths = [worktree]
        if let gitDirectory = GitChangesService.gitDirectory(worktree: worktree),
           !canonicalPath(gitDirectory).hasPrefix(canonicalPath(worktree) + "/") {
            paths.append(gitDirectory)
        }
        return paths
    }

    /// The path FSEvents reports for `url`: symbolic links resolved, `/var` as `/private/var`. `URL`'s own resolving
    /// strips `/private`, the opposite. A path that does not exist stays as it is.
    public static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Turns one callback's events into `FolderEvents`. Immutable, so FSEvents' queue can read it.
    final class EventHandler: Sendable {
        let roots: [String]
        let excluded: [String]
        let onChange: @Sendable (FolderEvents) -> Void

        init(roots: [String], excluded: [String], onChange: @escaping @Sendable (FolderEvents) -> Void) {
            self.roots = roots
            self.excluded = excluded
            self.onChange = onChange
        }

        private static let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        )
        private static let rootChangedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        private static let historyDoneFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)

        func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
            let batch = Self.folderEvents(events, roots: roots, excluded: excluded)
            guard !batch.isEmpty else { return }
            onChange(batch)
        }

        static func folderEvents(_ events: [(path: String, flags: FSEventStreamEventFlags)], roots: [String], excluded: [String]) -> FolderEvents {
            var batch = FolderEvents()
            for event in events where event.flags & historyDoneFlag == 0 {
                let path = trimmed(event.path)
                if event.flags & rootChangedFlag != 0 {
                    // A watched folder moved or was deleted: all of it is unknown now.
                    batch.subtrees.insert(path)
                    continue
                }
                guard !isExcluded(path, roots: roots, excluded: excluded) else { continue }
                if event.flags & rescanFlags != 0 {
                    batch.subtrees.insert(path)
                } else {
                    batch.folders.insert(path)
                }
            }
            return batch
        }

        /// FSEvents ends a folder's path with "/".
        private static func trimmed(_ path: String) -> String {
            guard path.count > 1, path.hasSuffix("/") else { return path }
            return String(path.dropLast())
        }

        /// Whether `path` is an excluded folder or inside one, below the watched folder that holds it.
        static func isExcluded(_ path: String, roots: [String], excluded: [String]) -> Bool {
            let root = roots.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            let below = root.map { String(path.dropFirst($0.count)) } ?? path
            return excluded.contains { name in
                below.hasSuffix("/" + name) || below.contains("/" + name + "/")
            }
        }
    }
}
