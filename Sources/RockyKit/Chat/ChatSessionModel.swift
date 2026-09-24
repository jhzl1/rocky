import Foundation
import Observation

public struct ChatItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case user, agent, thought, tool, error
    }

    public let id: UUID
    public var kind: Kind
    public var text: String
    public var status: String?
    /// Files shown as badges: what the user attached to a message, or what a tool call reads or edits. A user
    /// message's `text` marks where each one sits with `PromptAttachment.marker`, in this order.
    public var attachments: [String]
    /// A tool call's ACP kind (read, edit, execute, search, think…), which picks its icon.
    public var toolKind: String?
    public let createdAt: Date
    /// Set on a user message when the agent finishes the turn it started (the reply footer's duration and time).
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        status: String? = nil,
        attachments: [String] = [],
        toolKind: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.status = status
        self.attachments = attachments
        self.toolKind = toolKind
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

/// One agent session in one workspace: starts the ACP process, streams its updates into `items`,
/// and surfaces permission prompts.
@MainActor
@Observable
public final class ChatSessionModel {
    public enum State: Equatable {
        case idle, starting, ready, running
        case stopped(String)
    }

    public let agent: AgentKind
    public private(set) var items: [ChatItem]
    public private(set) var state: State = .idle
    public private(set) var pendingPermission: PermissionRequest?
    /// Questions the agent is waiting on (Claude's AskUserQuestion).
    public private(set) var pendingQuestion: AgentQuestionRequest?
    public private(set) var sessionId: String?
    public private(set) var capabilities = AgentCapabilities(loadSession: false)
    /// The settings the agent offers for this session (model, effort, fast mode…); empty until the session exists.
    public private(set) var configOptions: [SessionConfigOption] = []
    /// When the turn in progress started, for the elapsed time shown while the agent works.
    public private(set) var turnStartedAt: Date?
    /// While false, updates are buffered and applied on the next show (spec Section 1).
    public var isVisible = true {
        didSet { if isVisible { flush() } }
    }

    @ObservationIgnored private let launch: AgentLaunch
    @ObservationIgnored private let flushInterval: Duration
    @ObservationIgnored private let onPersist: @MainActor (ChatItem) -> Void
    @ObservationIgnored private let onSessionReady: @MainActor (String) -> Void
    @ObservationIgnored private var resumeSessionId: String?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var connection: ACPConnection?
    @ObservationIgnored private var buffered: [SessionEvent] = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var openTextItem: UUID?
    @ObservationIgnored private var toolItems: [String: UUID] = [:]
    @ObservationIgnored private var turnItems: [UUID] = []
    @ObservationIgnored private var permissionContinuation: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var questionContinuation: CheckedContinuation<AgentQuestionAnswer, Never>?
    /// The mode plan mode was switched on from, so switching it off goes back there.
    @ObservationIgnored private var modeBeforePlan: String?

    public init(
        agent: AgentKind,
        launch: AgentLaunch,
        history: [ChatItem] = [],
        resumeSessionId: String? = nil,
        flushInterval: Duration = .milliseconds(100),
        onPersist: @escaping @MainActor (ChatItem) -> Void = { _ in },
        onSessionReady: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.agent = agent
        self.launch = launch
        self.items = history
        self.resumeSessionId = resumeSessionId
        self.flushInterval = flushInterval
        self.onPersist = onPersist
        self.onSessionReady = onSessionReady
    }

    /// Starts the agent. A second call while it is starting waits for the same start, so a message sent while
    /// the agent starts in the background goes out once it is ready.
    public func start() async {
        if let startTask {
            await startTask.value
            return
        }
        switch state {
        case .idle, .stopped: break
        default: return
        }
        let task = Task { await performStart() }
        startTask = task
        await task.value
        startTask = nil
    }

    private func performStart() async {
        state = .starting
        resumeSessionId = sessionId ?? resumeSessionId
        sessionId = nil
        do {
            let connection = try ACPConnection(
                executable: launch.executable,
                arguments: launch.arguments,
                environment: launch.environment,
                cwd: launch.cwd,
                stderrLog: launch.stderrLog
            )
            self.connection = connection
            await connection.setHandlers(ACPHandlers(
                onNotification: { [weak self] notification in await self?.receive(notification) },
                onRequest: { [weak self] method, params in
                    if method == ACPProtocol.questionMethod {
                        guard let self, let request = ACPProtocol.questionRequest(from: params) else { return ["action": "decline"] }
                        let answer = await self.askQuestion(request)
                        return ACPProtocol.questionResponse(answer, for: request)
                    }
                    guard method == "session/request_permission", let self else {
                        return ACPProtocol.permissionResponse(optionId: nil)
                    }
                    let optionId = await self.askPermission(ACPProtocol.permissionRequest(from: params))
                    return ACPProtocol.permissionResponse(optionId: optionId)
                },
                onExit: { [weak self] error in await self?.connectionEnded(error) }
            ))
            try await connection.start()
            capabilities = ACPProtocol.capabilities(from: try await connection.call("initialize", ACPProtocol.initializeParams()))
            // Updates are dropped while `sessionId` is nil. `session/load` replays the whole
            // conversation before it responds, and the transcript already comes from the store.
            if let resume = resumeSessionId, capabilities.loadSession {
                do {
                    let loaded = try await connection.call("session/load", ACPProtocol.loadSessionParams(sessionId: resume, cwd: launch.cwd))
                    sessionId = resume
                    configOptions = ACPProtocol.configOptions(from: loaded)
                } catch ACPConnectionError.rpc(_, let message) {
                    // The agent no longer has that session, for example after the repo switched Claude instances.
                    // Shown but not saved: it says why the agent forgot the conversation, and it must not pile up.
                    items.append(ChatItem(kind: .error, text: "Could not resume the previous conversation (\(message)); started a new one."))
                    try await startNewSession(on: connection)
                }
            } else {
                try await startNewSession(on: connection)
            }
            state = .ready
            if let sessionId { onSessionReady(sessionId) }
        } catch {
            state = .stopped(Self.describe(error))
            await connection?.terminate()
        }
    }

    private func startNewSession(on connection: ACPConnection) async throws {
        let result = try await connection.call("session/new", ACPProtocol.newSessionParams(cwd: launch.cwd))
        guard let id = ACPProtocol.sessionId(fromNewSession: result) else {
            throw ACPConnectionError.rpc(code: 0, message: "session/new returned no sessionId")
        }
        sessionId = id
        configOptions = ACPProtocol.configOptions(from: result)
    }

    public func option(_ id: String) -> SessionConfigOption? {
        configOptions.first { $0.id == id }
    }

    /// Changes one of `configOptions` (for example the model or the effort). The agent answers with the whole
    /// updated list when it can, since changing the model changes the effort levels.
    public func setOption(_ id: String, to value: String) async {
        guard let connection, let sessionId, let option = option(id), option.current != value else { return }
        let request = ACPProtocol.setConfigOptionRequest(sessionId: sessionId, option: option, value: value)
        do {
            let updated = ACPProtocol.configOptions(from: try await connection.call(request.method, request.params))
            if updated.isEmpty {
                if let index = configOptions.firstIndex(where: { $0.id == id }) { configOptions[index].current = value }
            } else {
                configOptions = updated
            }
        } catch {
            items.append(ChatItem(kind: .error, text: "Could not change \(option.name.lowercased()): \(Self.describe(error))"))
        }
    }

    /// The agent offers a plan mode: it plans and asks before changing anything.
    public var canUsePlanMode: Bool {
        option(SessionConfigOption.mode)?.choices.contains { $0.value == SessionConfigOption.planMode } ?? false
    }

    public var isPlanMode: Bool {
        option(SessionConfigOption.mode)?.current == SessionConfigOption.planMode
    }

    public func setPlanMode(_ on: Bool) async {
        guard let mode = option(SessionConfigOption.mode), canUsePlanMode, on != isPlanMode else { return }
        if on {
            modeBeforePlan = mode.current
            await setOption(mode.id, to: SessionConfigOption.planMode)
        } else {
            let previous = modeBeforePlan.flatMap { value in mode.choices.first { $0.value == value }?.value }
            await setOption(mode.id, to: previous ?? mode.choices.first { $0.value != SessionConfigOption.planMode }?.value ?? "default")
        }
    }

    /// Sends a message, first starting the agent if it has not started, or waiting for a start in progress.
    /// Images go inline when the agent accepts them; other files are sent as links the agent reads itself. `text`
    /// may mark where each file sits with `PromptAttachment.marker`.
    public func send(_ text: String, attachments: [URL] = []) async {
        if state == .idle || state == .starting { await start() }
        guard state == .ready, let connection, let sessionId else { return }
        let promptAttachments = attachments.map { PromptAttachment.make(for: $0, imagesAllowed: capabilities.promptImages) }
        let userItem = ChatItem(kind: .user, text: text, attachments: attachments.map(\.path))
        items.append(userItem)
        onPersist(userItem)
        state = .running
        turnStartedAt = userItem.createdAt
        openTextItem = nil
        turnItems = []
        do {
            _ = try await connection.call(
                "session/prompt",
                ACPProtocol.promptParams(sessionId: sessionId, text: text, attachments: promptAttachments)
            )
            flush()
            if state == .running { state = .ready }
        } catch ACPConnectionError.rpc(_, let message) {
            flush()
            appendTurnItem(ChatItem(kind: .error, text: message))
            if state == .running { state = .ready }
        } catch {
            flush()
            // stop() or the exit handler may already have set a more precise reason.
            if state == .running { state = .stopped(Self.describe(error)) }
        }
        for id in turnItems {
            if let item = items.first(where: { $0.id == id }) { onPersist(item) }
        }
        if let index = items.firstIndex(where: { $0.id == userItem.id }) {
            items[index].completedAt = Date()
            onPersist(items[index])
        }
    }

    public func cancel() async {
        answerPermission(optionId: nil)
        answerQuestion(.cancelled)
        guard let connection, let sessionId else { return }
        try? await connection.notify("session/cancel", ACPProtocol.cancelParams(sessionId: sessionId))
    }

    public func answerPermission(optionId: String?) {
        pendingPermission = nil
        permissionContinuation?.resume(returning: optionId)
        permissionContinuation = nil
    }

    public func stop() async {
        answerPermission(optionId: nil)
        answerQuestion(.cancelled)
        state = .stopped("Stopped")
        await connection?.terminate()
    }

    public func flush() {
        let events = buffered
        buffered.removeAll()
        for event in events { apply(event) }
    }

    private func receive(_ notification: ACPNotification) {
        guard notification.method == "session/update", let sessionId,
              let event = ACPProtocol.event(fromUpdate: notification.params, sessionId: sessionId) else { return }
        buffered.append(event)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard isVisible else { return }
        guard flushInterval > .zero else { return flush() }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self, flushInterval] in
            try? await Task.sleep(for: flushInterval)
            self?.flushScheduled = false
            self?.flush()
        }
    }

    private func apply(_ event: SessionEvent) {
        switch event {
        case .agentText(let text):
            appendText(text, kind: .agent)
        case .agentThought(let text):
            appendText(text, kind: .thought)
        case let .toolCall(id, title, status, kind, paths):
            let item = ChatItem(kind: .tool, text: title, status: status, attachments: paths, toolKind: kind)
            toolItems[id] = item.id
            appendTurnItem(item)
        case let .toolCallUpdate(id, status, title, kind, paths):
            guard let itemId = toolItems[id], let index = items.firstIndex(where: { $0.id == itemId }) else { return }
            if let status { items[index].status = status }
            if let title { items[index].text = title }
            if let kind { items[index].toolKind = kind }
            if let paths { items[index].attachments = paths }
        case .configOptions(let options):
            if !options.isEmpty { configOptions = options }
        case .currentMode(let mode):
            if let index = configOptions.firstIndex(where: { $0.id == SessionConfigOption.mode }) {
                configOptions[index].current = mode
            }
        case .ignored:
            break
        }
    }

    private func appendText(_ text: String, kind: ChatItem.Kind) {
        if let openTextItem, let index = items.lastIndex(where: { $0.id == openTextItem }), items[index].kind == kind {
            items[index].text += text
            return
        }
        let item = ChatItem(kind: kind, text: text)
        appendTurnItem(item)
        openTextItem = item.id
    }

    private func appendTurnItem(_ item: ChatItem) {
        openTextItem = nil
        items.append(item)
        turnItems.append(item.id)
    }

    public func answerQuestion(_ answer: AgentQuestionAnswer) {
        pendingQuestion = nil
        questionContinuation?.resume(returning: answer)
        questionContinuation = nil
    }

    private func askQuestion(_ request: AgentQuestionRequest) async -> AgentQuestionAnswer {
        await withCheckedContinuation { continuation in
            questionContinuation?.resume(returning: .cancelled)
            questionContinuation = continuation
            pendingQuestion = request
        }
    }

    private func askPermission(_ request: PermissionRequest) async -> String? {
        await withCheckedContinuation { continuation in
            permissionContinuation?.resume(returning: nil)
            permissionContinuation = continuation
            pendingPermission = request
        }
    }

    private func connectionEnded(_ error: ACPConnectionError) {
        answerPermission(optionId: nil)
        answerQuestion(.cancelled)
        connection = nil
        if case .stopped = state { return }
        state = .stopped(Self.describe(error))
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let ACPConnectionError.agentExited(status, stderrTail):
            let lastLine = stderrTail.split(separator: "\n").last.map(String.init) ?? ""
            return "Agent exited (\(status)). \(lastLine)".trimmingCharacters(in: .whitespaces)
        case let ACPConnectionError.rpc(_, message):
            return message
        default:
            return "\(error)"
        }
    }
}
