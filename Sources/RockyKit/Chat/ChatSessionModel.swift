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

    public init(id: UUID = UUID(), kind: Kind, text: String, status: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.status = status
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
    public private(set) var sessionId: String?
    public private(set) var capabilities = AgentCapabilities(loadSession: false)
    /// While false, updates are buffered and applied on the next show (spec Section 1).
    public var isVisible = true {
        didSet { if isVisible { flush() } }
    }

    @ObservationIgnored private let launch: AgentLaunch
    @ObservationIgnored private let flushInterval: Duration
    @ObservationIgnored private let onPersist: @MainActor (ChatItem) -> Void
    @ObservationIgnored private var resumeSessionId: String?
    @ObservationIgnored private var connection: ACPConnection?
    @ObservationIgnored private var buffered: [SessionEvent] = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var openTextItem: UUID?
    @ObservationIgnored private var toolItems: [String: UUID] = [:]
    @ObservationIgnored private var turnItems: [UUID] = []
    @ObservationIgnored private var permissionContinuation: CheckedContinuation<String?, Never>?

    public init(
        agent: AgentKind,
        launch: AgentLaunch,
        history: [ChatItem] = [],
        resumeSessionId: String? = nil,
        flushInterval: Duration = .milliseconds(100),
        onPersist: @escaping @MainActor (ChatItem) -> Void = { _ in }
    ) {
        self.agent = agent
        self.launch = launch
        self.items = history
        self.resumeSessionId = resumeSessionId
        self.flushInterval = flushInterval
        self.onPersist = onPersist
    }

    public func start() async {
        switch state {
        case .idle, .stopped: break
        default: return
        }
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
                    _ = try await connection.call("session/load", ACPProtocol.loadSessionParams(sessionId: resume, cwd: launch.cwd))
                    sessionId = resume
                } catch ACPConnectionError.rpc(_, let message) {
                    // The agent no longer has that session, for example after the repo switched Claude instances.
                    let note = ChatItem(kind: .error, text: "Could not resume the previous conversation (\(message)); started a new one.")
                    items.append(note)
                    onPersist(note)
                    sessionId = try await newSession(on: connection)
                }
            } else {
                sessionId = try await newSession(on: connection)
            }
            state = .ready
        } catch {
            state = .stopped(Self.describe(error))
            await connection?.terminate()
        }
    }

    private func newSession(on connection: ACPConnection) async throws -> String {
        let result = try await connection.call("session/new", ACPProtocol.newSessionParams(cwd: launch.cwd))
        guard let id = ACPProtocol.sessionId(fromNewSession: result) else {
            throw ACPConnectionError.rpc(code: 0, message: "session/new returned no sessionId")
        }
        return id
    }

    public func send(_ text: String) async {
        guard state == .ready, let connection, let sessionId else { return }
        let userItem = ChatItem(kind: .user, text: text)
        items.append(userItem)
        onPersist(userItem)
        state = .running
        openTextItem = nil
        turnItems = []
        do {
            _ = try await connection.call("session/prompt", ACPProtocol.promptParams(sessionId: sessionId, text: text))
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
    }

    public func cancel() async {
        answerPermission(optionId: nil)
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
        case let .toolCall(id, title, status):
            let item = ChatItem(kind: .tool, text: title, status: status)
            toolItems[id] = item.id
            appendTurnItem(item)
        case let .toolCallUpdate(id, status):
            guard let itemId = toolItems[id], let index = items.firstIndex(where: { $0.id == itemId }) else { return }
            items[index].status = status
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

    private func askPermission(_ request: PermissionRequest) async -> String? {
        await withCheckedContinuation { continuation in
            permissionContinuation?.resume(returning: nil)
            permissionContinuation = continuation
            pendingPermission = request
        }
    }

    private func connectionEnded(_ error: ACPConnectionError) {
        answerPermission(optionId: nil)
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
