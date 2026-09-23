import Foundation

public struct AgentCapabilities: Sendable, Equatable {
    public var loadSession: Bool
    /// The agent accepts images inside a prompt (`promptCapabilities.image`).
    public var promptImages: Bool

    public init(loadSession: Bool, promptImages: Bool = false) {
        self.loadSession = loadSession
        self.promptImages = promptImages
    }
}

/// A file the user attached to a message.
public enum PromptAttachment: Sendable, Equatable {
    case image(mimeType: String, base64: String)
    /// Sent as an ACP `resource_link`: the agent reads the file itself.
    case file(URL)

    /// Up to this size an image goes inline; a bigger one is sent as a link.
    public static let maxInlineImageBytes = 5_000_000

    public static func make(for url: URL, imagesAllowed: Bool) -> PromptAttachment {
        let mimeTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        guard imagesAllowed,
              let mimeType = mimeTypes[url.pathExtension.lowercased()],
              let data = try? Data(contentsOf: url),
              data.count <= maxInlineImageBytes else {
            return .file(url)
        }
        return .image(mimeType: mimeType, base64: data.base64EncodedString())
    }
}

/// The models an agent offers for a session. Claude's adapter reports them as the `model` entry of
/// `configOptions` (switched with `session/set_config_option`); older agents report `models`
/// (switched with `session/set_model`), and then `configId` is nil.
public struct ModelChoice: Sendable, Equatable {
    public struct Option: Sendable, Equatable, Identifiable {
        public let value: String
        public let name: String
        public let detail: String?
        public var id: String { value }
    }

    public let configId: String?
    public var current: String
    public let options: [Option]

    public var currentName: String {
        options.first { $0.value == current }?.name ?? current
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
        AgentCapabilities(
            loadSession: result["agentCapabilities"]?["loadSession"]?.boolValue ?? false,
            promptImages: result["agentCapabilities"]?["promptCapabilities"]?["image"]?.boolValue ?? false
        )
    }

    /// Reads the model list from a `session/new` or `session/load` result; nil when the agent offers none.
    public static func modelChoice(from result: JSONValue) -> ModelChoice? {
        if let option = result["configOptions"]?.arrayValue?.first(where: {
            $0["id"]?.stringValue == "model" || $0["category"]?.stringValue == "model"
        }), let configId = option["id"]?.stringValue {
            // An option list may hold groups, each with its own `options`.
            let options = (option["options"]?.arrayValue ?? [])
                .flatMap { $0["options"]?.arrayValue ?? [$0] }
                .compactMap { entry -> ModelChoice.Option? in
                    guard let value = entry["value"]?.stringValue else { return nil }
                    return ModelChoice.Option(value: value, name: entry["name"]?.stringValue ?? value, detail: entry["description"]?.stringValue)
                }
            guard !options.isEmpty else { return nil }
            return ModelChoice(configId: configId, current: option["currentValue"]?.stringValue ?? options[0].value, options: options)
        }
        if let models = result["models"], let available = models["availableModels"]?.arrayValue {
            let options = available.compactMap { entry -> ModelChoice.Option? in
                guard let id = entry["modelId"]?.stringValue else { return nil }
                return ModelChoice.Option(value: id, name: entry["name"]?.stringValue ?? id, detail: entry["description"]?.stringValue)
            }
            guard !options.isEmpty else { return nil }
            return ModelChoice(configId: nil, current: models["currentModelId"]?.stringValue ?? options[0].value, options: options)
        }
        return nil
    }

    public static func setModelRequest(sessionId: String, choice: ModelChoice, value: String) -> (method: String, params: JSONValue) {
        if let configId = choice.configId {
            return ("session/set_config_option", ["sessionId": .string(sessionId), "configId": .string(configId), "value": .string(value)])
        }
        return ("session/set_model", ["sessionId": .string(sessionId), "modelId": .string(value)])
    }

    public static func newSessionParams(cwd: URL) -> JSONValue {
        ["cwd": .string(cwd.path), "mcpServers": []]
    }

    public static func loadSessionParams(sessionId: String, cwd: URL) -> JSONValue {
        ["sessionId": .string(sessionId), "cwd": .string(cwd.path), "mcpServers": []]
    }

    public static func promptParams(sessionId: String, text: String, attachments: [PromptAttachment] = []) -> JSONValue {
        var blocks: [JSONValue] = [["type": "text", "text": .string(text)]]
        for attachment in attachments {
            switch attachment {
            case let .image(mimeType, base64):
                blocks.append(["type": "image", "mimeType": .string(mimeType), "data": .string(base64)])
            case let .file(url):
                blocks.append(["type": "resource_link", "uri": .string(url.absoluteString), "name": .string(url.lastPathComponent)])
            }
        }
        return ["sessionId": .string(sessionId), "prompt": .array(blocks)]
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
