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

    /// CMT-05: a line comment's prompt is one text block, as it was built, even with the file marker in its code.
    @Test func aTextAttachmentIsOneTextBlockAsItIs() {
        let prompt = "Comment on a.ts, line 1:\n```ts\nlet a = \"\(PromptAttachment.marker)\"\n```\nWhy?"
        #expect(ACPProtocol.promptParams(sessionId: "s1", text: "", attachments: [.text(prompt)])
            == ["sessionId": "s1", "prompt": [["type": "text", "text": .string(prompt)]]])
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

    /// DIFF-06, in the shapes claude-agent-acp 0.81 sends: the optimistic `tool_call` of a Write, then the update after
    /// the tool ran, with only `content`, whose hunks carry their counts at `_meta.jetbrains.air.diffStats`.
    @Test func readsClaudesDiffEntriesAndTheirCounts() {
        let call = update([
            "sessionUpdate": "tool_call", "toolCallId": "t4", "title": "Write notes.md", "status": "pending", "kind": "edit",
            "content": [["type": "diff", "path": "/repo/notes.md", "oldText": .null, "newText": "one\ntwo\n"]],
        ])
        #expect(ACPProtocol.event(fromUpdate: call, sessionId: "s1") == .toolCall(
            id: "t4", title: "Write notes.md", status: "pending", kind: "edit",
            diffs: [ToolCallDiff(path: "/repo/notes.md", oldText: nil, newText: "one\ntwo\n")]
        ))
        let meta: JSONValue = ["jetbrains": ["air": ["version": 1, "diffStats": ["version": 1, "added": 1, "removed": 1]]]]
        let hunks = update([
            "sessionUpdate": "tool_call_update", "toolCallId": "t4",
            "_meta": ["claudeCode": ["toolName": "Write"]],
            "content": [
                ["type": "diff", "path": "/repo/notes.md", "oldText": "one\n2", "newText": "one\ntwo", "_meta": meta],
                // A hunk whose coordinates did not check out comes without counts.
                ["type": "diff", "path": "/repo/notes.md", "oldText": .null, "newText": "three"],
            ],
        ])
        #expect(ACPProtocol.event(fromUpdate: hunks, sessionId: "s1") == .toolCallUpdate(id: "t4", status: nil, diffs: [
            ToolCallDiff(path: "/repo/notes.md", oldText: "one\n2", newText: "one\ntwo", stats: DiffStat(additions: 1, deletions: 1)),
            ToolCallDiff(path: "/repo/notes.md", oldText: nil, newText: "three"),
        ]))
    }

    /// Counts only at Claude's key, with `version` 1 and whole, non-negative numbers.
    @Test func readsCountsOnlyInTheirKnownShape() {
        func stats(_ diffStats: JSONValue) -> DiffStat? {
            ACPProtocol.diffStats(fromMeta: ["jetbrains": ["air": ["diffStats": diffStats]]])
        }
        #expect(stats(["version": 1, "added": 3, "removed": 0]) == DiffStat(additions: 3))
        #expect(stats(["version": 2, "added": 3, "removed": 0]) == nil)
        #expect(stats(["added": 3, "removed": 0]) == nil)
        #expect(stats(["version": 1, "added": -1, "removed": 0]) == nil)
        #expect(stats(["version": 1, "added": .number(1.5), "removed": 0]) == nil)
        #expect(stats(["version": 1, "added": .number(1e300), "removed": 0]) == nil)
        #expect(stats(["version": 1, "added": "3", "removed": 0]) == nil)
        #expect(ACPProtocol.diffStats(fromMeta: ["diffStats": ["version": 1, "added": 3, "removed": 0]]) == nil)
        #expect(ACPProtocol.diffStats(fromMeta: nil) == nil)
    }

    /// DIFF-06: `diffs` is nil without `content`, so the call keeps its entries, and empty when the content holds no
    /// diff, so an update with only such content is no longer ignored. OpenCode's entries have no `_meta`, and an
    /// entry without its path or new text is left out.
    @Test func anUpdateWithContentButNoDiffReplacesTheEntries() {
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "tool_call_update", "toolCallId": "t5", "status": "failed"]), sessionId: "s1")
            == .toolCallUpdate(id: "t5", status: "failed"))
        let text = update([
            "sessionUpdate": "tool_call_update", "toolCallId": "t5",
            "content": [["type": "content", "content": ["type": "text", "text": "The user rejected the edit"]]],
        ])
        #expect(ACPProtocol.event(fromUpdate: text, sessionId: "s1") == .toolCallUpdate(id: "t5", status: nil, diffs: []))
        let opencode = update([
            "sessionUpdate": "tool_call_update", "toolCallId": "t6", "status": "completed",
            "content": [
                ["type": "diff", "path": "/repo/a.ts", "oldText": "", "newText": "export {}\n"],
                ["type": "diff", "path": "/repo/b.ts"],
                ["type": "diff", "newText": "x"],
            ],
        ])
        #expect(ACPProtocol.event(fromUpdate: opencode, sessionId: "s1")
            == .toolCallUpdate(id: "t6", status: "completed", diffs: [ToolCallDiff(path: "/repo/a.ts", oldText: "", newText: "export {}\n")]))
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
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "user_message_chunk"]), sessionId: "s1")
            == .ignored("user_message_chunk"))
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "tool_call_update", "toolCallId": "t1"]), sessionId: "s1")
            == .ignored("tool_call_update"))
    }

    /// KIT-01, in the shape claude-agent-acp 0.81.0 sends: a hint, a null input, an MCP prompt, `_meta`, and entries
    /// the parser must drop or fill in.
    @Test func parsesAvailableCommands() {
        let commands = update([
            "sessionUpdate": "available_commands_update",
            "availableCommands": [
                ["name": "compact", "description": "Clear conversation history but keep a summary in context", "input": ["hint": "<optional custom summarization instructions>"]],
                ["name": "security-review", "description": "Review the pending changes", "input": .null],
                ["name": "mcp:linear:triage", "description": "Triage an issue (MCP)", "input": ["hint": "<issue>"], "_meta": ["claudeCode": ["source": "mcp"]]],
                ["description": "an entry without a name"],
                ["name": 7, "description": "a name that is not a string"],
                ["name": "no-description", "input": [:]],
                ["name": "blank-hint", "description": "", "input": ["hint": " "]],
                ["name": "compact", "description": "announced twice"],
            ],
        ])
        #expect(ACPProtocol.event(fromUpdate: commands, sessionId: "s1") == .availableCommands([
            SlashCommand(name: "compact", description: "Clear conversation history but keep a summary in context", inputHint: "<optional custom summarization instructions>"),
            SlashCommand(name: "security-review", description: "Review the pending changes"),
            SlashCommand(name: "mcp:linear:triage", description: "Triage an issue (MCP)", inputHint: "<issue>"),
            SlashCommand(name: "no-description"),
            SlashCommand(name: "blank-hint"),
        ]))
        #expect(SlashCommand(name: "mcp:linear:triage").isMCP)
        #expect(!SlashCommand(name: "compact").isMCP)
        // An update without a list is an empty list, which still replaces the previous one.
        #expect(ACPProtocol.event(fromUpdate: update(["sessionUpdate": "available_commands_update"]), sessionId: "s1")
            == .availableCommands([]))
    }

    /// OpenCode 1.18.32 sends a name and a description, never an input.
    @Test func parsesOpenCodeCommandsWithoutInput() {
        let commands = update([
            "sessionUpdate": "available_commands_update",
            "availableCommands": [["name": "init", "description": "create/update AGENTS.md"], ["name": "review", "description": "review changes"]],
        ])
        #expect(ACPProtocol.event(fromUpdate: commands, sessionId: "s1") == .availableCommands([
            SlashCommand(name: "init", description: "create/update AGENTS.md"),
            SlashCommand(name: "review", description: "review changes"),
        ]))
    }

    /// ACP-03: a command is an ordinary prompt whose first block is the text exactly as typed, `mcp:` included, with
    /// the files after it.
    @Test func commandPromptIsTheTextAsTyped() {
        let file = URL(fileURLWithPath: "/repo/issue.md")
        let params = ACPProtocol.promptParams(
            sessionId: "s1",
            text: "/mcp:linear:triage web \(PromptAttachment.marker)",
            attachments: [.file(file)]
        )
        #expect(params["prompt"] == [
            ["type": "text", "text": "/mcp:linear:triage web "],
            ["type": "resource_link", "uri": .string(file.absoluteString), "name": "issue.md"],
        ])
        let unmarked = ACPProtocol.promptParams(sessionId: "s1", text: "/mcp:linear:triage web", attachments: [.file(file)])
        #expect(unmarked["prompt"]?.arrayValue?.first == ["type": "text", "text": "/mcp:linear:triage web"])
        #expect(ACPProtocol.promptParams(sessionId: "s1", text: "/compact")["prompt"] == [["type": "text", "text": "/compact"]])
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
