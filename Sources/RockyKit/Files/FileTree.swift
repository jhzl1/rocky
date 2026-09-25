import Foundation

/// One item of a folder's listing (`FIL-02`): its name, and whether it is a folder. A symbolic link counts as what it
/// points to, and a broken one as a file (`WorktreeFiles.listing`).
public struct FileEntry: Equatable, Hashable, Sendable {
    public let name: String
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// The worktree's files as git lists them (`FIL-04`'s source and `FIL-03`'s ignored rule): tracked and untracked files
/// that no ignore rule hides, less the files deleted from disk. Built once per `ls-files` run, off the main actor, so
/// each keystroke of the filter is one pass over `paths` (`FileTree.rank`) and each tree row one set lookup.
public struct FileList: Sendable {
    /// `listed` minus `deleted`, in Finder's order (`localizedStandardCompare`, folder by folder: "file2" before
    /// "file10"), sorted once here. The filter's ties keep this order.
    public let paths: [String]
    /// Every listed file and every folder that holds one: what is not in here is ignored.
    private let known: Set<String>
    /// `ls-files`' output as it came, which decides equality: a new run that prints the same lists is the same list
    /// (`WorktreeFiles.list(worktree:reusing:)`).
    let listed: [String]
    let deleted: [String]
    /// `paths` lowercased, as bytes, for `FileTree.rank`.
    let index: SearchIndex

    /// `listed` and `deleted` are worktree-relative paths from `git ls-files`. A nested repository lists as its folder
    /// with a trailing "/": it counts as a folder that is not ignored, and adds no file.
    public init(listed: [String], deleted: [String]) {
        self.listed = listed
        self.deleted = deleted
        let built = Self.build(listed: listed, deleted: deleted)
        paths = built.paths
        known = built.known
        index = SearchIndex(paths: built.paths)
    }

    /// `FIL-03` and `FIL-07`'s rule: an entry is ignored when it is neither listed nor the parent of a listed path. So
    /// is an empty folder, which git never lists, and everything inside an ignored folder. The root never is.
    public func isIgnored(_ path: String) -> Bool {
        !path.isEmpty && !known.contains(path)
    }

    /// Where `path` is in `paths`, nil when the list does not hold it (a folder, an ignored or a deleted file). A
    /// binary search in the order `paths` was sorted in, folder by folder and each folder's entries by name, so looking
    /// up the few recent files of `FIL-08` needs no index of every path.
    public func position(of path: String) -> Int? {
        var low = 0
        var high = paths.count
        while low < high {
            let middle = (low + high) / 2
            if FileTree.pathPrecedes(paths[middle], path) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < paths.count && paths[low] == path ? low : nil
    }

    /// `paths` in Finder's order, and every path the list knows. Files are grouped by folder, and each folder's files
    /// and subfolders are sorted together by name, so a sort compares short names instead of whole paths.
    private static func build(listed: [String], deleted: [String]) -> (paths: [String], known: Set<String>) {
        let gone = Set(deleted)
        var files: [String: [String]] = [:]
        var subfolders: [String: Set<String>] = [:]
        var known = Set<String>()
        known.reserveCapacity(listed.count)
        for raw in listed {
            let isFolder = raw.hasSuffix("/")
            let path = isFolder ? String(raw.dropLast()) : raw
            // `--cached` repeats a file with a conflict once per stage.
            guard !path.isEmpty, !gone.contains(path), known.insert(path).inserted else { continue }
            let (parent, name) = FileTree.split(path)
            if isFolder {
                subfolders[parent, default: []].insert(name)
            } else {
                files[parent, default: []].append(name)
            }
            // The folders above it; once one is known, so are the ones above that.
            var folder = parent
            while !folder.isEmpty {
                let (above, folderName) = FileTree.split(folder)
                guard subfolders[above, default: []].insert(folderName).inserted else { break }
                known.insert(folder)
                folder = above
            }
        }
        var ordered: [String] = []
        ordered.reserveCapacity(known.count)
        // Depth first, each folder's entries in Finder's order, without recursion (a deep tree stays off the stack).
        var stack: [(folder: String, entries: [(name: String, isFolder: Bool)], next: Int)] = []
        func push(_ folder: String) {
            var entries = (files[folder] ?? []).map { (name: $0, isFolder: false) }
            entries += (subfolders[folder] ?? []).map { (name: $0, isFolder: true) }
            entries.sort { FileTree.finderPrecedes($0.name, $1.name) }
            stack.append((folder: folder, entries: entries, next: 0))
        }
        push("")
        while !stack.isEmpty {
            let top = stack.count - 1
            guard stack[top].next < stack[top].entries.count else {
                stack.removeLast()
                continue
            }
            let entry = stack[top].entries[stack[top].next]
            stack[top].next += 1
            let path = FileTree.join(stack[top].folder, entry.name)
            if entry.isFolder {
                push(path)
            } else {
                ordered.append(path)
            }
        }
        return (ordered, known)
    }
}

extension FileList: Equatable {
    /// Two lists are equal when `ls-files` printed the same, which compares the arrays git gave, not the derived index.
    /// A list compared with itself costs nothing: arrays sharing their storage are equal at once.
    public static func == (lhs: FileList, rhs: FileList) -> Bool {
        lhs.listed == rhs.listed && lhs.deleted == rhs.deleted
    }
}

/// `FileList.paths` lowercased, back to back as UTF-8 bytes, with where each path and its name start: `FileTree.rank`
/// searches them with `memmem`, one C call per test, which keeps 100,000 paths under `FIL-07`'s 50 ms.
struct SearchIndex: Sendable {
    let bytes: [UInt8]
    /// `paths.count + 1` offsets: path `i` is `bytes[starts[i]..<starts[i + 1]]`.
    let starts: [Int]
    /// Where each path's name starts, after its last "/".
    let nameStarts: [Int]

    init(paths: [String]) {
        var bytes: [UInt8] = []
        var starts: [Int] = []
        var nameStarts: [Int] = []
        starts.reserveCapacity(paths.count + 1)
        nameStarts.reserveCapacity(paths.count)
        for path in paths {
            starts.append(bytes.count)
            var nameStart = bytes.count
            for byte in path.lowercased().utf8 {
                bytes.append(byte)
                if byte == UInt8(ascii: "/") { nameStart = bytes.count }
            }
            nameStarts.append(nameStart)
        }
        starts.append(bytes.count)
        self.bytes = bytes
        self.starts = starts
        self.nameStarts = nameStarts
    }
}

/// One row of the All files tree (`FIL-02`), in the order the tree draws them.
public struct FileTreeRow: Equatable, Sendable, Identifiable {
    /// Worktree-relative.
    public let path: String
    public let name: String
    /// 0 at the worktree's root.
    public let depth: Int
    public let isDirectory: Bool
    public let isExpanded: Bool
    /// `FIL-03`: shown dimmed, with Show Ignored Files.
    public let isIgnored: Bool

    public var id: String { path }

    public init(path: String, name: String, depth: Int, isDirectory: Bool, isExpanded: Bool, isIgnored: Bool) {
        self.path = path
        self.name = name
        self.depth = depth
        self.isDirectory = isDirectory
        self.isExpanded = isExpanded
        self.isIgnored = isIgnored
    }
}

/// The All files tab of the selected workspace (`FIL-01`, `FIL-07`): git's list, the folders read so far (worktree-
/// relative, "" the root) and the expanded folders (stored per workspace).
public struct FileTreeState: Equatable, Sendable {
    public var list: FileList?
    /// Each read folder's entries, in Finder's order (`FileTree.sorted`). Kept until an event names the folder.
    public var listings: [String: [FileEntry]]
    public var expanded: Set<String>
    /// `ERR-02`: `git ls-files`' last lines when it failed, shown in place of the tree; nil once it worked.
    public var listFailure: String?

    public init(list: FileList? = nil, listings: [String: [FileEntry]] = [:], expanded: Set<String> = [], listFailure: String? = nil) {
        self.list = list
        self.listings = listings
        self.expanded = expanded
        self.listFailure = listFailure
    }
}

/// The All files tab's rules (`FIL-02`…`FIL-04`, `FIL-07`), pure so they are tested.
public enum FileTree {
    /// `FIL-02`'s rows: each listing in its order (folders first, then files, in Finder's order: `sorted`), a folder's
    /// children under it when it is expanded and its listing is read. Ignored entries are left out, or kept and flagged
    /// with `showsIgnored` (`FIL-03`). `.git` never shows; tracked dotfiles show like any file.
    public static func rows(listings: [String: [FileEntry]], expanded: Set<String>, list: FileList, showsIgnored: Bool) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        // Depth first without recursion: the folder, its entries and the next one to draw.
        var stack: [(folder: String, entries: [FileEntry], next: Int, depth: Int)] = []
        if let root = listings[""] { stack.append((folder: "", entries: root, next: 0, depth: 0)) }
        while !stack.isEmpty {
            let top = stack.count - 1
            guard stack[top].next < stack[top].entries.count else {
                stack.removeLast()
                continue
            }
            let entry = stack[top].entries[stack[top].next]
            stack[top].next += 1
            guard entry.name != ".git" else { continue }
            let depth = stack[top].depth
            let path = join(stack[top].folder, entry.name)
            let isIgnored = list.isIgnored(path)
            if isIgnored, !showsIgnored { continue }
            let isExpanded = entry.isDirectory && expanded.contains(path)
            rows.append(FileTreeRow(path: path, name: entry.name, depth: depth, isDirectory: entry.isDirectory, isExpanded: isExpanded, isIgnored: isIgnored))
            if isExpanded, let children = listings[path] {
                stack.append((folder: path, entries: children, next: 0, depth: depth + 1))
            }
        }
        return rows
    }

    /// A folder's entries in `FIL-02`'s order: folders first, then files, each by `localizedStandardCompare` ("file2"
    /// before "file10"). `WorktreeFiles.listing` sorts once, off the main actor, so drawing the tree sorts nothing.
    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return finderPrecedes(lhs.name, rhs.name)
        }
    }

    /// The expanded folders under `folder` whose rows show, so whose listings the tree needs: `entries` is `folder`'s
    /// listing. An ignored folder counts only with `showsIgnored`, and before git's list is read nothing counts as
    /// ignored.
    public static func shownSubfolders(of folder: String, entries: [FileEntry], expanded: Set<String>, list: FileList?, showsIgnored: Bool) -> [String] {
        entries.compactMap { entry -> String? in
            guard entry.isDirectory, entry.name != ".git" else { return nil }
            let path = join(folder, entry.name)
            guard expanded.contains(path), showsIgnored || !(list?.isIgnored(path) ?? false) else { return nil }
            return path
        }
    }

    /// Every folder whose listing the tree needs now: the root, then each expanded folder its rows reach, read or not.
    /// `FIL-07`: nothing else is ever read.
    public static func shownFolders(listings: [String: [FileEntry]], expanded: Set<String>, list: FileList?, showsIgnored: Bool) -> Set<String> {
        var shown: Set<String> = [""]
        var pending = [""]
        while let folder = pending.popLast() {
            guard let entries = listings[folder] else { continue }
            for child in shownSubfolders(of: folder, entries: entries, expanded: expanded, list: list, showsIgnored: showsIgnored)
            where shown.insert(child).inserted {
                pending.append(child)
            }
        }
        return shown
    }

    /// `FIL-04`'s ranking of `query` over `list.paths`, case-insensitive: the name starts with it; the name contains
    /// it; the path contains it; its characters appear in order in the name ("srv" finds `server.ts`); then in order
    /// anywhere in the path. Ties keep the list's order (Finder's). One pass with byte searches and no locale-aware
    /// comparison, so 100,000 paths rank in under 50 ms (`FIL-07`). Ignored files are not in the list, so they are
    /// never ranked. An empty query ranks every path, as one tier.
    ///
    /// `recent` (`FIL-08`, newest first) goes first inside each tier, newest first, and never above a better tier; a
    /// recent path the list does not hold is left out. The All files filter passes none.
    public static func rank(_ query: String, in list: FileList, recent: [String] = []) -> [String] {
        let lowered = query.lowercased()
        let needle = Array(lowered.utf8)
        let recentPositions = positions(of: recent, in: list)
        guard !needle.isEmpty else {
            guard !recentPositions.isEmpty else { return list.paths }
            return joined([Array(list.paths.indices)], recent: recentPositions, in: list)
        }
        // Where each of the query's characters ends in `needle`: the in-order ranks look for one character at a time,
        // all its bytes at once, so a byte never matches half of another character.
        var pieceEnds: [Int] = []
        var end = 0
        for scalar in lowered.unicodeScalars {
            end += UTF8.width(scalar)
            pieceEnds.append(end)
        }
        // Each rank's paths, as indices of `list.paths`, in the list's order.
        var buckets = [[Int]](repeating: [], count: 5)
        let index = list.index
        index.bytes.withUnsafeBufferPointer { bytes in
            needle.withUnsafeBufferPointer { needleBytes in
                index.starts.withUnsafeBufferPointer { starts in
                    index.nameStarts.withUnsafeBufferPointer { nameStarts in
                        pieceEnds.withUnsafeBufferPointer { pieces in
                            guard let base = bytes.baseAddress, let pattern = needleBytes.baseAddress else { return }
                            let length = needleBytes.count
                            /// The query's characters, in order, between the offsets `from` and `to`.
                            func appearsInOrder(from: Int, to: Int) -> Bool {
                                var position = from
                                var pieceStart = 0
                                for pieceEnd in pieces {
                                    let width = pieceEnd - pieceStart
                                    guard to - position >= width,
                                          let found = memmem(base + position, to - position, pattern + pieceStart, width) else { return false }
                                    position = Int(bitPattern: found) - Int(bitPattern: base) + width
                                    pieceStart = pieceEnd
                                }
                                return true
                            }
                            for item in 0..<nameStarts.count {
                                let start = starts[item]
                                let end = starts[item + 1]
                                let nameStart = nameStarts[item]
                                if end - start >= length, let found = memmem(base + start, end - start, pattern, length) {
                                    let at = Int(bitPattern: found) - Int(bitPattern: base)
                                    if at >= nameStart {
                                        // The first match is in the name: at its start, or inside it.
                                        buckets[at == nameStart ? 0 : 1].append(item)
                                    } else if end - nameStart >= length, memcmp(base + nameStart, pattern, length) == 0 {
                                        buckets[0].append(item)
                                    } else if end - nameStart >= length, memmem(base + nameStart, end - nameStart, pattern, length) != nil {
                                        buckets[1].append(item)
                                    } else {
                                        buckets[2].append(item)
                                    }
                                } else if appearsInOrder(from: start, to: end) {
                                    // Checked over the whole path first: most paths fail there, with one pass.
                                    buckets[appearsInOrder(from: nameStart, to: end) ? 3 : 4].append(item)
                                }
                            }
                        }
                    }
                }
            }
        }
        return joined(buckets, recent: recentPositions, in: list)
    }

    /// Each of `paths` the list holds, as its index in `list.paths`, in the order given and each once.
    static func positions(of paths: [String], in list: FileList) -> [Int] {
        var seen = Set<Int>()
        return paths.compactMap { path in
            guard let position = list.position(of: path), seen.insert(position).inserted else { return nil }
            return position
        }
    }

    /// The tiers one after the other, as paths: in each, the `recent` indices it holds first, in `recent`'s order,
    /// then the rest in the list's order. A tier's indices are ascending, so a recent one is found by binary search
    /// and skipped with one comparison per item, which keeps `rank` in its budget with 20 recent files.
    private static func joined(_ tiers: [[Int]], recent: [Int], in list: FileList) -> [String] {
        var ranked: [String] = []
        ranked.reserveCapacity(tiers.reduce(0) { $0 + $1.count })
        for tier in tiers {
            let first = recent.filter { holds(tier, $0) }
            for item in first { ranked.append(list.paths[item]) }
            let skipped = first.sorted()
            var next = 0
            for item in tier {
                if next < skipped.count, skipped[next] == item {
                    next += 1
                    continue
                }
                ranked.append(list.paths[item])
            }
        }
        return ranked
    }

    /// Whether the ascending `items` hold `item`.
    private static func holds(_ items: [Int], _ item: Int) -> Bool {
        var low = 0
        var high = items.count
        while low < high {
            let middle = (low + high) / 2
            if items[middle] < item {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < items.count && items[low] == item
    }

    /// The characters of `path` to draw in `accent` for `query` (`FIL-04`), by the rank that matched it: the query in
    /// the name, else in the path, else each of its characters in order, in the name first. Adjacent characters make
    /// one range. The view asks only for the rows it draws.
    public static func matches(_ query: String, in path: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        let nameStart = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        let name = path[nameStart...]
        if let range = name.range(of: query, options: [.caseInsensitive, .anchored]) { return [range] }
        if let range = name.range(of: query, options: .caseInsensitive) { return [range] }
        if let range = path.range(of: query, options: .caseInsensitive) { return [range] }
        return inOrder(query, in: path, from: nameStart) ?? inOrder(query, in: path, from: path.startIndex) ?? []
    }

    /// Each of `query`'s characters, lowercased, found in turn in `path` from `start`; nil when one is missing.
    private static func inOrder(_ query: String, in path: String, from start: String.Index) -> [Range<String.Index>]? {
        var ranges: [Range<String.Index>] = []
        var position = start
        for character in query.lowercased() {
            let wanted = String(character)
            guard let found = path[position...].firstIndex(where: { $0.lowercased() == wanted }) else { return nil }
            let next = path.index(after: found)
            if let last = ranges.last, last.upperBound == found {
                ranges[ranges.count - 1] = last.lowerBound..<next
            } else {
                ranges.append(found..<next)
            }
            position = next
        }
        return ranges
    }

    /// `FIL-07`: the worktree-relative folders whose listings a batch of events makes stale ("" the root), and the
    /// subtrees to read again whole. `worktree` is compared as `FileWatcher` reports it (`FileWatcher.canonicalPath`).
    /// Paths outside the worktree, such as its git directory, invalidate nothing.
    public static func invalidated(by events: FolderEvents, worktree: String) -> (folders: Set<String>, subtrees: Set<String>) {
        let root = worktree.count > 1 && worktree.hasSuffix("/") ? String(worktree.dropLast()) : worktree
        let prefix = root + "/"
        func relative(_ path: String) -> String? {
            if path == root { return "" }
            guard path.hasPrefix(prefix) else { return nil }
            return String(path.dropFirst(prefix.count))
        }
        return (Set(events.folders.compactMap(relative)), Set(events.subtrees.compactMap(relative)))
    }

    /// The folders above `path`, outermost first: "src/a/b.ts" → ["src", "src/a"]. Reveal expands them (`FIL-05`).
    public static func ancestors(of path: String) -> [String] {
        var ancestors: [String] = []
        var current = ""
        for part in path.split(separator: "/").dropLast() {
            current = join(current, String(part))
            ancestors.append(current)
        }
        return ancestors
    }

    // MARK: Paths

    /// `folder` joined with `name`; the root is "".
    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    /// "src/a/b.ts" → ("src/a", "b.ts"); "b.ts" → ("", "b.ts").
    static func split(_ path: String) -> (parent: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    /// Finder's order for two names (`localizedStandardCompare`), with a byte order between names it calls equal
    /// ("a" and "A"), so every sort gives the same order.
    static func finderPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.localizedStandardCompare(rhs) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs < rhs
        }
    }

    /// `FileList.paths`' order for two paths: their first differing names in Finder's order, as the list was built
    /// folder by folder. A path whose names all begin the other comes first (a folder and a file never share a path
    /// in one list).
    static func pathPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs.split(separator: "/", omittingEmptySubsequences: false).makeIterator()
        var right = rhs.split(separator: "/", omittingEmptySubsequences: false).makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case let (leftName?, rightName?):
                guard leftName != rightName else { continue }
                return finderPrecedes(String(leftName), String(rightName))
            case (nil, .some):
                return true
            case (.some, nil), (nil, nil):
                return false
            }
        }
    }
}
