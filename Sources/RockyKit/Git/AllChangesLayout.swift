import Foundation

/// `ALL-05`: what the All changes tab of a workspace keeps while Rocky runs: the folded files, the unchanged runs
/// expanded and the large files shown, by worktree-relative path, and the current file of `ALL-06`'s keys.
public struct AllChangesState: Equatable, Sendable {
    public var folded: Set<String> = []
    public var expandedGaps: [String: Set<DiffGap>] = [:]
    public var shownLarge: Set<String> = []
    /// `ALL-06`: the file ⌥⌘↓ / ⌥⌘↑ last scrolled to, whose header shows the accent bar.
    public var current: String?
    /// The hunks' new starts each file's runs were expanded for: when they move, a run no longer names the same lines.
    public var hunkStarts: [String: [Int]] = [:]

    public init() {}

    /// The state for a new reading of the changes: a file no longer listed is forgotten, so it comes back unfolded,
    /// and a file whose hunks moved loses its expanded runs, as a diff tab does.
    public func reconciled(with changes: WorkspaceChanges) -> AllChangesState {
        let files = Dictionary(changes.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var next = self
        next.folded = folded.filter { files[$0] != nil }
        next.shownLarge = shownLarge.filter { files[$0] != nil }
        next.expandedGaps = expandedGaps.filter { path, _ in
            guard let file = files[path] else { return false }
            return hunkStarts[path] == file.hunks.map(\.newStart)
        }
        next.hunkStarts = hunkStarts.filter { next.expandedGaps[$0.key] != nil }
        if let current, files[current] == nil { next.current = nil }
        return next
    }

    /// `ALL-04`'s click on a collapsed run, remembering the hunks it was made for.
    public mutating func expand(_ gap: DiffGap, of file: FileDiff) {
        expandedGaps[file.path, default: []].insert(gap)
        hunkStarts[file.path] = file.hunks.map(\.newStart)
    }
}

/// `ALL-03`'s caption above the first file of each kind: "Uncommitted · 2", "Committed · 3" (`CHG-03`).
public struct AllChangesKindCaption: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case uncommitted, committed

        public var title: String {
            switch self {
            case .uncommitted: "Uncommitted"
            case .committed: "Committed"
            }
        }
    }

    public let kind: Kind
    public let count: Int

    public var id: String { "section|\(kind.rawValue)" }
}

/// `ALL-07`: what a file shows under its header in place of rows.
public enum AllChangesCaption: Equatable, Sendable {
    /// "Large diff · 3,214 lines" and Show.
    case large(lines: Int)
    /// "Binary file · 24 KB → 31 KB": the sizes are the view's to read.
    case binary
    /// "File mode changed 644 → 755".
    case modeOnly(ModeChange)
    /// "Renamed, no content changes".
    case renamed
    /// An added file with nothing in it.
    case emptyFile
}

/// One row under a file's header, in the order it is drawn. Its id is its file's path and its `DiffRow` id, so a file
/// added above changes no other id (`ALL-09`'s anchor).
public enum AllChangesRow: Identifiable, Equatable, Sendable {
    case line(path: String, DiffLine)
    case gap(path: String, DiffGap, count: Int)
    case caption(path: String, AllChangesCaption)
    /// `ALL-04`'s 8 points after a file's last row.
    case spacer(path: String)

    public var path: String {
        switch self {
        case .line(let path, _), .gap(let path, _, _), .caption(let path, _), .spacer(let path): path
        }
    }

    public var id: String {
        switch self {
        case .line(let path, let line): "\(path)|\(DiffRow.line(line).id)"
        case .gap(let path, let gap, let count): "\(path)|\(DiffRow.gap(gap, count: count).id)"
        case .caption(let path, _): "\(path)|caption"
        case .spacer(let path): "\(path)|spacer"
        }
    }
}

/// One file of the All changes tab: a pinned header (`ALL-03`) and its rows, with the kind's caption before it when it
/// is its kind's first file.
public struct AllChangesSection: Identifiable, Equatable, Sendable {
    public let file: FileDiff
    public let kindCaption: AllChangesKindCaption?
    public let isFolded: Bool
    /// Whether the header has a chevron: a binary file, a mode change alone, a rename without content changes and an
    /// empty file have nothing to fold, nor a large file until it is shown (`ALL-07`).
    public let canFold: Bool
    /// "New file", "Deleted", "Renamed from src/old/api.ts", "Mode 644 → 755"; nil for a plain modification.
    public let note: String?
    public let rows: [AllChangesRow]

    public var id: String { file.path }
    public var headerId: String { Self.headerId(of: file.path) }

    public static func headerId(of path: String) -> String { "\(path)|header" }
}

/// `KIT-21`: the All changes tab laid out, pure, on top of `DiffLayout`.
public enum AllChangesLayout {
    /// One section per file of `changes.listOrder`, Uncommitted then Committed. `newLines` holds the worktree lines of
    /// the files read so far: without them a file shows its hunks and the runs between them, as a diff tab does before
    /// its file is read.
    public static func sections(changes: WorkspaceChanges, state: AllChangesState, newLines: [String: [String]]) -> [AllChangesSection] {
        let uncommitted = changes.uncommitted
        let committed = changes.committed
        func captioned(_ files: [FileDiff], kind: AllChangesKindCaption.Kind) -> [AllChangesSection] {
            files.enumerated().map { index, file in
                section(
                    for: file,
                    kindCaption: index == 0 ? AllChangesKindCaption(kind: kind, count: files.count) : nil,
                    state: state,
                    newLines: newLines[file.path]
                )
            }
        }
        return captioned(uncommitted, kind: .uncommitted) + captioned(committed, kind: .committed)
    }

    static func section(for file: FileDiff, kindCaption: AllChangesKindCaption?, state: AllChangesState, newLines: [String]?) -> AllChangesSection {
        let path = file.path
        let caption = self.caption(for: file, shownLarge: state.shownLarge.contains(path))
        let canFold = caption == nil
        let isFolded = canFold && state.folded.contains(path)
        var rows: [AllChangesRow] = []
        if !isFolded {
            if let caption {
                rows.append(.caption(path: path, caption))
            } else {
                for row in DiffLayout.rows(for: file, newLines: newLines, expanded: state.expandedGaps[path] ?? []) {
                    switch row {
                    case .line(let line): rows.append(.line(path: path, line))
                    case .gap(let gap, let count): rows.append(.gap(path: path, gap, count: count))
                    }
                }
            }
            rows.append(.spacer(path: path))
        }
        return AllChangesSection(file: file, kindCaption: kindCaption, isFolded: isFolded, canFold: canFold, note: note(for: file), rows: rows)
    }

    /// `ALL-07`'s caption, or nil when the file shows rows.
    static func caption(for file: FileDiff, shownLarge: Bool) -> AllChangesCaption? {
        if file.isBinary { return .binary }
        if file.isLarge, !shownLarge { return .large(lines: file.changedLineCount) }
        guard file.hunks.isEmpty else { return nil }
        // An untracked file over 1 MB has no hunks: once shown, its lines are its rows.
        if file.status == .added, file.isLarge { return nil }
        if let modeChange = file.modeChange { return .modeOnly(modeChange) }
        if file.oldPath != nil { return .renamed }
        return .emptyFile
    }

    /// The header's note (`ALL-03`, `ALL-07`).
    static func note(for file: FileDiff) -> String? {
        if let oldPath = file.oldPath { return "Renamed from \(oldPath)" }
        switch file.status {
        case .added: return "New file"
        case .deleted: return "Deleted"
        default: break
        }
        if let modeChange = file.modeChange, !file.hunks.isEmpty {
            return "Mode \(modeChange.old.suffix(3)) → \(modeChange.new.suffix(3))"
        }
        return nil
    }

    /// `ALL-09`: the row to keep at the top after an update, for the one that was there, `id`. It is the same row when
    /// it is still there. A line that is gone gives the same file's nearest line; a file that is gone, the header of
    /// the next file of `previousPaths` still listed, else the last file. nil with no files.
    public static func anchor(in sections: [AllChangesSection], was id: String, previousPaths: [String]) -> String? {
        guard !sections.isEmpty else { return nil }
        if sections.contains(where: { $0.headerId == id || $0.kindCaption?.id == id || $0.rows.contains { $0.id == id } }) {
            return id
        }
        guard let bar = id.range(of: "|", options: .backwards) else { return sections.first?.headerId }
        let path = String(id[..<bar.lowerBound])
        if let section = sections.first(where: { $0.file.path == path }) {
            guard let number = lineNumber(in: String(id[bar.upperBound...])) else { return section.headerId }
            let nearest = section.rows.compactMap { row -> (id: String, distance: Int)? in
                guard case .line(_, let line) = row, let own = line.newNumber ?? line.oldNumber else { return nil }
                return (row.id, abs(own - number))
            }.min { $0.distance < $1.distance }
            return nearest?.id ?? section.headerId
        }
        let listed = Set(sections.map(\.file.path))
        if let index = previousPaths.firstIndex(of: path),
           let next = previousPaths[(index + 1)...].first(where: listed.contains) {
            return AllChangesSection.headerId(of: next)
        }
        return sections.last?.headerId
    }

    /// The line a row id's `DiffRow` part names: "l12:14" is new line 14, "l12:0" old line 12.
    private static func lineNumber(in rowId: String) -> Int? {
        guard rowId.hasPrefix("l") else { return nil }
        let parts = rowId.dropFirst().split(separator: ":")
        guard parts.count == 2, let old = Int(parts[0]), let new = Int(parts[1]) else { return nil }
        return new > 0 ? new : old
    }
}
