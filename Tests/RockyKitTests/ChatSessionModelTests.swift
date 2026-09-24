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

    private func waitForCommands(_ model: ChatSessionModel) async throws {
        for _ in 0..<500 where !model.commandsReceived {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.commandsReceived)
    }

    private static let announced = ["compact", "review", "mcp:linear:triage"]

    /// Review Focus 1: both adapters send the list from a `setTimeout` right after the `session/new` result, and it
    /// must not be lost.
    @Test func commandsSentRightAfterSessionNewArrive() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        var reported: [[String]] = []
        model.onCommands = { reported.append($0.map(\.name)) }
        #expect(!model.commandsReceived)
        await model.start()
        try await waitForCommands(model)
        #expect(model.commands.map(\.name) == Self.announced)
        #expect(model.commands.first?.inputHint == "<optional custom summarization instructions>")
        #expect(model.commands[1].inputHint == nil)
        #expect(reported == [Self.announced])
        #expect(model.items.isEmpty)
        await model.stop()
    }

    /// The list can reach the model before the code that stores the new session id: it is kept and applied then,
    /// while the other updates before the id stay dropped.
    @Test func commandsThatBeatTheSessionIdAreKept() async {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(commandsEarly: true), flushInterval: .zero)
        await model.start()
        #expect(model.commandsReceived)
        #expect(model.commands.map(\.name) == Self.announced)
        #expect(model.items.isEmpty)
        await model.stop()
    }

    /// Review Focus 2 (ACP-01): each update replaces the whole list.
    @Test func commandsAreReplacedNotMerged() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        try await waitForCommands(model)
        await model.send("change commands")
        #expect(model.commands == [SlashCommand(name: "init", description: "Write a CLAUDE.md for this repository")])
        await model.stop()
    }

    @Test func aResumedSessionGetsItsCommandsWithoutReplayingHistory() async throws {
        let history = [ChatItem(kind: .user, text: "earlier"), ChatItem(kind: .agent, text: "replayed")]
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), history: history, resumeSessionId: "fake-1", flushInterval: .zero)
        await model.start()
        try await waitForCommands(model)
        #expect(model.commands.map(\.name) == Self.announced)
        #expect(model.items == history)
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
        #expect(model.items.last?.kind == .interrupted)
        #expect(model.items.filter { $0.kind == .user }.map(\.text) == ["first"])
        await model.stop()
    }

    @Test func stoppingATurnEndsItWithInterruptedByUser() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        await model.cancel()
        await sending
        #expect(model.items.last?.kind == .interrupted)
        #expect(model.items.last?.text == "Interrupted by user")
        #expect(model.items.filter { $0.kind == .error }.isEmpty)
        await model.stop()
    }

    @Test func aTurnNobodyStoppedHasNoInterruptedMark() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        await model.start()
        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        model.answerPermission(optionId: "allow")
        await sending
        #expect(!model.items.contains { $0.kind == .interrupted })
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

    // MARK: Terminal commands (CMD-08)

    /// The lines the fake agent received so far.
    private func received(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    /// Claude Code's terminal commands never reach the agent, idle or working, and are never queued.
    @Test func terminalCommandsNeverReachTheAgentNorTheQueue() async throws {
        let log = Fixtures.stderrLog()
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(log: log), flushInterval: .zero)
        await model.start()
        #expect(model.terminalCommand(in: "/mcp extra") == TerminalOnlyCommand(name: "mcp", arguments: "extra"))
        #expect(model.terminalCommand(in: "/compact") == nil)

        await model.send("/mcp")
        #expect(model.items.isEmpty)
        #expect(model.state == .ready)
        model.enqueue("/mcp extra args")
        #expect(model.queue.isEmpty)

        // During a turn.
        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        #expect(model.state == .running)
        model.enqueue("/hooks")
        model.enqueue("/plugins now")
        #expect(model.queue.isEmpty)
        model.answerPermission(optionId: "allow")
        await sending

        let prompts = received(log).filter { $0.contains(#""method":"session/prompt""#) }
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains(#""text":"hi""#) == true)
        #expect(!received(log).contains { $0.contains("/mcp") || $0.contains("/hooks") || $0.contains("/plugins") })
        #expect(model.items.filter { $0.kind == .user }.map(\.text) == ["hi"])
        await model.stop()
    }

    /// OpenCode's commands all go to its agent, "/mcp" included.
    @Test func anOpenCodeConversationSendsTheSameTextToItsAgent() async throws {
        let log = Fixtures.stderrLog()
        let model = ChatSessionModel(agent: .opencode, launch: Fixtures.fakeACPLaunch(log: log), flushInterval: .zero)
        await model.start()
        #expect(model.terminalCommand(in: "/mcp") == nil)
        async let sending: Void = model.send("/mcp")
        try await waitForPermission(model)
        model.answerPermission(optionId: "allow")
        await sending
        #expect(model.items.first?.text == "/mcp")
        #expect(received(log).contains { $0.contains(#""method":"session/prompt""#) && $0.contains(#""text":"/mcp""#) })
        await model.stop()
    }

    /// CMD-08's Refresh: a new agent process resumes the session (`session/load`) and announces its list again. The
    /// stopped process exits after the new one has started; its exit must not end the new session.
    @Test func restartResumesTheSessionAndGetsANewCommandList() async throws {
        let log = Fixtures.stderrLog()
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(log: log), flushInterval: .zero)
        await model.start()
        async let sending: Void = model.send("hi")
        try await waitForPermission(model)
        model.answerPermission(optionId: "allow")
        await sending
        await model.send("change commands")
        #expect(model.commands.map(\.name) == ["init"])

        await model.restart()
        #expect(model.state == .ready)
        #expect(model.sessionId == "fake-1")
        try await waitUntil { model.commands.map(\.name) == Self.announced }
        #expect(received(log).filter { $0.contains(#""method":"session/load""#) }.count == 1)
        #expect(received(log).filter { $0.contains(#""method":"session/new""#) }.count == 1)

        // Long enough for the stopped process's exit to come in.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.state == .ready)
        #expect(model.failure == nil)
        await model.send("change commands")
        #expect(model.commands.map(\.name) == ["init"])
        await model.stop()
    }

    /// A Refresh while the agent is still starting waits for that start to end, then starts again.
    @Test func restartWhileStartingStartsAgain() async throws {
        let model = ChatSessionModel(agent: .claude, launch: Fixtures.fakeACPLaunch(), flushInterval: .zero)
        let starting = Task { await model.start() }
        // The start sets `.starting` before its first wait on the process, and stays there for its round trips.
        for _ in 0..<10_000 where model.state == .idle { await Task.yield() }
        try #require(model.state == .starting)
        await model.restart()
        await starting.value
        #expect(model.state == .ready)
        #expect(model.sessionId == "fake-1")
        await model.stop()
    }
}
