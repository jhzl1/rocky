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
