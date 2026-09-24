import Foundation
import Testing
@testable import RockyKit

/// `EDIT-01`'s Tab: the indentation a file already uses.
struct IndentationTests {
    @Test func tabsAreDetected() {
        #expect(Indentation.detect(in: "func main() {\n\tif ok {\n\t\trun()\n\t}\n}\n") == "\t")
    }

    @Test func theCommonStepOfSpacesIsDetected() {
        #expect(Indentation.detect(in: "a:\n  b:\n    c: 1\n  d: 2\n") == "  ")
        #expect(Indentation.detect(in: "class A:\n    def b(self):\n        pass\n    x = 1\n") == "    ")
        #expect(Indentation.detect(in: "a {\r\n    b\r\n}\r\n") == "    ")
    }

    @Test func nothingIndentedIsNil() {
        #expect(Indentation.detect(in: "one\ntwo\n\nthree\n") == nil)
        #expect(Indentation.detect(in: "") == nil)
    }

    /// A block comment's " * " lines step by one space; the code's own step wins.
    @Test func aBlockCommentDoesNotMakeItOneSpace() {
        let text = "/**\n * Runs.\n * Twice.\n */\nfunction run() {\n  one()\n  if (again) {\n    two()\n  }\n}\n"
        #expect(Indentation.detect(in: text) == "  ")
    }
}

/// The editor's line numbers (`EDIT-01`), in UTF-16 offsets as the text view counts.
struct LineStartsTests {
    @Test func crlfIsOneBreakAndALoneCarriageReturnIsOne() {
        #expect(LineStarts.of("a\nb\r\nc\rd") == [0, 2, 5, 7])
    }

    @Test func aFinalNewlineStartsAnEmptyLine() {
        #expect(LineStarts.of("a\n") == [0, 2])
        #expect(LineStarts.of("") == [0])
    }

    @Test func offsetsAreUTF16Units() {
        // "é" is one unit, the emoji two.
        #expect(LineStarts.of("é😀\nx") == [0, 4])
    }

    @Test func aLineIsTheLastStartAtOrBeforeTheOffset() {
        let starts = [0, 2, 5]
        #expect(LineStarts.line(containing: 0, in: starts) == 0)
        #expect(LineStarts.line(containing: 1, in: starts) == 0)
        #expect(LineStarts.line(containing: 2, in: starts) == 1)
        #expect(LineStarts.line(containing: 4, in: starts) == 1)
        #expect(LineStarts.line(containing: 99, in: starts) == 2)
    }
}

/// `EDIT-04`'s change bars against the base, as the design's mock marks them.
struct ChangeBarsTests {
    private let base = "one\ntwo\nthree\nfour\n"

    @Test func anUnchangedTextHasNoBars() {
        #expect(ChangeBars.compute(base: base, text: base) == ChangeBars())
    }

    @Test func anInsertedLineIsAdded() {
        #expect(ChangeBars.compute(base: base, text: "one\ntwo\nnew\nthree\nfour\n") == ChangeBars(marks: [2: .added]))
    }

    @Test func aReplacedLineIsModified() {
        #expect(ChangeBars.compute(base: base, text: "one\nTWO\nthree\nfour\n") == ChangeBars(marks: [1: .modified]))
    }

    /// The triangle goes on the edge above the line that follows the removed ones, or at the end.
    @Test func removedLinesMarkTheLineBelowThemOrTheEnd() {
        #expect(ChangeBars.compute(base: base, text: "one\nfour\n") == ChangeBars(deletionsAbove: [1]))
        #expect(ChangeBars.compute(base: base, text: "one\ntwo\n") == ChangeBars(deletionAtEnd: true))
        #expect(ChangeBars.compute(base: "a\nb\n", text: "") == ChangeBars(deletionAtEnd: true))
    }

    /// Two lines replaced by one: the one is modified, and the other removal marks the line after it.
    @Test func fewerLinesInPlaceOfMoreAreModifiedThenMarked() {
        #expect(ChangeBars.compute(base: base, text: "one\nTWO\nfour\n") == ChangeBars(marks: [1: .modified], deletionsAbove: [2]))
    }

    @Test func aFileTheBaseLacksIsAllAdded() {
        #expect(ChangeBars.compute(base: "", text: "a\nb\n") == ChangeBars(marks: [0: .added, 1: .added]))
    }

    /// Two long unrelated middles are not diffed: every line between them is modified.
    @Test func pastTheDiffLimitTheMiddleIsModified() {
        let old = (0..<1_500).map { "old \($0)" }
        let new = (0..<1_500).map { "new \($0)" }
        let bars = ChangeBars.compute(base: ["same"] + old, text: ["same"] + new)
        #expect(bars.marks.count == 1_500)
        #expect(bars.marks[0] == nil)
        #expect(bars.marks.values.allSatisfy { $0 == .modified })
    }
}
