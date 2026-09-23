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
}
