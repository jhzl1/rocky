import Foundation
import Testing
@testable import RockyKit

/// `KIT-21`: the All changes tab's sections, folding, captions, notes and the scroll anchor (`ALL-03`…`ALL-09`).
struct AllChangesLayoutTests {
    /// A file with one hunk at new line `start`: a context line, an added one, a context one.
    private static func changed(_ path: String, at start: Int = 10, uncommitted: Bool = true, status: FileDiff.Status = .modified) -> FileDiff {
        FileDiff(
            path: path,
            status: status,
            hunks: [
                Hunk(header: "@@ -\(start),2 +\(start),3 @@", oldStart: start, oldCount: 2, newStart: start, newCount: 3, lines: [
                    DiffLine(kind: .context, oldNumber: start, newNumber: start, text: "a"),
                    DiffLine(kind: .added, oldNumber: nil, newNumber: start + 1, text: "b"),
                    DiffLine(kind: .context, oldNumber: start + 1, newNumber: start + 2, text: "c"),
                ]),
            ],
            additions: 1,
            isUncommitted: uncommitted
        )
    }

    private static func changes(_ files: [FileDiff]) -> WorkspaceChanges {
        WorkspaceChanges(base: "abc", files: files)
    }

    @Test func uncommittedThenCommittedWithTheirCounts() {
        let changes = Self.changes([
            Self.changed("b.ts", uncommitted: false),
            Self.changed("a.ts"),
            Self.changed("c.ts", uncommitted: false),
        ])
        let sections = AllChangesLayout.sections(changes: changes, state: AllChangesState(), newLines: [:])
        #expect(sections.map(\.file.path) == ["a.ts", "b.ts", "c.ts"])
        #expect(sections.map(\.kindCaption) == [
            AllChangesKindCaption(kind: .uncommitted, count: 1),
            AllChangesKindCaption(kind: .committed, count: 2),
            nil,
        ])
        // An empty kind is left out.
        let onlyCommitted = AllChangesLayout.sections(changes: Self.changes([Self.changed("b.ts", uncommitted: false)]), state: AllChangesState(), newLines: [:])
        #expect(onlyCommitted.map(\.kindCaption?.kind) == [.committed])
    }

    @Test func aFoldedFileGivesItsHeaderOnly() {
        var state = AllChangesState()
        state.folded = ["a.ts"]
        let sections = AllChangesLayout.sections(changes: Self.changes([Self.changed("a.ts"), Self.changed("b.ts")]), state: state, newLines: [:])
        #expect(sections[0].isFolded)
        #expect(sections[0].rows.isEmpty)
        #expect(!sections[1].isFolded)
        // The run above the hunk, its three lines, then the space before the next file; without the worktree file the
        // run after the last hunk is left out, as in a diff tab.
        #expect(sections[1].rows.map(\.id) == ["b.ts|g0", "b.ts|l10:10", "b.ts|l0:11", "b.ts|l11:12", "b.ts|spacer"])
    }

    /// DIFF-03's cases under the header, and the notes (`ALL-07`).
    @Test func captionsAndNotes() {
        var large = Self.changed("big.ts")
        large.isLarge = true
        large.additions = 3_214
        let binary = FileDiff(path: "logo.png", status: .modified, isBinary: true)
        let mode = FileDiff(path: "run.sh", status: .modified, modeChange: ModeChange(old: "100644", new: "100755"))
        var modeAndContent = Self.changed("tool.sh")
        modeAndContent.modeChange = ModeChange(old: "100644", new: "100755")
        let renamed = FileDiff(path: "src/api.ts", status: .renamed(from: "src/old/api.ts"))
        let added = Self.changed("new.ts", status: .added)
        let deleted = Self.changed("gone.ts", status: .deleted)

        var state = AllChangesState()
        let sections = AllChangesLayout.sections(
            changes: Self.changes([large, binary, mode, modeAndContent, renamed, added, deleted]),
            state: state,
            newLines: [:]
        )
        let byPath = Dictionary(uniqueKeysWithValues: sections.map { ($0.file.path, $0) })
        #expect(byPath["big.ts"]?.rows.first == .caption(path: "big.ts", .large(lines: 3_214)))
        #expect(byPath["big.ts"]?.canFold == false)
        #expect(byPath["logo.png"]?.rows.first == .caption(path: "logo.png", .binary))
        #expect(byPath["run.sh"]?.rows.first == .caption(path: "run.sh", .modeOnly(ModeChange(old: "100644", new: "100755"))))
        #expect(byPath["src/api.ts"]?.rows.first == .caption(path: "src/api.ts", .renamed))
        #expect(byPath["src/api.ts"]?.note == "Renamed from src/old/api.ts")
        #expect(byPath["tool.sh"]?.note == "Mode 644 → 755")
        #expect(byPath["tool.sh"]?.canFold == true)
        #expect(byPath["new.ts"]?.note == "New file")
        #expect(byPath["gone.ts"]?.note == "Deleted")
        #expect(byPath["logo.png"]?.canFold == false)

        // Shown, a large file has rows and a chevron.
        state.shownLarge = ["big.ts"]
        let shown = AllChangesLayout.sections(changes: Self.changes([large]), state: state, newLines: [:])
        #expect(shown[0].canFold)
        #expect(shown[0].rows.contains { if case .line = $0 { true } else { false } })
    }

    /// `ALL-09`: a file added above changes no other id, and an anchor that is gone falls back.
    @Test func idsStayWhenAFileIsAddedAboveAndTheAnchorFallsBack() {
        let before = AllChangesLayout.sections(changes: Self.changes([Self.changed("b.ts"), Self.changed("c.ts")]), state: AllChangesState(), newLines: [:])
        let after = AllChangesLayout.sections(changes: Self.changes([Self.changed("a.ts"), Self.changed("b.ts"), Self.changed("c.ts")]), state: AllChangesState(), newLines: [:])
        let idsOf = { (sections: [AllChangesSection], path: String) in
            sections.first { $0.file.path == path }.map { [$0.headerId] + $0.rows.map(\.id) }
        }
        #expect(idsOf(before, "b.ts") == idsOf(after, "b.ts"))
        #expect(idsOf(before, "c.ts") == idsOf(after, "c.ts"))
        let previous = before.map(\.file.path)

        // Still there: the same row.
        #expect(AllChangesLayout.anchor(in: after, was: "c.ts|l0:11", previousPaths: previous) == "c.ts|l0:11")
        // The hunk moved to line 40: the same file's nearest line.
        let moved = AllChangesLayout.sections(changes: Self.changes([Self.changed("b.ts"), Self.changed("c.ts", at: 40)]), state: AllChangesState(), newLines: [:])
        #expect(AllChangesLayout.anchor(in: moved, was: "c.ts|l0:11", previousPaths: previous) == "c.ts|l40:40")
        // The file is gone: the next file's header in the previous order, else the last file.
        let withoutB = AllChangesLayout.sections(changes: Self.changes([Self.changed("c.ts")]), state: AllChangesState(), newLines: [:])
        #expect(AllChangesLayout.anchor(in: withoutB, was: "b.ts|l0:11", previousPaths: previous) == "c.ts|header")
        let onlyB = AllChangesLayout.sections(changes: Self.changes([Self.changed("b.ts")]), state: AllChangesState(), newLines: [:])
        #expect(AllChangesLayout.anchor(in: onlyB, was: "c.ts|header", previousPaths: previous) == "b.ts|header")
        #expect(AllChangesLayout.anchor(in: [], was: "c.ts|header", previousPaths: previous) == nil)
    }

    /// `ALL-05`: a file that leaves the list comes back unfolded, and one whose hunks moved loses its expanded runs.
    @Test func reconciledForgetsGoneFilesAndMovedRuns() {
        let a = Self.changed("a.ts")
        let b = Self.changed("b.ts")
        var state = AllChangesState()
        state.folded = ["a.ts", "b.ts"]
        state.shownLarge = ["b.ts"]
        state.current = "b.ts"
        state.expand(DiffGap(hunkIndex: 0), of: a)
        state.expand(DiffGap(hunkIndex: 1), of: b)

        let next = state.reconciled(with: Self.changes([a, Self.changed("b.ts", at: 30)]))
        #expect(next.folded == ["a.ts", "b.ts"])
        #expect(next.expandedGaps == ["a.ts": [DiffGap(hunkIndex: 0)]])

        let gone = state.reconciled(with: Self.changes([a]))
        #expect(gone.folded == ["a.ts"])
        #expect(gone.shownLarge.isEmpty)
        #expect(gone.current == nil)
        #expect(gone.expandedGaps.keys.sorted() == ["a.ts"])
    }
}
