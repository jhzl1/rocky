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
    /// Marks where a file sits in a message's text, one per attachment in order: U+FFFC, the character a text view
    /// uses for an embedded object.
    public static let marker = "\u{FFFC}"

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

/// A setting the agent offers for a session, such as the model or the effort. Claude's adapter reports them as
/// `configOptions` and applies a change with `session/set_config_option`, answering with the whole updated list
/// (the effort levels depend on the model). An agent that only reports the older `models` field gets a
/// `model` option with `isLegacyModel`, switched with `session/set_model`.
public struct SessionConfigOption: Sendable, Equatable, Identifiable {
    public struct Choice: Sendable, Equatable, Identifiable {
        public let value: String
        public let name: String
        public let detail: String?
        public var id: String { value }

        public init(value: String, name: String, detail: String? = nil) {
            self.value = value
            self.name = name
            self.detail = detail
        }
    }

    public static let model = "model"
    public static let effort = "effort"
    /// Claude's fast mode: choices "on" and "off".
    public static let fast = "fast"
    /// The permission mode (Claude: default, acceptEdits, plan, auto…); plan mode is its "plan" choice.
    public static let mode = "mode"
    public static let planMode = "plan"

    public let id: String
    public let name: String
    public let category: String?
    public var current: String
    public let choices: [Choice]
    public var isLegacyModel = false

    public var currentName: String {
        choices.first { $0.value == current }?.name ?? current
    }
}

public enum SessionEvent: Sendable, Equatable {
    case agentText(String)
    case agentThought(String)
    /// `kind` is ACP's tool kind (read, edit, execute, search, think…); `paths` are the files it touches.
    case toolCall(id: String, title: String, status: String, kind: String? = nil, paths: [String] = [])
    /// Only what changed: Claude's adapter first reports a tool with a placeholder title and fills it in later.
    case toolCallUpdate(id: String, status: String?, title: String? = nil, kind: String? = nil, paths: [String]? = nil)
    /// The agent changed its settings by itself, for example leaving plan mode once the plan is approved.
    case configOptions([SessionConfigOption])
    case currentMode(String)
    /// The agent's whole command list (ACP-01): it replaces the previous one, never adds to it.
    case availableCommands([SlashCommand])
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
            // `elicitation.form`: Rocky shows the agent's questions (`AgentQuestionRequest`). Without it Claude's adapter
            // takes AskUserQuestion away.
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
                "elicitation": ["form": [:]],
            ],
        ]
    }

    public static func capabilities(from result: JSONValue) -> AgentCapabilities {
        AgentCapabilities(
            loadSession: result["agentCapabilities"]?["loadSession"]?.boolValue ?? false,
            promptImages: result["agentCapabilities"]?["promptCapabilities"]?["image"]?.boolValue ?? false
        )
    }

    /// Reads the select-type settings from a `session/new`, `session/load` or `session/set_config_option`
    /// result. Empty when the agent offers none.
    public static func configOptions(from result: JSONValue) -> [SessionConfigOption] {
        var options = (result["configOptions"]?.arrayValue ?? []).compactMap { entry -> SessionConfigOption? in
            guard let id = entry["id"]?.stringValue else { return nil }
            // A choice list may hold groups, each with its own `options`.
            let choices = (entry["options"]?.arrayValue ?? [])
                .flatMap { $0["options"]?.arrayValue ?? [$0] }
                .compactMap { choice -> SessionConfigOption.Choice? in
                    guard let value = choice["value"]?.stringValue else { return nil }
                    return SessionConfigOption.Choice(value: value, name: choice["name"]?.stringValue ?? value, detail: choice["description"]?.stringValue)
                }
            guard !choices.isEmpty else { return nil }
            return SessionConfigOption(
                id: id,
                name: entry["name"]?.stringValue ?? id,
                category: entry["category"]?.stringValue,
                current: entry["currentValue"]?.stringValue ?? choices[0].value,
                choices: choices
            )
        }
        if !options.contains(where: { $0.id == SessionConfigOption.model }),
           let models = result["models"], let available = models["availableModels"]?.arrayValue {
            let choices = available.compactMap { entry -> SessionConfigOption.Choice? in
                guard let id = entry["modelId"]?.stringValue else { return nil }
                return SessionConfigOption.Choice(value: id, name: entry["name"]?.stringValue ?? id, detail: entry["description"]?.stringValue)
            }
            if !choices.isEmpty {
                options.append(SessionConfigOption(
                    id: SessionConfigOption.model,
                    name: "Model",
                    category: "model",
                    current: models["currentModelId"]?.stringValue ?? choices[0].value,
                    choices: choices,
                    isLegacyModel: true
                ))
            }
        }
        return options
    }

    public static func setConfigOptionRequest(sessionId: String, option: SessionConfigOption, value: String) -> (method: String, params: JSONValue) {
        if option.isLegacyModel {
            return ("session/set_model", ["sessionId": .string(sessionId), "modelId": .string(value)])
        }
        return ("session/set_config_option", ["sessionId": .string(sessionId), "configId": .string(option.id), "value": .string(value)])
    }

    public static func newSessionParams(cwd: URL) -> JSONValue {
        ["cwd": .string(cwd.path), "mcpServers": []]
    }

    public static func loadSessionParams(sessionId: String, cwd: URL) -> JSONValue {
        ["sessionId": .string(sessionId), "cwd": .string(cwd.path), "mcpServers": []]
    }

    /// The prompt's blocks in the order the user wrote them: each `PromptAttachment.marker` in `text` is replaced by
    /// the next attachment. Attachments without a marker go after the text.
    public static func promptParams(sessionId: String, text: String, attachments: [PromptAttachment] = []) -> JSONValue {
        var blocks: [JSONValue] = []
        var remaining = attachments[...]
        for (index, part) in text.components(separatedBy: PromptAttachment.marker).enumerated() {
            if index > 0, let attachment = remaining.popFirst() { blocks.append(block(for: attachment)) }
            if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (index == 0 && attachments.isEmpty) {
                blocks.append(["type": "text", "text": .string(part)])
            }
        }
        blocks.append(contentsOf: remaining.map(block(for:)))
        return ["sessionId": .string(sessionId), "prompt": .array(blocks)]
    }

    private static func block(for attachment: PromptAttachment) -> JSONValue {
        switch attachment {
        case let .image(mimeType, base64):
            ["type": "image", "mimeType": .string(mimeType), "data": .string(base64)]
        case let .file(url):
            ["type": "resource_link", "uri": .string(url.absoluteString), "name": .string(url.lastPathComponent)]
        }
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
                status: update["status"]?.stringValue ?? "pending",
                kind: toolKind(of: update),
                paths: paths(fromLocations: update["locations"]) ?? []
            )
        case "tool_call_update":
            let status = update["status"]?.stringValue
            let title = update["title"]?.stringValue
            let toolKind = update["kind"] == nil ? nil : toolKind(of: update)
            let touched = paths(fromLocations: update["locations"])
            guard status != nil || title != nil || toolKind != nil || touched != nil else { return .ignored(kind) }
            return .toolCallUpdate(id: update["toolCallId"]?.stringValue ?? "", status: status, title: title, kind: toolKind, paths: touched)
        case "config_option_update":
            return .configOptions(configOptions(from: update))
        case "current_mode_update":
            guard let mode = update["currentModeId"]?.stringValue else { return .ignored(kind) }
            return .currentMode(mode)
        case availableCommandsUpdate:
            return .availableCommands(commands(from: update["availableCommands"]))
        default:
            return .ignored(kind)
        }
    }

    /// The `sessionUpdate` kind that carries the agent's commands.
    public static let availableCommandsUpdate = "available_commands_update"

    /// Reads an `availableCommands` list (KIT-01): an entry without a name is dropped, a missing description is
    /// empty, and an `input` that is null, missing or has no hint gives no hint. The order is kept, `_meta` is
    /// ignored. A name announced twice keeps its first entry, since the popup identifies rows by name.
    public static func commands(from list: JSONValue?) -> [SlashCommand] {
        var seen: Set<String> = []
        return (list?.arrayValue ?? []).compactMap { entry -> SlashCommand? in
            guard let name = entry["name"]?.stringValue, !name.isEmpty, seen.insert(name).inserted else { return nil }
            let hint = entry["input"]?["hint"]?.stringValue
            return SlashCommand(
                name: name,
                description: entry["description"]?.stringValue ?? "",
                // A blank hint would complete the command instead of running it, with nothing to show.
                inputHint: hint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? hint : nil
            )
        }
    }

    /// Kind `question` for Claude's AskUserQuestion, which ACP reports as `other`, so the conversation shows it as
    /// the user's input; ACP's `kind` for every other tool.
    public static let questionToolKind = "question"

    static func toolKind(of update: JSONValue) -> String? {
        if update["_meta"]?["claudeCode"]?["toolName"]?.stringValue == "AskUserQuestion" { return questionToolKind }
        return update["kind"]?.stringValue
    }

    /// The files of a tool call's `locations`, each once; nil when the update has no `locations`.
    static func paths(fromLocations locations: JSONValue?) -> [String]? {
        guard let entries = locations?.arrayValue else { return nil }
        var paths: [String] = []
        for path in entries.compactMap({ $0["path"]?.stringValue }) where !paths.contains(path) {
            paths.append(path)
        }
        return paths
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
