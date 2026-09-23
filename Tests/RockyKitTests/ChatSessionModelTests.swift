import Foundation
import Testing
@testable import RockyKit

@MainActor
struct ChatSessionModelTests {
    private func waitForPermission(_ model: ChatSessionModel) async throws {
        for _ in 0..<500 where model.pendingPermission == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.pendingPermission != nil)
    }

    private func summary(_ items: [ChatItem]) -> [String] {
        items.map { "\($0.kind.rawValue):\($0.text)" + ($0.status.map { "[\($0)]" } ?? "") }
    }

    @Test func startsANewSessionAndIgnoresUpdatesBeforeIt() async {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        #expect(model.state == .ready)
        #expect(model.sessionId == "fake-1")
        #expect(model.capabilities.loadSession)
        #expect(model.items.isEmpty)
        await model.stop()
    }

    @Test func streamsTextAsksPermissionAndPersistsTheTurn() async throws {
        var persisted: [ChatItem] = []
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero) { persisted.append($0) }
        await model.start()

        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        #expect(model.state == .running)
        #expect(model.pendingPermission?.title == "Run printenv")
        #expect(model.pendingPermission?.options.map(\.id) == ["allow", "reject"])
        model.answerPermission(optionId: "allow")
        await sending

        #expect(model.state == .ready)
        #expect(summary(model.items) == ["user:hi", "agent:Hello", "tool:Run printenv[completed]"])
        #expect(summary(persisted) == ["user:hi", "agent:Hello", "tool:Run printenv[completed]"])
        await model.stop()
    }

    @Test func rejectedPermissionMarksTheToolFailed() async throws {
        let model = ChatSessionModel(agent: .opencode, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        model.answerPermission(optionId: "reject")
        await sending
        #expect(model.items.last?.status == "failed")
        await model.stop()
    }

    @Test func hiddenSessionBuffersUpdatesUntilShown() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        model.isVisible = false

        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        #expect(summary(model.items) == ["user:hi"])
        model.isVisible = true
        #expect(summary(model.items) == ["user:hi", "agent:Hello", "tool:Run printenv[pending]"])

        model.answerPermission(optionId: "allow")
        await sending
        await model.stop()
    }

    @Test func resumeUsesSessionLoadAndDoesNotDuplicateReplayedHistory() async {
        let history = [ChatItem(kind: .user, text: "earlier"), ChatItem(kind: .agent, text: "replayed")]
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), history: history, resumeSessionId: "fake-1", flushInterval: .zero)
        await model.start()
        #expect(model.state == .ready)
        #expect(model.sessionId == "fake-1")
        #expect(model.items == history)
        await model.stop()
    }

    @Test func resumeFallsBackToNewSessionWhenAgentCannotLoad() async {
        let history = [ChatItem(kind: .user, text: "earlier")]
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(loadSession: false), history: history, resumeSessionId: "old-9", flushInterval: .zero)
        await model.start()
        #expect(model.sessionId == "fake-1")
        #expect(model.items == history)
        await model.stop()
    }

    @Test func agentThatExitsDuringStartStopsWithReason() async {
        let launch = AgentLaunch(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "read -r line; echo 'Authentication required' >&2; exit 3"],
            environment: ProcessInfo.processInfo.environment,
            cwd: FileManager.default.temporaryDirectory,
            stderrLog: Fixtures.stderrLog()
        )
        let model = ChatSessionModel(agent: .claude, launch: launch, flushInterval: .zero)
        await model.start()
        #expect(model.state == .stopped("Agent exited (3). Authentication required"))
    }

    @Test func stopWhileWaitingForPermissionUnblocksTheTurn() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        await model.stop()
        await sending
        #expect(model.pendingPermission == nil)
        #expect(model.state == .stopped("Stopped"))
    }
}
