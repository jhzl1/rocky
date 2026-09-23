import Foundation

public struct AgentCapabilities: Sendable, Equatable {
    public var loadSession: Bool

    public init(loadSession: Bool) {
        self.loadSession = loadSession
    }
}

public enum SessionEvent: Sendable, Equatable {
    case agentText(String)
    case agentThought(String)
    case toolCall(id: String, title: String, status: String)
    case toolCallUpdate(id: String, status: String)
    case ignored(String)
}

public struct PermissionOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
}

public struct PermissionRequest: Sendable, Equatable {
    public let title: String
    public let options: [PermissionOption]
}

/// Builds and reads ACP payloads (protocol version 1). Pure functions, no I/O.
public enum ACPProtocol {
    public static func initializeParams() -> JSONValue {
        [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
        ]
    }

    public static func capabilities(from result: JSONValue) -> AgentCapabilities {
        AgentCapabilities(loadSession: result["agentCapabilities"]?["loadSession"]?.boolValue ?? false)
    }

    public static func newSessionParams(cwd: URL) -> JSONValue {
        ["cwd": .string(cwd.path), "mcpServers": []]
    }

    public static func loadSessionParams(sessionId: String, cwd: URL) -> JSONValue {
        ["sessionId": .string(sessionId), "cwd": .string(cwd.path), "mcpServers": []]
    }

    public static func promptParams(sessionId: String, text: String) -> JSONValue {
        ["sessionId": .string(sessionId), "prompt": [["type": "text", "text": .string(text)]]]
    }

    public static func cancelParams(sessionId: String) -> JSONValue {
        ["sessionId": .string(sessionId)]
    }

    public static func sessionId(fromNewSession result: JSONValue) -> String? {
        result["sessionId"]?.stringValue
    }

    /// Maps a `session/update` payload to an event; nil when it belongs to another session.
    public static func event(fromUpdate params: JSONValue, sessionId: String) -> SessionEvent? {
        guard params["sessionId"]?.stringValue == sessionId,
              let update = params["update"],
              let kind = update["sessionUpdate"]?.stringValue else { return nil }
        switch kind {
        case "agent_message_chunk":
            return .agentText(update["content"]?["text"]?.stringValue ?? "")
        case "agent_thought_chunk":
            return .agentThought(update["content"]?["text"]?.stringValue ?? "")
        case "tool_call":
            return .toolCall(
                id: update["toolCallId"]?.stringValue ?? "",
                title: update["title"]?.stringValue ?? "Tool call",
                status: update["status"]?.stringValue ?? "pending"
            )
        case "tool_call_update":
            guard let status = update["status"]?.stringValue else { return .ignored(kind) }
            return .toolCallUpdate(id: update["toolCallId"]?.stringValue ?? "", status: status)
        default:
            return .ignored(kind)
        }
    }

    public static func permissionRequest(from params: JSONValue) -> PermissionRequest {
        let options = (params["options"]?.arrayValue ?? []).compactMap { option -> PermissionOption? in
            guard let id = option["optionId"]?.stringValue else { return nil }
            return PermissionOption(id: id, name: option["name"]?.stringValue ?? id, kind: option["kind"]?.stringValue ?? "")
        }
        return PermissionRequest(title: params["toolCall"]?["title"]?.stringValue ?? "The agent wants to run a tool", options: options)
    }

    /// `nil` answers "cancelled", which ACP requires when the prompt is cancelled or dismissed.
    public static func permissionResponse(optionId: String?) -> JSONValue {
        guard let optionId else { return ["outcome": ["outcome": "cancelled"]] }
        return ["outcome": ["outcome": "selected", "optionId": .string(optionId)]]
    }
}
