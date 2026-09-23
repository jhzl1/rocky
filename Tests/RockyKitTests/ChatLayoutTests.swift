import Foundation
import Testing
@testable import RockyKit

struct ChatLayoutTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func kinds(_ rows: [ChatRow]) -> [String] {
        rows.map { row in
            switch row {
            case .item(let item): item.kind.rawValue
            case .tools(let tools): "tools(\(tools.count))"
            case .turnFooter: "footer"
            }
        }
    }

    @Test func foldsConsecutiveToolCallsAndKeepsALoneOne() {
        let items = [
            ChatItem(kind: .user, text: "hi"),
            ChatItem(kind: .tool, text: "Read a.swift"),
            ChatItem(kind: .tool, text: "Read b.swift"),
            ChatItem(kind: .agent, text: "Done"),
            ChatItem(kind: .tool, text: "Run tests"),
        ]
        #expect(kinds(ChatLayout.rows(items)) == ["user", "tools(2)", "agent", "tool"])
    }

    @Test func endsEachFinishedTurnWithAFooter() {
        let first = ChatItem(kind: .user, text: "one", createdAt: start, completedAt: start.addingTimeInterval(328))
        let second = ChatItem(kind: .user, text: "two", createdAt: start.addingTimeInterval(400))
        let items = [
            first,
            ChatItem(kind: .agent, text: "Hello"),
            ChatItem(kind: .tool, text: "Run ls"),
            ChatItem(kind: .agent, text: "world"),
            second,
            ChatItem(kind: .agent, text: "still working"),
        ]
        let rows = ChatLayout.rows(items)
        #expect(kinds(rows) == ["user", "agent", "tool", "agent", "footer", "user", "agent"])
        #expect(rows[4] == .turnFooter(TurnSummary(
            id: first.id,
            startedAt: start,
            completedAt: start.addingTimeInterval(328),
            agentText: "Hello\n\nworld"
        )))
    }
}
