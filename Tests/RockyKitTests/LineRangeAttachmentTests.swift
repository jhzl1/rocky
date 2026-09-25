import Foundation
import Testing
@testable import RockyKit

/// CMT-05, CMT-06: a line comment's entry is its file's absolute path with a `#L` or `#base-L` fragment, parsed back
/// from the message's attachments, and shown as the chip's range.
struct LineRangeAttachmentTests {
    private static let path = "/Users/me/app-worktrees/tokyo/src/openapi.ts"

    @Test func roundTripsBothSidesAndOneLine() throws {
        let new = LineRangeAttachment(path: Self.path, side: .new, start: 18, end: 25)
        #expect(new.entry == Self.path + "#L18-25")
        #expect(LineRangeAttachment(entry: new.entry) == new)

        let removed = LineRangeAttachment(path: Self.path, side: .old, start: 12, end: 13)
        #expect(removed.entry == Self.path + "#base-L12-13")
        #expect(LineRangeAttachment(entry: removed.entry) == removed)

        let one = LineRangeAttachment(path: Self.path, side: .new, start: 18, end: 18)
        #expect(one.entry == Self.path + "#L18")
        #expect(LineRangeAttachment(entry: one.entry) == one)
        let oneRemoved = try #require(LineRangeAttachment(entry: Self.path + "#base-L7"))
        #expect(oneRemoved == LineRangeAttachment(path: Self.path, side: .old, start: 7, end: 7))
    }

    /// The last "#" starts the fragment, so a folder with one in its name keeps it.
    @Test func theLastFragmentCounts() {
        #expect(LineRangeAttachment(entry: "/tmp/a#b/c.ts#L3") == LineRangeAttachment(path: "/tmp/a#b/c.ts", side: .new, start: 3, end: 3))
    }

    @Test func rejectsPlainPathsAndMalformedFragments() {
        #expect(LineRangeAttachment(entry: Self.path) == nil)
        #expect(LineRangeAttachment(entry: "/tmp/shot.png") == nil)
        for fragment in ["", "L", "L0", "Lx", "L-5", "L5-", "L5-3", "L1-2-3", "L2 ", "L١", "base-", "base-L", "l5", "M5", "base-L0-2", "L+5"] {
            #expect(LineRangeAttachment(entry: Self.path + "#" + fragment) == nil, "#\(fragment)")
        }
        #expect(LineRangeAttachment(entry: "#L5") == nil)
    }

    /// CMT-06's range text after the file's name.
    @Test func rangeLabelNamesTheSide() {
        #expect(LineRangeAttachment(path: Self.path, side: .new, start: 18, end: 25).rangeLabel == "+18–25")
        #expect(LineRangeAttachment(path: Self.path, side: .old, start: 12, end: 13).rangeLabel == "−12–13")
        #expect(LineRangeAttachment(path: Self.path, side: .new, start: 18, end: 18).rangeLabel == "+18")
    }

    /// Only a user message whose first attachment is an entry, and no other one, is a line comment; the files after the
    /// entry are the ones attached next to its chip (CMT-05 Resend). Files and tool calls are not.
    @Test func aUserMessageStartingWithOneEntryIsALineComment() {
        let entry = Self.path + "#L18-25"
        #expect(ChatItem(kind: .user, text: "Why?", attachments: [entry]).lineRange?.start == 18)
        #expect(ChatItem(kind: .user, text: "Why?", attachments: [entry]).attachedFiles.isEmpty)
        let withFile = ChatItem(kind: .user, text: "Like \(PromptAttachment.marker)?", attachments: [entry, "/tmp/shot.png"])
        #expect(withFile.lineRange?.start == 18)
        #expect(withFile.attachedFiles == ["/tmp/shot.png"])
        let plain = ChatItem(kind: .user, text: "look", attachments: ["/tmp/shot.png"])
        #expect(plain.lineRange == nil)
        #expect(plain.attachedFiles == ["/tmp/shot.png"])
        #expect(ChatItem(kind: .user, text: "look", attachments: ["/tmp/shot.png", entry]).lineRange == nil)
        #expect(ChatItem(kind: .user, text: "both", attachments: [entry, entry]).lineRange == nil)
        #expect(ChatItem(kind: .tool, text: "Read openapi.ts", attachments: [entry]).lineRange == nil)
    }
}
