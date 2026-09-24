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
        // The user message is saved again once the turn ends, now with its completedAt.
        #expect(summary(persisted) == ["user:hi", "agent:Hello", "tool:Run printenv[completed]", "user:hi"])
        let user = try #require(model.items.first)
        let completedAt = try #require(user.completedAt)
        #expect(completedAt >= user.createdAt)
        #expect(persisted.last?.completedAt == completedAt)
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

    @Test func theFirstMessageStartsAnIdleChat() async throws {
        var ready: [String] = []
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero, onSessionReady: { ready.append($0) })
        #expect(model.state == .idle)

        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        model.answerPermission(optionId: "allow")
        await sending

        #expect(model.state == .ready)
        #expect(ready == ["fake-1"])
        #expect(summary(model.items) == ["user:hi", "agent:Hello", "tool:Run printenv[completed]"])
        await model.stop()
    }

    @Test func readsTheSessionOptionsAndChangesThem() async {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        #expect(model.configOptions.map(\.id) == ["model", "effort", "mode"])
        #expect(model.option("model")?.choices.map(\.name) == ["Default", "Opus"])
        #expect(model.option("model")?.current == "default")

        await model.setOption("model", to: "opus")
        #expect(model.option("model")?.current == "opus")
        await model.setOption("effort", to: "low")
        #expect(model.option("effort")?.currentName == "Low")
        await model.stop()
    }

    @Test func showsTheAgentsQuestionAndSendsTheAnswer() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(asks: true), flushInterval: .zero)
        await model.start()
        async let sending: Void = model.send("pick one")
        for _ in 0..<500 where model.pendingQuestion == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let request = try #require(model.pendingQuestion)
        #expect(request.questions.map(\.text) == ["Which color?"])
        #expect(request.questions.first?.options.map(\.label) == ["Blue", "Red"])
        model.answerQuestion(.answered(picks: ["question_0": ["Blue"]], other: [:]))
        await sending

        #expect(model.pendingQuestion == nil)
        #expect(model.items.last?.text == "answered Blue")
        await model.stop()
    }

    @Test func planModeSwitchesTheModeAndBack() async {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        #expect(model.canUsePlanMode)
        #expect(!model.isPlanMode)

        await model.setPlanMode(true)
        #expect(model.isPlanMode)
        await model.setPlanMode(false)
        #expect(model.option("mode")?.current == "default")
        await model.stop()
    }

    @Test func aMessageKeepsItsFilesApartFromItsTextAndTheToolItsKind() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        let file = try Fixtures.temporaryDirectory("files").appendingPathComponent("notes.md")
        try "notes".write(to: file, atomically: true, encoding: .utf8)

        async let sending: Void = model.send("look", attachments: [file])
        try await waitForPermission(model)
        #expect(model.turnStartedAt == model.items.first?.createdAt)
        model.answerPermission(optionId: "allow")
        await sending

        #expect(model.items.first?.text == "look")
        #expect(model.items.first?.attachments == [file.path])
        #expect(model.items.last?.toolKind == "execute")
        await model.stop()
    }

    @Test func resumeStartsANewSessionWhenTheAgentNoLongerHasTheOldOne() async {
        let history = [ChatItem(kind: .user, text: "earlier")]
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(loadFails: true), history: history, resumeSessionId: "other-instance", flushInterval: .zero)
        await model.start()
        #expect(model.state == .ready)
        #expect(model.sessionId == "fake-1")
        #expect(summary(model.items) == [
            "user:earlier",
            "error:Could not resume the previous conversation (Resource not found); started a new one.",
        ])
        await model.stop()
    }

    @Test func aQueuedMessageGoesOutWhenTheTurnEnds() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        var reported: [ChatAttention] = []
        model.onAttention = { reported.append($0) }
        await model.start()
        async let sending: Void = model.send("first")
        try await waitForPermission(model)
        model.enqueue("second")
        model.answerPermission(optionId: "allow")
        await sending
        #expect(model.queue.isEmpty)
        try await waitForPermission(model)
        #expect(model.items.filter { $0.kind == .user }.map(\.text) == ["first", "second"])
        model.answerPermission(optionId: "allow")
        for _ in 0..<500 where model.state != .ready { try await Task.sleep(for: .milliseconds(10)) }
        // The first turn did not report finishing: the agent went on with the queued message.
        #expect(reported == [.needsYou, .needsYou, .finished])
        await model.stop()
    }

    @Test func stoppingTheTurnHoldsTheQueue() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        async let sending: Void = model.send("first")
        try await waitForPermission(model)
        model.enqueue("second")
        await model.cancel()
        await sending
        #expect(model.state == .ready)
        #expect(model.queue.map(\.text) == ["second"])
        #expect(model.isQueueHeld)
        #expect(model.items.filter { $0.kind == .user }.map(\.text) == ["first"])
        await model.stop()
    }

    @Test func sendQueuedNowStopsTheTurnAndSendsIt() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        async let sending: Void = model.send("first")
        try await waitForPermission(model)
        model.enqueue("second")
        model.enqueue("third")
        let third = try #require(model.queue.last)
        await model.sendQueuedNow(id: third.id)
        await sending
        try await waitForPermission(model)
        #expect(model.items.filter { $0.kind == .user }.map(\.text) == ["first", "third"])
        #expect(model.queue.map(\.text) == ["second"])
        #expect(!model.isQueueHeld)
        await model.stop()
    }

    @Test func aConversationWithNoMessageStartsANewSessionWithoutAnError() async {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(loadFails: true), history: [], resumeSessionId: "never-prompted", flushInterval: .zero)
        await model.start()
        #expect(model.state == .ready)
        #expect(model.sessionId == "fake-1")
        #expect(model.items.isEmpty)
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

    @Test func agentExitSetsFailure() async {
        let launch = AgentLaunch(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "read -r line; echo 'Authentication required' >&2; exit 3"],
            environment: ProcessInfo.processInfo.environment,
            cwd: FileManager.default.temporaryDirectory,
            stderrLog: Fixtures.stderrLog()
        )
        let model = ChatSessionModel(agent: .claude, launch: launch, flushInterval: .zero)
        await model.start()
        #expect(model.failure == "Agent exited (3). Authentication required")
    }

    /// An explicit stop also ends in `.stopped`, but it is not the sidebar's error state.
    @Test func explicitStopIsNotAFailure() async {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        await model.stop()
        #expect(model.state == .stopped("Stopped"))
        #expect(model.failure == nil)
    }

    @Test func aTurnReportsItsPermissionRequestAndItsEnd() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        var reported: [ChatAttention] = []
        model.onAttention = { reported.append($0) }
        await model.start()
        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        model.answerPermission(optionId: "allow")
        await sending
        #expect(reported == [.needsYou, .finished])
        await model.stop()
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
