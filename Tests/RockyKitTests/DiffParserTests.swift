import Foundation
import Testing
@testable import RockyKit

/// `GIT-02` on patches as `git diff --no-color --no-ext-diff --find-renames -U3 --src-prefix=a/ --dst-prefix=b/`
/// prints them.
struct DiffParserTests {
    @Test func modifiedFileWithTwoHunks() throws {
        let patch = """
            diff --git a/src/openapi.ts b/src/openapi.ts
            index 1111111..2222222 100644
            --- a/src/openapi.ts
            +++ b/src/openapi.ts
            @@ -1,4 +1,4 @@ import
             import { Route } from "./route";
            -const version = 1;
            +const version = 2;
            \u{20}
             export {};
            @@ -40,2 +40,4 @@ function operation(route: Route) {
               const id = route.name;
            +  const unique = true;
            +  return { id, unique };
               return { id };
            """
        let files = DiffParser.parse(patch + "\n")
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.path == "src/openapi.ts")
        #expect(file.status == .modified)
        #expect(file.status.letter == "M")
        #expect(!file.isBinary)
        #expect(file.modeChange == nil)
        #expect(file.additions == 3)
        #expect(file.deletions == 1)
        #expect(!file.isLarge)
        #expect(file.hunks.count == 2)

        let first = file.hunks[0]
        #expect(first.header == "@@ -1,4 +1,4 @@ import")
        #expect((first.oldStart, first.oldCount, first.newStart, first.newCount) == (1, 4, 1, 4))
        #expect(first.lines == [
            DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: #"import { Route } from "./route";"#),
            DiffLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "const version = 1;"),
            DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "const version = 2;"),
            // An empty context line is a lone space in the patch.
            DiffLine(kind: .context, oldNumber: 3, newNumber: 3, text: ""),
            DiffLine(kind: .context, oldNumber: 4, newNumber: 4, text: "export {};"),
        ])
        #expect(first.noNewlineAtEnd == NoNewlineAtEnd())

        let second = file.hunks[1]
        #expect((second.oldStart, second.oldCount, second.newStart, second.newCount) == (40, 2, 40, 4))
        #expect(second.lines.map(\.newNumber) == [40, 41, 42, 43])
        #expect(second.lines.map(\.oldNumber) == [40, nil, nil, 41])
        #expect(second.lines.last?.text == "  return { id };")
    }

    @Test func addedFile() throws {
        let patch = """
            diff --git a/src/retry.ts b/src/retry.ts
            new file mode 100644
            index 0000000..3333333
            --- /dev/null
            +++ b/src/retry.ts
            @@ -0,0 +1,2 @@
            +export const attempts = 3;
            +export const delay = 250;

            """
        let file = try #require(DiffParser.parse(patch).first)
        #expect(file.path == "src/retry.ts")
        #expect(file.status == .added)
        #expect(file.additions == 2)
        #expect(file.deletions == 0)
        #expect(file.modeChange == nil)
        #expect(file.hunks.first?.lines.map(\.newNumber) == [1, 2])
        #expect(file.hunks.first?.lines.allSatisfy { $0.kind == .added && $0.oldNumber == nil } == true)
    }

    @Test func deletedFile() throws {
        let patch = """
            diff --git a/old/legacy.swift b/old/legacy.swift
            deleted file mode 100644
            index 4444444..0000000
            --- a/old/legacy.swift
            +++ /dev/null
            @@ -1,3 +0,0 @@
            -import Foundation
            -
            -struct Legacy {}

            """
        let file = try #require(DiffParser.parse(patch).first)
        #expect(file.path == "old/legacy.swift")
        #expect(file.status == .deleted)
        #expect(file.status.letter == "D")
        #expect(file.deletions == 3)
        #expect(file.additions == 0)
        #expect(file.hunks.first?.lines.map(\.oldNumber) == [1, 2, 3])
    }

    @Test func renamedWithSimilarity() throws {
        let patch = """
            diff --git a/src/api/old name.ts b/src/api/new name.ts
            similarity index 90%
            rename from src/api/old name.ts
            rename to src/api/new name.ts
            index 5555555..6666666 100644
            --- a/src/api/old name.ts\t
            +++ b/src/api/new name.ts\t
            @@ -1,2 +1,2 @@
            -export const name = "old";
            +export const name = "new";
             export default name;

            """
        let file = try #require(DiffParser.parse(patch).first)
        #expect(file.path == "src/api/new name.ts")
        #expect(file.status == .renamed(from: "src/api/old name.ts"))
        #expect(file.oldPath == "src/api/old name.ts")
        #expect(file.status.letter == "R")
        #expect(file.additions == 1)
        #expect(file.deletions == 1)
    }

    /// A rename with no content change has no hunks.
    @Test func pureRenameHasNoRows() throws {
        let patch = """
            diff --git a/a.txt b/b.txt
            similarity index 100%
            rename from a.txt
            rename to b.txt

            """
        let file = try #require(DiffParser.parse(patch).first)
        #expect(file.path == "b.txt")
        #expect(file.status == .renamed(from: "a.txt"))
        #expect(file.hunks.isEmpty)
    }

    @Test func binaryFile() throws {
        let patch = """
            diff --git a/assets/logo b.png b/assets/logo b.png
            index 7777777..8888888 100644
            Binary files a/assets/logo b.png and b/assets/logo b.png differ
            diff --git a/assets/new.png b/assets/new.png
            new file mode 100644
            index 0000000..9999999
            Binary files /dev/null and b/assets/new.png differ

            """
        let files = DiffParser.parse(patch)
        #expect(files.map(\.path) == ["assets/logo b.png", "assets/new.png"])
        #expect(files.map(\.status) == [.modified, .added])
        #expect(files.allSatisfy { $0.isBinary && $0.hunks.isEmpty && $0.additions == 0 })
    }

    @Test func modeOnly() throws {
        let patch = """
            diff --git a/scripts/make-app.sh b/scripts/make-app.sh
            old mode 100644
            new mode 100755

            """
        let file = try #require(DiffParser.parse(patch).first)
        #expect(file.path == "scripts/make-app.sh")
        #expect(file.status == .modified)
        #expect(file.modeChange == ModeChange(old: "100644", new: "100755"))
        #expect(file.hunks.isEmpty)
    }

    @Test func noNewlineAtEndOnEachSide() throws {
        let patch = """
            diff --git a/one.txt b/one.txt
            index 1..2 100644
            --- a/one.txt
            +++ b/one.txt
            @@ -1 +1 @@
            -old
            \\ No newline at end of file
            +new
            diff --git a/two.txt b/two.txt
            index 3..4 100644
            --- a/two.txt
            +++ b/two.txt
            @@ -1 +1 @@
            -old
            +new
            \\ No newline at end of file
            diff --git a/three.txt b/three.txt
            index 5..6 100644
            --- a/three.txt
            +++ b/three.txt
            @@ -1,2 +1,2 @@
            -first
            +First
             last
            \\ No newline at end of file

            """
        let files = DiffParser.parse(patch)
        #expect(files.map(\.path) == ["one.txt", "two.txt", "three.txt"])
        #expect(files[0].hunks.first?.noNewlineAtEnd == NoNewlineAtEnd(old: true, new: false))
        #expect(files[1].hunks.first?.noNewlineAtEnd == NoNewlineAtEnd(old: false, new: true))
        #expect(files[2].hunks.first?.noNewlineAtEnd == NoNewlineAtEnd(old: true, new: true))
        #expect(files[0].hunks.first?.lines.map(\.text) == ["old", "new"])
        #expect(files[2].hunks.first?.lines.last == DiffLine(kind: .context, oldNumber: 2, newNumber: 2, text: "last"))
    }

    /// Swift reads "\r\n" as one character; the lines of a CRLF file still split, and keep their "\r".
    @Test func crlfLinesSplitAndKeepTheirCarriageReturn() throws {
        let patch = "diff --git a/w.bat b/w.bat\n--- a/w.bat\n+++ b/w.bat\n@@ -1,2 +1,2 @@\n-echo old\r\n+echo new\r\n rem end\r\n"
        let file = try #require(DiffParser.parse(patch).first)
        #expect(file.hunks.first?.lines.map(\.text) == ["echo old\r", "echo new\r", "rem end\r"])
    }

    @Test func quotedPathsAreUnquoted() throws {
        let patch = """
            diff --git "a/docs/tab\\there.md" "b/docs/tab\\there.md"
            --- "a/docs/tab\\there.md"
            +++ "b/docs/tab\\there.md"
            @@ -1 +1 @@
            -a
            +b

            """
        let file = try #require(DiffParser.parse(patch).first)
        #expect(file.path == "docs/tab\there.md")
        #expect(DiffParser.unquote("\"caf\\303\\251.txt\"") == "café.txt")
    }

    /// `DIFF-03`: over 1,500 changed lines.
    @Test func manyChangedLinesAreLarge() throws {
        let added = (1...1_501).map { "+line \($0)" }.joined(separator: "\n")
        let patch = "diff --git a/big.txt b/big.txt\nnew file mode 100644\n--- /dev/null\n+++ b/big.txt\n@@ -0,0 +1,1501 @@\n\(added)\n"
        let file = try #require(DiffParser.parse(patch).first)
        #expect(file.additions == 1_501)
        #expect(file.isLarge)
    }

    @Test func diffStatAbbreviatesThousands() {
        #expect(DiffStat.abbreviated(999) == "999")
        #expect(DiffStat.abbreviated(1_000) == "1k")
        #expect(DiffStat.abbreviated(2_340) == "2.3k")
        #expect(DiffStat.abbreviated(12_000) == "12k")
    }

    /// `CHG-03`: Uncommitted first, then Committed; ⌥⌘↓ / ⌥⌘↑ walk that order and stop at its ends.
    @Test func listOrderPutsUncommittedFirst() {
        let changes = WorkspaceChanges(base: "abc", files: [
            FileDiff(path: "a.ts", status: .modified, additions: 1),
            FileDiff(path: "b.ts", status: .added, additions: 2, isUncommitted: true),
            FileDiff(path: "c.ts", status: .deleted, deletions: 4),
            FileDiff(path: "d.ts", status: .modified, deletions: 1, isUncommitted: true),
        ])
        #expect(changes.additions == 3)
        #expect(changes.deletions == 5)
        #expect(changes.listOrder.map(\.path) == ["b.ts", "d.ts", "a.ts", "c.ts"])
        #expect(changes.file(after: nil, step: 1)?.path == "b.ts")
        #expect(changes.file(after: nil, step: -1)?.path == "c.ts")
        #expect(changes.file(after: "d.ts", step: 1)?.path == "a.ts")
        #expect(changes.file(after: "b.ts", step: -1) == nil)
        #expect(changes.file(after: "c.ts", step: 1) == nil)
    }
}
