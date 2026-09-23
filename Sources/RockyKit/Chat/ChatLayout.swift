import Foundation

/// A finished turn: from the user's message until the agent's reply ended.
public struct TurnSummary: Equatable, Sendable {
    /// The user message that started the turn.
    public let id: UUID
    public let startedAt: Date
    public let completedAt: Date
    /// The agent's text in the turn, for the footer's Copy button.
    public let agentText: String
}

/// One row of the chat as shown: an item, several consecutive tool calls folded together, or a turn's footer.
public enum ChatRow: Identifiable, Equatable, Sendable {
    case item(ChatItem)
    case tools([ChatItem])
    case turnFooter(TurnSummary)

    public var id: String {
        switch self {
        case .item(let item): item.id.uuidString
        case .tools(let tools): "tools-\(tools.first?.id.uuidString ?? "")"
        case .turnFooter(let summary): "footer-\(summary.id.uuidString)"
        }
    }
}

public enum ChatLayout {
    /// Two or more tool calls in a row fold into one `.tools` row; a lone tool call stays an `.item`.
    /// Every turn whose user message has `completedAt` ends with a `.turnFooter`.
    public static func rows(_ items: [ChatItem]) -> [ChatRow] {
        var rows: [ChatRow] = []
        var pendingTools: [ChatItem] = []
        var turnStart: ChatItem?
        var turnText: [String] = []

        func flushTools() {
            if pendingTools.count == 1 {
                rows.append(.item(pendingTools[0]))
            } else if pendingTools.count > 1 {
                rows.append(.tools(pendingTools))
            }
            pendingTools = []
        }

        func closeTurn() {
            guard let start = turnStart, let completedAt = start.completedAt else { return }
            rows.append(.turnFooter(TurnSummary(
                id: start.id,
                startedAt: start.createdAt,
                completedAt: completedAt,
                agentText: turnText.joined(separator: "\n\n")
            )))
        }

        for item in items {
            if item.kind == .tool {
                pendingTools.append(item)
                continue
            }
            flushTools()
            if item.kind == .user {
                closeTurn()
                turnStart = item
                turnText = []
            } else if item.kind == .agent {
                turnText.append(item.text)
            }
            rows.append(.item(item))
        }
        flushTools()
        closeTurn()
        return rows
    }
}
