import Foundation
import Testing
@testable import RockyKit

struct ACPProtocolTests {
    private func update(_ body: JSONValue, session: String = "s1") -> JSONValue {
        ["sessionId": .string(session), "update": body]
    }

    @Test func readsLoadSessionCapability() {
        #expect(ACPProtocol.capabilities(from: ["agentCapabilities": ["loadSession": true]]).loadSession)
        #expect(!ACPProtocol.capabilities(from: [:]).loadSession)
    }

    @Test func buildsPromptParams() {
        #expect(ACPProtocol.promptParams(sessionId: "s1", text: "hi")
            == ["sessionId": "s1", "prompt": [["type": "text", "text": "hi"]]])
    }

    @Test func mapsMessageThoughtAndToolUpdates() {
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Hel"]]), sessionId: "s1")
            == .agentText("Hel"))
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "hmm"]]), sessionId: "s1")
            == .agentThought("hmm"))
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run ls", "status": "pending"]), sessionId: "s1")
            == .toolCall(id: "t1", title: "Run ls", status: "pending"))
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"]), sessionId: "s1")
            == .toolCallUpdate(id: "t1", status: "completed"))
    }

    @Test func ignoresUnknownKindsAndUpdatesWithoutStatus() {
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "available_commands_update"]), sessionId: "s1")
            == .ignored("available_commands_update"))
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "tool_call_update", "toolCallId": "t1"]), sessionId: "s1")
            == .ignored("tool_call_update"))
    }

    @Test func dropsUpdatesForAnotherSession() {
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "agent_message_chunk"], session: "other"), sessionId: "s1") == nil)
    }

    @Test func nonTextContentBecomesEmptyText() {
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "agent_message_chunk", "content": ["type": "image"]]), sessionId: "s1")
            == .agentText(""))
    }

    @Test func readsPermissionRequestAndBuildsResponses() {
        let request = ACPProtocol.permissionRequest(from: [
            "toolCall": ["toolCallId": "t1", "title": "Run printenv"],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"], ["name": "no id"]],
        ])
        #expect(request == PermissionRequest(title: "Run printenv", options: [PermissionOption(id: "allow", name: "Allow", kind: "allow_once")]))
        #expect(ACPProtocol.permissionResponse(optionId: "allow") == ["outcome": ["outcome": "selected", "optionId": "allow"]])
        #expect(ACPProtocol.permissionResponse(optionId: nil) == ["outcome": ["outcome": "cancelled"]])
    }

    @Test func readsImageSupport() {
        let result: JSONValue = ["agentCapabilities": ["loadSession": true, "promptCapabilities": ["image": true, "embeddedContext": true]]]
        #expect(ACPProtocol.capabilities(from: result) == AgentCapabilities(loadSession: true, promptImages: true))
        #expect(!ACPProtocol.capabilities(from: [:]).promptImages)
    }

    @Test func buildsPromptParamsWithAttachments() {
        let file = URL(fileURLWithPath: "/tmp/notes.md")
        let params = ACPProtocol.promptParams(sessionId: "s1", text: "look", attachments: [.image(mimeType: "image/png", base64: "AAA"), .file(file)])
        #expect(params == ["sessionId": "s1", "prompt": [
            ["type": "text", "text": "look"],
            ["type": "image", "mimeType": "image/png", "data": "AAA"],
            ["type": "resource_link", "uri": "file:///tmp/notes.md", "name": "notes.md"],
        ]])
    }

    @Test func imagesGoInlineOnlyWhenAllowedAndOtherFilesAsLinks() throws {
        let folder = try Fixtures.temporaryDirectory("attach")
        let image = folder.appendingPathComponent("shot.png")
        let text = folder.appendingPathComponent("notes.txt")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try Data("hi".utf8).write(to: text)
        #expect(PromptAttachment.make(for: image, imagesAllowed: true) == .image(mimeType: "image/png", base64: "iVBORw=="))
        #expect(PromptAttachment.make(for: image, imagesAllowed: false) == .file(image))
        #expect(PromptAttachment.make(for: text, imagesAllowed: true) == .file(text))
    }

    @Test func readsModelsFromConfigOptionsIncludingGroups() {
        let result: JSONValue = ["configOptions": [
            ["id": "mode", "options": [["value": "ask", "name": "Ask"]]],
            ["id": "model", "category": "model", "currentValue": "opus", "options": [
                ["value": "default", "name": "Default", "description": "Opus 4.x"],
                ["group": "more", "name": "More", "options": [["value": "opus", "name": "Opus"], ["value": "haiku", "name": "Haiku"]]],
            ]],
        ]]
        let choice = ACPProtocol.modelChoice(from: result)
        #expect(choice?.configId == "model")
        #expect(choice?.current == "opus")
        #expect(choice?.currentName == "Opus")
        #expect(choice?.options.map(\.value) == ["default", "opus", "haiku"])
        #expect(choice?.options.first?.detail == "Opus 4.x")
    }

    @Test func readsLegacyModelsAndBuildsBothSwitchRequests() throws {
        let legacy = try #require(ACPProtocol.modelChoice(from: ["models": [
            "currentModelId": "a",
            "availableModels": [["modelId": "a", "name": "A"], ["modelId": "b", "name": "B"]],
        ]]))
        #expect(legacy.configId == nil)
        #expect(ACPProtocol.setModelRequest(sessionId: "s1", choice: legacy, value: "b").method == "session/set_model")
        #expect(ACPProtocol.setModelRequest(sessionId: "s1", choice: legacy, value: "b").params == ["sessionId": "s1", "modelId": "b"])

        let config = ModelChoice(configId: "model", current: "a", options: legacy.options)
        let request = ACPProtocol.setModelRequest(sessionId: "s1", choice: config, value: "b")
        #expect(request.method == "session/set_config_option")
        #expect(request.params == ["sessionId": "s1", "configId": "model", "value": "b"])
        #expect(ACPProtocol.modelChoice(from: [:]) == nil)
    }
}
