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

    @Test func tellsTheAgentItCanAskQuestions() {
        #expect(ACPProtocol.initializeParams()["clientCapabilities"]?["elicitation"]?["form"] == [:])
    }

    @Test func readsTheAgentsQuestionsInOrderAndBuildsTheAnswer() throws {
        let params: JSONValue = [
            "mode": "form", "sessionId": "s1", "message": "Please answer the following questions.",
            "requestedSchema": ["type": "object", "properties": [
                "question_10": ["type": "string", "description": "Last?", "oneOf": [["const": "Yes", "title": "Yes"]]],
                "question_2": [
                    "type": "array", "title": "Tools", "description": "Which tools?",
                    "items": ["anyOf": [["const": "rg", "title": "rg", "description": "Search"], ["const": "fd", "title": "fd"]]],
                ],
                "question_2_custom": ["type": "string", "title": "Other"],
            ]],
        ]
        let request = try #require(ACPProtocol.questionRequest(from: params))
        #expect(request.questions.map(\.id) == ["question_2", "question_10"])
        #expect(request.questions[0] == AgentQuestionRequest.Question(
            id: "question_2", header: "Tools", text: "Which tools?",
            options: [.init(label: "rg", detail: "Search"), .init(label: "fd", detail: nil)],
            allowsMultiple: true, otherFieldId: "question_2_custom"
        ))
        #expect(request.questions[1].otherFieldId == nil)

        let answered = ACPProtocol.questionResponse(.answered(picks: ["question_2": ["rg"], "question_10": ["Yes"]], other: ["question_2": " bat "]), for: request)
        #expect(answered == ["action": "accept", "content": ["question_2": ["rg"], "question_2_custom": "bat", "question_10": "Yes"]])
        #expect(ACPProtocol.questionResponse(.skipped, for: request) == ["action": "decline"])
        #expect(ACPProtocol.questionResponse(.cancelled, for: request) == ["action": "cancel"])
    }

    @Test func marksClaudesQuestionToolAsUserInput() {
        let call = update([
            "sessionUpdate": "tool_call", "toolCallId": "t3", "title": "Which color?", "status": "pending", "kind": "other",
            "_meta": ["claudeCode": ["toolName": "AskUserQuestion"]],
        ])
        #expect(ACPProtocol.event(fromUpdate: call, sessionId: "s1")
            == .toolCall(id: "t3", title: "Which color?", status: "pending", kind: "question"))
    }

    @Test func keepsFilesWhereTheMessageHasThem() {
        let marker = PromptAttachment.marker
        let file = URL(fileURLWithPath: "/repo/notes.md")
        let params = ACPProtocol.promptParams(
            sessionId: "s1",
            text: "look at \(marker) and \(marker)",
            attachments: [.image(mimeType: "image/png", base64: "AAA"), .file(file)]
        )
        #expect(params["prompt"] == [
            ["type": "text", "text": "look at "],
            ["type": "image", "mimeType": "image/png", "data": "AAA"],
            ["type": "text", "text": " and "],
            ["type": "resource_link", "uri": .string(file.absoluteString), "name": "notes.md"],
        ])
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

    @Test func readsAToolCallsKindAndFilesAndLaterUpdates() {
        let call = update([
            "sessionUpdate": "tool_call", "toolCallId": "t2", "title": "Read File", "status": "pending", "kind": "read",
            "locations": [["path": "/repo/a.png", "line": 1], ["path": "/repo/a.png"], ["path": "/repo/b.md"]],
        ])
        #expect(ACPProtocol.event(fromUpdate: call, sessionId: "s1")
            == .toolCall(id: "t2", title: "Read File", status: "pending", kind: "read", paths: ["/repo/a.png", "/repo/b.md"]))
        // Claude's adapter fills in the title and files once the tool's input is complete, without a status.
        let refined = update(["sessionUpdate": "tool_call_update", "toolCallId": "t2", "title": "Read a.png", "locations": [["path": "/repo/a.png"]]])
        #expect(ACPProtocol.event(fromUpdate: refined, sessionId: "s1")
            == .toolCallUpdate(id: "t2", status: nil, title: "Read a.png", paths: ["/repo/a.png"]))
    }

    @Test func readsSettingsTheAgentChangesByItself() {
        let options = update([
            "sessionUpdate": "config_option_update",
            "configOptions": [["id": "mode", "name": "Mode", "currentValue": "default", "options": [["value": "default", "name": "Manual"], ["value": "plan", "name": "Plan"]]]],
        ])
        guard case .configOptions(let parsed) = ACPProtocol.event(fromUpdate: options, sessionId: "s1") else {
            Issue.record("expected configOptions")
            return
        }
        #expect(parsed.map(\.id) == ["mode"])
        #expect(parsed.first?.current == "default")
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "current_mode_update", "currentModeId": "plan"]), sessionId: "s1")
            == .currentMode("plan"))
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

    @Test func readsConfigOptionsIncludingGroupsAndSkipsEmptyOnes() {
        let result: JSONValue = ["configOptions": [
            ["id": "model", "name": "Model", "category": "model", "currentValue": "opus", "options": [
                ["value": "default", "name": "Default", "description": "Opus 4.x"],
                ["group": "more", "name": "More", "options": [["value": "opus", "name": "Opus"], ["value": "haiku", "name": "Haiku"]]],
            ]],
            ["id": "effort", "name": "Effort", "category": "thought_level", "currentValue": "high", "options": [
                ["value": "low", "name": "Low"], ["value": "high", "name": "High"],
            ]],
            ["id": "empty", "name": "Nothing", "options": []],
        ]]
        let options = ACPProtocol.configOptions(from: result)
        #expect(options.map(\.id) == ["model", "effort"])
        #expect(options[0].currentName == "Opus")
        #expect(options[0].choices.map(\.value) == ["default", "opus", "haiku"])
        #expect(options[0].choices.first?.detail == "Opus 4.x")
        #expect(options[1].category == "thought_level")
        #expect(options[1].currentName == "High")
    }

    @Test func readsLegacyModelsAndBuildsBothChangeRequests() throws {
        let legacy = try #require(ACPProtocol.configOptions(from: ["models": [
            "currentModelId": "a",
            "availableModels": [["modelId": "a", "name": "A"], ["modelId": "b", "name": "B"]],
        ]]).first)
        #expect(legacy.id == "model")
        #expect(legacy.isLegacyModel)
        let legacyRequest = ACPProtocol.setConfigOptionRequest(sessionId: "s1", option: legacy, value: "b")
        #expect(legacyRequest.method == "session/set_model")
        #expect(legacyRequest.params == ["sessionId": "s1", "modelId": "b"])

        let effort = SessionConfigOption(id: "effort", name: "Effort", category: "thought_level", current: "low", choices: [])
        let request = ACPProtocol.setConfigOptionRequest(sessionId: "s1", option: effort, value: "high")
        #expect(request.method == "session/set_config_option")
        #expect(request.params == ["sessionId": "s1", "configId": "effort", "value": "high"])
        #expect(ACPProtocol.configOptions(from: [:]).isEmpty)
    }
}
