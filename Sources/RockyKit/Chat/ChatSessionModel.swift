import Foundation
import Observation

public struct ChatItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case user, agent, thought, tool, error
        /// The user stopped the turn (Esc, Stop or Send Now); shown as "Interrupted by user", like Conductor.
        case interrupted
    }

    public let id: UUID
    public var kind: Kind
    public var text: String
    public var status: String?
    /// Files shown as badges: what the user attached to a message, or what a tool call reads or edits. A user
    /// message's `text` marks where each one sits with `PromptAttachment.marker`, in this order. A line comment's first
    /// entry is its range instead (`lineRange`, `CMT-05`), drawn as its chip; its files follow it.
    public var attachments: [String]
    /// A tool call's ACP kind (read, edit, execute, search, think…), which picks its icon.
    public var toolKind: String?
    public let createdAt: Date
    /// Set on a user message when the agent finishes the turn it started (the reply footer's duration and time).
    public var completedAt: Date?
    /// `DIFF-06`: the lines a completed tool call added and removed, from the `diff` entries of its latest content
    /// (`ToolDiffStats.count`). nil while it runs, when it failed or was rejected, when its content holds no diff or
    /// one that cannot be counted, and on rows saved before the counts were stored. `files` stays 0.
    public var diffStat: DiffStat?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        status: String? = nil,
        attachments: [String] = [],
        toolKind: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        diffStat: DiffStat? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.status = status
        self.attachments = attachments
        self.toolKind = toolKind
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.diffStat = diffStat
    }
}

/// What a conversation reports to `AppModel`, which decides whether the user hears about it.
public enum ChatAttention: Sendable, Equatable {
    /// A turn ended normally (`.running` → `.ready`).
    case finished
    /// An error stopped the agent during a turn.
    case failed
    /// The agent is waiting for a permission or an answer to its question.
    case needsYou
}

/// A message written while the agent was working. It goes out when the turn ends, like Conductor's queue (user
/// decision, 2026-09-23).
public struct QueuedMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let attachments: [URL]
    /// A comment on a diff's lines (`CMT-05`), whose `text` is the comment and `attachments` its files: its row shows
    /// the chip over them, and it goes out as the prompt built when it was written. nil for a typed message.
    public let lineComment: LineComment?

    init(text: String, attachments: [URL] = [], lineComment: LineComment? = nil) {
        self.id = UUID()
        self.text = text
        self.attachments = attachments
        self.lineComment = lineComment
    }

    fileprivate var outgoing: OutgoingMessage {
        lineComment.map(OutgoingMessage.lineComment) ?? .message(text, files: attachments)
    }
}

/// What `ChatSessionModel` sends: a typed message and its files, or a line comment (`CMT-05`).
private enum OutgoingMessage {
    case message(String, files: [URL])
    case lineComment(LineComment)
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
    /// The slash commands the agent announced for this session (KIT-01), replaced on every update.
    public private(set) var commands: [SlashCommand] = []
    /// False until the agent's first command list arrives; until then `AppModel.commands(for:)` offers the last list
    /// of the repository and agent.
    public private(set) var commandsReceived = false
    /// When the turn in progress started, for the elapsed time shown while the agent works.
    public private(set) var turnStartedAt: Date?
    /// Why the agent stopped on an error (ROW-03). nil after an explicit `stop()`, which also ends in `.stopped`;
    /// cleared when the agent starts again or a turn starts.
    public private(set) var failure: String?
    /// Messages waiting for the turn in progress, oldest first; the next one goes out when a turn ends. In memory
    /// only: quitting Rocky drops them.
    public private(set) var queue: [QueuedMessage] = []
    /// The queue waits instead of going out: the user stopped the turn, or it ended on an error or a crash. The next
    /// message the user sends, or Send Now, lets it go again.
    public private(set) var isQueueHeld = false
    /// This turn was stopped or ended on an error, so the queue is held when it ends…
    @ObservationIgnored private var holdsQueue = false
    /// …unless it was stopped to send a queued message now (`sendQueuedNow`).
    @ObservationIgnored private var steers = false
    /// The user stopped this turn, so it ends with an `.interrupted` item whatever the agent answers.
    @ObservationIgnored private var interrupted = false
    /// Called when a turn ends or fails and when the agent starts waiting for the user: the sidebar's unread state
    /// (ROW-04), the alert sound and the Dock's number.
    @ObservationIgnored public var onAttention: (@MainActor (ChatAttention) -> Void)?
    /// While false, updates are buffered and applied on the next show (spec Section 1).
    public var isVisible = true {
        didSet { if isVisible { flush() } }
    }
    /// Called with every command list the agent announces, for `AppModel`'s cache per repository and agent.
    @ObservationIgnored public var onCommands: (@MainActor ([SlashCommand]) -> Void)?

    @ObservationIgnored private let launch: AgentLaunch
    @ObservationIgnored private let flushInterval: Duration
    @ObservationIgnored private let onPersist: @MainActor (ChatItem) -> Void
    @ObservationIgnored private let onSessionReady: @MainActor (String) -> Void
    @ObservationIgnored private var resumeSessionId: String?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var connection: ACPConnection?
    @ObservationIgnored private var buffered: [SessionEvent] = []
    /// The last command list that came while `sessionId` was still nil. Both adapters send it from a `setTimeout`
    /// right after the `session/new`, `session/load` or `session/resume` response (ACP-01), and that notification can
    /// reach this actor before the code that stores the new id; dropping it would leave the popup without commands
    /// until the list changes.
    @ObservationIgnored private var earlyCommands: JSONValue?
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var openTextItem: UUID?
    @ObservationIgnored private var toolItems: [String: UUID] = [:]
    @ObservationIgnored private var turnItems: [UUID] = []
    /// From a turn's start until it saves `turnItems`, as it ends. A tool call's counts that land before then go with
    /// them: saving the call earlier would give it its place in the transcript before the items ahead of it.
    @ObservationIgnored private var isTurnUnsaved = false
    /// `DIFF-06`: the latest `diff` entries of each tool call that has not completed, counted when it does. A turn
    /// that ends drops the entries of the calls that never completed.
    @ObservationIgnored private var pendingDiffs: [UUID: [ToolCallDiff]] = [:]
    /// `DIFF-06`: the count each tool call waits for, by serial. A later update replaces or removes it, and a count that
    /// ends after that is dropped.
    @ObservationIgnored private var diffCounts: [UUID: Int] = [:]
    @ObservationIgnored private var lastDiffCount = 0
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
        // Cleared by the task itself, before anyone waiting on it resumes, so `restart()` can start again right after.
        let task = Task {
            await performStart()
            startTask = nil
        }
        startTask = task
        await task.value
    }

    /// Stops the agent and starts it again (CMD-08's Refresh): a new process rereads Claude Code's MCP and plugin
    /// configuration and announces a new command list. A conversation with messages resumes its session through
    /// `session/load`. A start in progress ends on the stop, and the new one begins after it.
    public func restart() async {
        await stop()
        await startTask?.value
        await start()
    }

    private func performStart() async {
        state = .starting
        failure = nil
        resumeSessionId = sessionId ?? resumeSessionId
        sessionId = nil
        earlyCommands = nil
        do {
            let connection = try ACPConnection(
                executable: launch.executable,
                arguments: launch.arguments,
                environment: launch.environment,
                cwd: launch.cwd,
                stderrLog: launch.stderrLog
            )
            self.connection = connection
            // A restart starts the next process before the stopped one has exited: what the old one still reports,
            // its exit above all, must not reach the new session.
            let connectionId = ObjectIdentifier(connection)
            await connection.setHandlers(ACPHandlers(
                onNotification: { [weak self] notification in await self?.receive(notification, from: connectionId) },
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
                onExit: { [weak self] error in await self?.connectionEnded(error, from: connectionId) }
            ))
            try await connection.start()
            capabilities = ACPProtocol.capabilities(from: try await connection.call("initialize", ACPProtocol.initializeParams()))
            // Updates are dropped while `sessionId` is nil. `session/load` replays the whole
            // conversation before it responds, and the transcript already comes from the store.
            // A conversation nobody wrote in has nothing to resume: Claude Code saves a session only once it
            // gets its first prompt, so loading it would fail with "Resource not found".
            let hasBeenPrompted = items.contains { $0.kind == .user }
            if let resume = resumeSessionId, capabilities.loadSession, hasBeenPrompted {
                do {
                    let loaded = try await connection.call("session/load", ACPProtocol.loadSessionParams(sessionId: resume, cwd: launch.cwd))
                    adopt(sessionId: resume)
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
            fail(Self.describe(error))
            await connection?.terminate()
        }
    }

    private func startNewSession(on connection: ACPConnection) async throws {
        let result = try await connection.call("session/new", ACPProtocol.newSessionParams(cwd: launch.cwd))
        guard let id = ACPProtocol.sessionId(fromNewSession: result) else {
            throw ACPConnectionError.rpc(code: 0, message: "session/new returned no sessionId")
        }
        adopt(sessionId: id)
        configOptions = ACPProtocol.configOptions(from: result)
    }

    /// From here on the session's updates are applied, starting with a command list that came before the id was
    /// stored (`earlyCommands`).
    private func adopt(sessionId id: String) {
        sessionId = id
        guard let early = earlyCommands else { return }
        earlyCommands = nil
        if case .availableCommands(let list)? = ACPProtocol.event(fromUpdate: early, sessionId: id) { setCommands(list) }
    }

    private func setCommands(_ list: [SlashCommand]) {
        commands = list
        commandsReceived = true
        onCommands?(list)
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
    /// A terminal command (CMD-08) never goes out: see `terminalCommand(in:)`.
    public func send(_ text: String, attachments: [URL] = []) async {
        guard terminalCommand(in: text) == nil else { return }
        await deliver(.message(text, files: attachments))
    }

    /// `CMT-05`: a comment on a diff's lines, first starting the agent if needed. The transcript keeps the comment and
    /// its range's entry, the chip; the agent gets `comment.prompt` as one text block, with a `resource_link` only for
    /// each file attached next to the chip, after it. A turn that started since the caller looked, or while the agent
    /// started, queues it instead, so it is never lost. Its text is a comment, never a command (CMD-08).
    public func send(_ comment: LineComment) async {
        guard state != .running else { return enqueue(comment) }
        await deliver(.lineComment(comment))
    }

    private func deliver(_ outgoing: OutgoingMessage) async {
        if state == .idle || state == .starting { await start() }
        if state == .running, case .lineComment(let comment) = outgoing { return enqueue(comment) }
        guard state == .ready, let connection, let sessionId else { return }
        let userItem: ChatItem
        let prompt: JSONValue
        switch outgoing {
        case .message(let text, let files):
            let promptAttachments = files.map { PromptAttachment.make(for: $0, imagesAllowed: capabilities.promptImages) }
            userItem = ChatItem(kind: .user, text: text, attachments: files.map(\.path))
            prompt = ACPProtocol.promptParams(sessionId: sessionId, text: text, attachments: promptAttachments)
        case .lineComment(let comment):
            // Files attached next to the chip (CMT-05's Resend) go as links after the block, like a message's.
            let files = comment.files.map { PromptAttachment.make(for: $0, imagesAllowed: capabilities.promptImages) }
            userItem = ChatItem(kind: .user, text: comment.text, attachments: [comment.range.entry] + comment.files.map(\.path))
            prompt = ACPProtocol.promptParams(sessionId: sessionId, text: "", attachments: [.text(comment.prompt)] + files)
        }
        items.append(userItem)
        onPersist(userItem)
        state = .running
        failure = nil
        isQueueHeld = false
        interrupted = false
        turnStartedAt = userItem.createdAt
        openTextItem = nil
        turnItems = []
        isTurnUnsaved = true
        do {
            _ = try await connection.call("session/prompt", prompt)
            flush()
            if interrupted { appendTurnItem(Self.interruptedItem()) }
            endTurn()
        } catch ACPConnectionError.rpc(_, let message) {
            flush()
            // An agent may answer a cancelled prompt with an error; the user asked for it, so it is no error.
            appendTurnItem(interrupted ? Self.interruptedItem() : ChatItem(kind: .error, text: message))
            holdsQueue = true
            endTurn()
        } catch {
            flush()
            // stop() or the exit handler may already have set a more precise reason.
            if state == .running { fail(Self.describe(error)) }
        }
        for id in turnItems {
            if let item = items.first(where: { $0.id == id }) { onPersist(item) }
        }
        isTurnUnsaved = false
        // A call still pending after its turn never completes.
        pendingDiffs.removeAll()
        if let index = items.firstIndex(where: { $0.id == userItem.id }) {
            items[index].completedAt = Date()
            onPersist(items[index])
        }
    }

    public func cancel() async {
        if state == .running {
            holdsQueue = true
            interrupted = true
        }
        answerPermission(optionId: nil)
        answerQuestion(.cancelled)
        guard let connection, let sessionId else { return }
        try? await connection.notify("session/cancel", ACPProtocol.cancelParams(sessionId: sessionId))
    }

    private static func interruptedItem() -> ChatItem {
        ChatItem(kind: .interrupted, text: "Interrupted by user")
    }

    /// Keeps a message for when the agent's turn ends. A terminal command (CMD-08) is never queued.
    public func enqueue(_ text: String, attachments: [URL] = []) {
        guard terminalCommand(in: text) == nil else { return }
        queue.append(QueuedMessage(text: text, attachments: attachments))
    }

    /// `CMT-05`: a line comment kept for when the turn ends, with the prompt it was written with.
    public func enqueue(_ comment: LineComment) {
        queue.append(QueuedMessage(text: comment.text, attachments: comment.files, lineComment: comment))
    }

    /// The Claude Code terminal command a message runs (CMD-08), which the message box turns into the embedded
    /// terminal's strip. Such a message never reaches the agent, whether it is idle, starting or working: `send` and
    /// `enqueue` drop it, so no path (the queue, Send Now, a popup pick) can deliver it.
    public func terminalCommand(in text: String) -> TerminalOnlyCommand? {
        TerminalOnlyCommand.invoked(by: text, agent: agent)
    }

    /// Takes a message out of the queue, to delete it or to edit it in the message box.
    @discardableResult
    public func removeQueued(id: UUID) -> QueuedMessage? {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return nil }
        return queue.remove(at: index)
    }

    /// Sends a queued message now, Conductor's "steer": a turn in progress is stopped first, and this message goes
    /// out as soon as it ends, ahead of the rest of the queue.
    public func sendQueuedNow(id: UUID) async {
        guard let message = removeQueued(id: id) else { return }
        if state == .running {
            queue.insert(message, at: 0)
            steers = true
            await cancel()
            return
        }
        if case .stopped = state { await start() }
        await deliver(message.outgoing)
    }

    /// The queue's next message, once `send` has finished the turn before it. A message the user sent in between
    /// goes first; this one waits at the front of the queue.
    private func sendNextQueued(_ message: QueuedMessage) async {
        guard state == .ready else {
            queue.insert(message, at: 0)
            return
        }
        await deliver(message.outgoing)
    }

    public func answerPermission(optionId: String?) {
        pendingPermission = nil
        permissionContinuation?.resume(returning: optionId)
        permissionContinuation = nil
    }

    public func stop() async {
        answerPermission(optionId: nil)
        answerQuestion(.cancelled)
        isQueueHeld = !queue.isEmpty
        state = .stopped("Stopped")
        failure = nil
        await connection?.terminate()
    }

    public func flush() {
        let events = buffered
        buffered.removeAll()
        for event in events { apply(event) }
    }

    /// Whether `connectionId` is the process this model talks to now, not one a restart replaced.
    private func isCurrent(_ connectionId: ObjectIdentifier) -> Bool {
        connection.map(ObjectIdentifier.init) == connectionId
    }

    private func receive(_ notification: ACPNotification, from connectionId: ObjectIdentifier) {
        guard notification.method == "session/update", isCurrent(connectionId) else { return }
        guard let sessionId else {
            // Everything else before the id is dropped: `session/load` replays the conversation, which the transcript
            // already has from the store.
            if notification.params["update"]?["sessionUpdate"]?.stringValue == ACPProtocol.availableCommandsUpdate {
                earlyCommands = notification.params
            }
            return
        }
        guard let event = ACPProtocol.event(fromUpdate: notification.params, sessionId: sessionId) else { return }
        // Not buffered while the conversation is hidden: the list adds nothing to the transcript, and the cache a new
        // conversation starts from must not wait for this one to be shown.
        if case .availableCommands(let list) = event { return setCommands(list) }
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
        case let .toolCall(id, title, status, kind, paths, diffs):
            let item = ChatItem(kind: .tool, text: title, status: status, attachments: paths, toolKind: kind)
            toolItems[id] = item.id
            appendTurnItem(item)
            updateDiffStat(at: items.count - 1, diffs: diffs)
        case let .toolCallUpdate(id, status, title, kind, paths, diffs):
            guard let itemId = toolItems[id], let index = items.firstIndex(where: { $0.id == itemId }) else { return }
            if let status { items[index].status = status }
            if let title { items[index].text = title }
            if let kind { items[index].toolKind = kind }
            if let paths { items[index].attachments = paths }
            updateDiffStat(at: index, diffs: diffs)
        case .configOptions(let options):
            if !options.isEmpty { configOptions = options }
        case .currentMode(let mode):
            if let index = configOptions.firstIndex(where: { $0.id == SessionConfigOption.mode }) {
                configOptions[index].current = mode
            }
        case .availableCommands(let list):
            setCommands(list)
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

    // MARK: Line counts (DIFF-06)

    /// A tool call's counts are those of its latest `diff` entries, and only while it is completed. An update with
    /// `content` replaces the entries, as ACP replaces the content, and one without keeps them: Claude's first
    /// `tool_call` carries an optimistic diff (a Write reads as a new file), and the update after the tool ran brings
    /// the real hunks. A call pending, in progress, failed or rejected shows none, since the file has not changed.
    private func updateDiffStat(at index: Int, diffs: [ToolCallDiff]?) {
        let itemId = items[index].id
        if let diffs { pendingDiffs[itemId] = diffs }
        guard items[index].status == "completed" else {
            // A count still running belongs to a completion this update takes back.
            diffCounts[itemId] = nil
            if items[index].diffStat != nil { items[index].diffStat = nil }
            if items[index].status == "failed" { pendingDiffs[itemId] = nil }
            return
        }
        // Completed, and no entries since the last count: its counts stand.
        guard let latest = pendingDiffs.removeValue(forKey: itemId) else { return }
        guard !latest.isEmpty else {
            diffCounts[itemId] = nil
            return setDiffStat(nil, of: itemId)
        }
        count(latest, for: itemId)
    }

    /// Counts off the main actor, as the All files filter ranks: a line diff of up to `ToolDiffStats.lineDiffLimit`
    /// lines is CPU work.
    private func count(_ diffs: [ToolCallDiff], for itemId: UUID) {
        lastDiffCount += 1
        let serial = lastDiffCount
        diffCounts[itemId] = serial
        Task { [weak self] in
            let stat = await Task.detached(priority: .userInitiated) { ToolDiffStats.count(diffs) }.value
            guard let self, self.diffCounts[itemId] == serial else { return }
            self.diffCounts[itemId] = nil
            self.setDiffStat(stat, of: itemId)
        }
    }

    /// A turn saves its items when it ends, so only a call saved already is saved again: a count can land after its
    /// turn ended.
    private func setDiffStat(_ stat: DiffStat?, of itemId: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemId }), items[index].diffStat != stat else { return }
        items[index].diffStat = stat
        if !(isTurnUnsaved && turnItems.contains(itemId)) { onPersist(items[index]) }
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
            onAttention?(.needsYou)
        }
    }

    private func askPermission(_ request: PermissionRequest) async -> String? {
        await withCheckedContinuation { continuation in
            permissionContinuation?.resume(returning: nil)
            permissionContinuation = continuation
            pendingPermission = request
            onAttention?(.needsYou)
        }
    }

    private func connectionEnded(_ error: ACPConnectionError, from connectionId: ObjectIdentifier) {
        guard isCurrent(connectionId) else { return }
        answerPermission(optionId: nil)
        answerQuestion(.cancelled)
        connection = nil
        if case .stopped = state { return }
        fail(Self.describe(error))
    }

    /// The turn in progress ended with the agent still there.
    private func endTurn() {
        guard state == .running else { return }
        state = .ready
        let holds = holdsQueue && !steers
        holdsQueue = false
        steers = false
        if !queue.isEmpty {
            if holds {
                isQueueHeld = true
            } else {
                // The agent goes on with the next message, so there is nothing to report yet. It goes out after
                // `send` has persisted this turn, which a nested call would interleave with the next one.
                let next = queue.removeFirst()
                Task { await sendNextQueued(next) }
                return
            }
        }
        onAttention?(.finished)
    }

    /// An error stopped the agent: shown in the message box and as the workspace's error state.
    private func fail(_ reason: String) {
        let wasWorking = state == .running
        state = .stopped(reason)
        failure = reason
        isQueueHeld = !queue.isEmpty
        // An agent that cannot start shows its error where you started it; one that dies mid-turn may be out of sight.
        if wasWorking { onAttention?(.failed) }
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
