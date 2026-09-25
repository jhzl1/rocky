import Testing
@testable import RockyKit

struct MessageHistoryTests {
    private let first = MessageHistory.Entry(text: "hola", files: [])
    private let second = MessageHistory.Entry(text: "mira \(PromptAttachment.marker) esto", files: ["/tmp/a.png"])

    @Test func upFromAnEmptyBoxWalksBackAndDownWalksForwardToEmpty() {
        var history = MessageHistory(entries: [first, second])
        #expect(history.older(from: "") == .show(second))
        history.didShow(second.text)
        #expect(history.older(from: second.text) == .show(first))
        history.didShow(first.text)
        #expect(history.older(from: first.text) == .stay)
        #expect(history.newer(from: first.text) == .show(second))
        history.didShow(second.text)
        #expect(history.newer(from: second.text) == .clear)
        #expect(history.newer(from: "") == nil)
    }

    @Test func anEditedEntryLetsTheArrowsMoveTheCursor() {
        var history = MessageHistory(entries: [first, second])
        #expect(history.older(from: "") == .show(second))
        history.didShow(second.text)
        #expect(history.older(from: second.text + "!") == nil)
        #expect(history.newer(from: second.text + "!") == nil)
        #expect(history.older(from: "typing") == nil)
    }

    /// CMT-05 History: ↑ stops on a line comment, with its range for the chip, instead of going past it to an older
    /// message (user decision, 2026-09-25).
    @Test func upStopsOnALineComment() {
        let range = LineRangeAttachment(path: "/tmp/app-worktrees/tokyo/src/a.ts", side: .old, start: 12, end: 13)
        let comment = MessageHistory.Entry(text: "Why drop the retry?", files: [], lineRange: range)
        var history = MessageHistory(entries: [first, comment])
        #expect(history.older(from: "") == .show(comment))
        history.didShow(PromptAttachment.marker + comment.text)
        #expect(history.older(from: PromptAttachment.marker + comment.text) == .show(first))
        history.didShow(first.text)
        #expect(history.newer(from: first.text) == .show(comment))
    }

    /// The history is the user's messages, oldest first: a line comment keeps its range and the files after it, and a
    /// message with files keeps them all.
    @Test func historyEntriesKeepTheirLineRange() {
        let range = LineRangeAttachment(path: "/tmp/app-worktrees/tokyo/src/a.ts", side: .new, start: 18, end: 25)
        let items = [
            ChatItem(kind: .user, text: "hola"),
            ChatItem(kind: .agent, text: "Hi"),
            ChatItem(kind: .tool, text: "Read a.ts", attachments: [range.entry]),
            ChatItem(kind: .user, text: "Keep it?", attachments: [range.entry]),
            ChatItem(kind: .user, text: "Like \(PromptAttachment.marker)?", attachments: [range.entry, "/tmp/shot.png"]),
            ChatItem(kind: .user, text: second.text, attachments: second.files),
        ]
        #expect(MessageHistory.entries(from: items) == [
            first,
            MessageHistory.Entry(text: "Keep it?", files: [], lineRange: range),
            MessageHistory.Entry(text: "Like \(PromptAttachment.marker)?", files: ["/tmp/shot.png"], lineRange: range),
            second,
        ])
    }

    @Test func aNewMessageStartsOverFromTheNewest() {
        var history = MessageHistory(entries: [first])
        #expect(history.older(from: "") == .show(first))
        history.didShow(first.text)
        history.setEntries([first, second])
        #expect(history.older(from: "") == .show(second))
        var empty = MessageHistory()
        #expect(empty.older(from: "") == nil)
    }
}
