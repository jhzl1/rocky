import Foundation
import Testing
@testable import RockyKit

/// MOT-02: which chat rows enter with an animation. ChatView settles every key it finds when a conversation opens;
/// only rows whose key is not settled animate.
struct ChatEntranceTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func historyIsSettled() {
        let items = [
            ChatItem(kind: .user, text: "hi", createdAt: start, completedAt: start.addingTimeInterval(5)),
            ChatItem(kind: .agent, text: "Hello"),
            ChatItem(kind: .tool, text: "Read a"),
            ChatItem(kind: .tool, text: "Read b"),
        ]
        let settled = Set(ChatLayout.rows(items).map(\.entranceKey))
        #expect(ChatLayout.rows(items).allSatisfy { settled.contains($0.entranceKey) })
    }

    @Test func aNewUserMessageIsNew() {
        let history = [ChatItem(kind: .user, text: "hi"), ChatItem(kind: .agent, text: "Hello")]
        let settled = Set(ChatLayout.rows(history).map(\.entranceKey))
        let sent = ChatItem(kind: .user, text: "again")
        let fresh = ChatLayout.rows(history + [sent]).filter { !settled.contains($0.entranceKey) }
        #expect(fresh.map(\.entranceKey) == [sent.id.uuidString])
    }

    @Test func aToolRowJoiningAGroupKeepsItsKey() {
        let t1 = ChatItem(kind: .tool, text: "Read a")
        let t2 = ChatItem(kind: .tool, text: "Read b")
        let lone = ChatLayout.rows([t1])
        let grouped = ChatLayout.rows([t1, t2])
        #expect(lone.count == 1 && grouped.count == 1)
        #expect(lone[0].id != grouped[0].id)
        #expect(lone[0].entranceKey == grouped[0].entranceKey)
    }

    @Test func theFooterHasItsOwnKey() {
        let user = ChatItem(kind: .user, text: "hi", createdAt: start, completedAt: start.addingTimeInterval(3))
        let rows = ChatLayout.rows([user, ChatItem(kind: .agent, text: "Hello")])
        let footer = rows.last
        #expect(footer?.entranceKey == "footer-\(user.id.uuidString)")
        #expect(footer?.entranceKey != rows.first?.entranceKey)
    }
}
