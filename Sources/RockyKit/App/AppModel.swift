import Foundation
import Observation

public struct RockyPaths: Sendable {
    public let database: URL
    public let adapterPrefix: URL
    public let logs: URL

    public init(database: URL, adapterPrefix: URL, logs: URL) {
        self.database = database
        self.adapterPrefix = adapterPrefix
        self.logs = logs
    }

    /// `~/Library/Application Support/Rocky` for data and the Claude adapter, `~/Library/Logs/Rocky` for agent stderr.
    public static func standard() throws -> RockyPaths {
        let fileManager = FileManager.default
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Rocky", isDirectory: true)
        let logs = try fileManager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Logs/Rocky", isDirectory: true)
        for directory in [support, logs] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return RockyPaths(
            database: support.appendingPathComponent("rocky.sqlite"),
            adapterPrefix: support.appendingPathComponent("agents", isDirectory: true),
            logs: logs
        )
    }
}

/// Why removing a workspace stopped before deleting anything; the UI offers "Remove Anyway".
public struct ArchiveFailure: Equatable, Sendable {
    public let workspaceId: String
    public let workspaceName: String
    public let message: String

    public init(workspaceId: String, workspaceName: String, message: String) {
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName
        self.message = message
    }
}

/// The setup, run and archive scripts and the terminal tabs of one workspace. Kept only while Rocky runs.
@MainActor
@Observable
public final class WorkspaceProcesses {
    public internal(set) var setup: PTYSession?
    public internal(set) var run: PTYSession?
    public internal(set) var archive: PTYSession?
    public internal(set) var terminals: [PTYSession] = []

    /// Scripts first, then terminals: the order of the panel's tabs.
    public var all: [PTYSession] {
        [setup, run, archive].compactMap { $0 } + terminals
    }

    func stopAll() async {
        let running = all.filter { $0.state.isRunning }
        await withTaskGroup(of: Void.self) { group in
            for session in running {
                group.addTask { await session.stop() }
            }
        }
    }
}

/// App state: repos, their workspaces, one running chat per workspace, and each workspace's scripts and terminals.
@MainActor
@Observable
public final class AppModel {
    public private(set) var repos: [Repo] = []
    public private(set) var workspaces: [String: [Workspace]] = [:]
    public var selectedWorkspaceId: String?
    public var errorMessage: String?
    public var archiveFailure: ArchiveFailure?
    public private(set) var busyMessage: String?
    public private(set) var loginEnvironment: [String: String] = [:]

    @ObservationIgnored public let store: RockyStore
    @ObservationIgnored public let paths: RockyPaths
    @ObservationIgnored private let captureEnvironment: @Sendable () throws -> [String: String]
    @ObservationIgnored private let makeLaunch: @Sendable (AgentKind, URL, [String: String], RockyPaths) throws -> AgentLaunch
    @ObservationIgnored private let installAdapter: @Sendable (AgentKind, String?, RockyPaths, [String: String]) throws -> Void
    @ObservationIgnored private let latestVersion: @Sendable (String) async throws -> String
    @ObservationIgnored private let defaults: UserDefaults
    /// Rocky's agents: installed, newest on npm, tested. See `checkAgentUpdates`.
    public private(set) var agentVersions: [AgentKind: AgentVersion] = [:]
    public private(set) var lastAgentCheck: Date?
    public private(set) var isCheckingAgents = false
    public private(set) var updatingAgent: AgentKind?
    public var agentUpdateError: String?
    private static let lastAgentCheckKey = "lastAgentUpdateCheck"
    /// The automatic check runs at most once a day.
    public static let agentCheckInterval: TimeInterval = 24 * 60 * 60
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let terminalShell: @Sendable ([String: String]) -> (executable: String, arguments: [String])
    @ObservationIgnored private let processStopGracePeriod: Duration
    /// One chat per open conversation, keyed by `ChatSessionRecord.id`. Observed: views show chats from here.
    /// Several conversations of a workspace can run at once, one per tab.
    private var chats: [String: ChatSessionModel] = [:]
    @ObservationIgnored private var chatWorkspaceIds: [String: String] = [:]
    /// Each workspace's open conversations, oldest first: its tabs.
    public private(set) var conversations: [String: [ChatSessionRecord]] = [:]
    /// The conversation each workspace shows.
    public private(set) var selectedConversationIds: [String: String] = [:]
    /// Files opened in tabs next to the conversations (from a file badge), by workspace. Kept only while Rocky runs.
    public private(set) var openFiles: [String: [String]] = [:]
    /// The file tab each workspace shows instead of its conversation; none shows the selected conversation.
    public private(set) var selectedFiles: [String: String] = [:]
    /// Observed for the same reason as `chats`. Created only in actions, never while a view reads it.
    private var processes: [String: WorkspaceProcesses] = [:]

    public init(
        store: RockyStore,
        paths: RockyPaths,
        captureEnvironment: @escaping @Sendable () throws -> [String: String] = { try LoginEnvironment.capture() },
        makeLaunch: @escaping @Sendable (AgentKind, URL, [String: String], RockyPaths) throws -> AgentLaunch = { kind, cwd, environment, paths in
            try AgentLauncher.launch(kind, cwd: cwd, environment: environment, adapterPrefix: paths.adapterPrefix, logsDirectory: paths.logs)
        },
        installAdapter: @escaping @Sendable (AgentKind, String?, RockyPaths, [String: String]) throws -> Void = { kind, version, paths, environment in
            try AgentLauncher.install(kind, version: version, prefix: paths.adapterPrefix, environment: environment)
        },
        latestVersion: @escaping @Sendable (String) async throws -> String = { try await AgentLauncher.latestVersion(of: $0) },
        defaults: UserDefaults = .standard,
        secrets: SecretStore = KeychainSecretStore(),
        terminalShell: @escaping @Sendable ([String: String]) -> (executable: String, arguments: [String]) = { environment in
            (environment["SHELL"] ?? "/bin/zsh", ["-l"])
        },
        processStopGracePeriod: Duration = .seconds(5)
    ) {
        self.store = store
        self.paths = paths
        self.captureEnvironment = captureEnvironment
        self.makeLaunch = makeLaunch
        self.installAdapter = installAdapter
        self.latestVersion = latestVersion
        self.defaults = defaults
        self.lastAgentCheck = defaults.object(forKey: Self.lastAgentCheckKey) as? Date
        self.secrets = secrets
        self.terminalShell = terminalShell
        self.processStopGracePeriod = processStopGracePeriod
    }

    public var selectedWorkspace: Workspace? {
        workspaces.values.joined().first { $0.id == selectedWorkspaceId }
    }

    public func repo(id: String) -> Repo? {
        repos.first { $0.id == id }
    }

    /// The chat of the conversation the workspace shows.
    public func existingChat(workspaceId: String) -> ChatSessionModel? {
        selectedConversationIds[workspaceId].flatMap { chats[$0] }
    }

    public func chat(conversationId: String) -> ChatSessionModel? {
        chats[conversationId]
    }

    /// Whether an agent is working in any of the workspace's conversations (the sidebar's progress arc).
    public func isAgentWorking(workspaceId: String) -> Bool {
        chats.contains { chatWorkspaceIds[$0.key] == workspaceId && $0.value.state == .running }
    }

    public func workspace(id: String) -> Workspace? {
        workspaces.values.joined().first { $0.id == id }
    }

    /// The workspace's scripts and terminals; nil until one has been started. Never creates, so views can call it.
    public func existingProcesses(for workspaceId: String) -> WorkspaceProcesses? {
        processes[workspaceId]
    }

    /// Loads persisted state and captures the login environment once (spec Section 1).
    public func bootstrap() async {
        reload()
        await refreshEnvironment()
        refreshInstalledAgentVersions()
        // Once a day at most: one HTTPS request per agent, no timer.
        Task { await checkAgentUpdates() }
    }

    /// Captures the login shell environment again (menu "Refresh Shell Environment"). Running processes keep the
    /// environment they started with.
    public func refreshEnvironment() async {
        let capture = captureEnvironment
        do {
            loginEnvironment = try await Task.detached { try capture() }.value
        } catch {
            loginEnvironment = ProcessInfo.processInfo.environment
            errorMessage = "Could not read your login shell environment (\(error)). Agents use Rocky's own environment."
        }
    }

    public func addRepo(at url: URL) async {
        let service = WorktreeService(environment: loginEnvironment)
        let isRoot = await Task.detached { service.isRepositoryRoot(url) }.value
        guard isRoot else {
            errorMessage = "\(url.path) is not the root of a git repository."
            return
        }
        do {
            try store.add(Repo(name: url.lastPathComponent, path: url.path))
            reload()
        } catch RockyStoreError.duplicateRepo {
            errorMessage = "\(url.lastPathComponent) is already in Rocky."
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func setClaudeConfigDir(repoId: String, _ directory: String?) async {
        guard var repo = repo(id: repoId) else { return }
        let claudeConfigDir = (directory?.isEmpty ?? true) ? nil : directory
        guard claudeConfigDir != repo.claudeConfigDir else { return }
        repo.claudeConfigDir = claudeConfigDir
        do {
            try store.update(repo)
            reload()
        } catch {
            errorMessage = "\(error)"
            return
        }
        // A running Claude chat keeps the instance it was started with; the next Start picks up the new one.
        let repoWorkspaceIds = Set((workspaces[repoId] ?? []).map(\.id))
        for (conversationId, workspaceId) in chatWorkspaceIds
        where repoWorkspaceIds.contains(workspaceId) && chats[conversationId]?.agent == .claude {
            await stopChat(conversationId: conversationId)
        }
    }

    public func setScripts(repoId: String, setup: String, run: String, archive: String, runMode: RunScriptMode) {
        guard var repo = repo(id: repoId) else { return }
        repo.setupScript = ScriptConfigResolver.clean(setup)
        repo.runScript = ScriptConfigResolver.clean(run)
        repo.archiveScript = ScriptConfigResolver.clean(archive)
        repo.runScriptMode = runMode.rawValue
        do {
            try store.update(repo)
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: Repo variables

    /// The repo's variables. A secret's `value` is nil here: its value is in the secret store.
    public func repoVars(repoId: String) -> [RepoVar] {
        (try? store.repoVars(repoId: repoId)) ?? []
    }

    public func setRepoVar(repoId: String, name: String, value: String, isSecret: Bool) {
        guard Self.isValidVariableName(name) else {
            errorMessage = "\"\(name)\" is not a valid variable name: use letters, digits and _, and do not start with a digit."
            return
        }
        let account = Self.secretAccount(repoId: repoId, name: name)
        do {
            if isSecret {
                try secrets.write(value, account: account)
                try store.save(RepoVar(repoId: repoId, name: name, value: nil, isSecret: true))
            } else {
                try store.save(RepoVar(repoId: repoId, name: name, value: value, isSecret: false))
                // It may have been a secret before.
                try secrets.delete(account: account)
            }
        } catch {
            errorMessage = "Could not save \(name): \(error)"
        }
    }

    public func deleteRepoVar(repoId: String, name: String) {
        do {
            try store.deleteRepoVar(repoId: repoId, name: name)
            try secrets.delete(account: Self.secretAccount(repoId: repoId, name: name))
        } catch {
            errorMessage = "Could not delete \(name): \(error)"
        }
    }

    static func secretAccount(repoId: String, name: String) -> String {
        "\(repoId)/\(name)"
    }

    static func isValidVariableName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil
    }

    /// Forgets the repo in Rocky and deletes its secrets. Its folder and worktrees stay on disk.
    public func removeRepo(id: String) async {
        for workspace in workspaces[id] ?? [] {
            await stopChats(workspaceId: workspace.id)
            await processes.removeValue(forKey: workspace.id)?.stopAll()
        }
        do {
            for variable in try store.repoVars(repoId: id) where variable.isSecret {
                try secrets.delete(account: Self.secretAccount(repoId: id, name: variable.name))
            }
            try store.deleteRepo(id: id)
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func createWorkspace(repoId: String) async {
        guard let repo = repo(id: repoId) else { return }
        let repoURL = URL(fileURLWithPath: repo.path)
        let service = WorktreeService(environment: loginEnvironment)
        busyMessage = "Creating workspace…"
        defer { busyMessage = nil }
        do {
            let created = try await Task.detached {
                let name = WorkspaceNamer.pick(isTaken: { service.isTaken(repo: repoURL, name: $0) })
                return try service.create(repo: repoURL, name: name)
            }.value
            let port = try store.nextPort()
            let workspace = Workspace(
                repoId: repo.id,
                name: created.name,
                path: created.path.path,
                branch: created.branch,
                port: port,
                baseRef: created.baseRef
            )
            try store.add(workspace)
            reload()
            selectedWorkspaceId = workspace.id
            if created.fetchFailed {
                errorMessage = "git fetch failed; \(created.name) was created from the last fetched \(created.baseRef)."
            }
            // Setup runs once, right after the worktree exists (spec Section 3). A failure shows in its tab and
            // leaves the workspace usable.
            do {
                if let setup = try scriptConfig(for: workspace).setup {
                    processesCreatingIfNeeded(for: workspace.id).setup = startScript(setup, title: "Setup", in: workspace)
                }
            } catch {
                errorMessage = "\(error)"
            }
        } catch {
            errorMessage = "Could not create a workspace: \(error)"
        }
    }

    /// Stops the workspace's agent, scripts and terminals, runs its archive script, then removes the worktree
    /// folder and keeps its branch. A failing archive script deletes nothing and sets `archiveFailure`;
    /// `skipArchive` is the user's "Remove Anyway". Git still refuses while there are uncommitted changes.
    public func removeWorkspace(id: String, skipArchive: Bool = false) async {
        guard let workspace = self.workspace(id: id), let repo = repo(id: workspace.repoId) else { return }
        archiveFailure = nil
        await stopChats(workspaceId: id)
        await processes[id]?.stopAll()
        if !skipArchive {
            let archive: String?
            do {
                archive = try scriptConfig(for: workspace).archive
            } catch {
                archiveFailure = ArchiveFailure(workspaceId: id, workspaceName: workspace.name, message: "\(error)")
                return
            }
            if let archive {
                busyMessage = "Running the archive script of \(workspace.name)…"
                let session = startScript(archive, title: "Archive", in: workspace)
                processesCreatingIfNeeded(for: id).archive = session
                let result = await session.waitForExit()
                busyMessage = nil
                guard result == .exited(0) else {
                    archiveFailure = ArchiveFailure(workspaceId: id, workspaceName: workspace.name, message: Self.archiveMessage(result))
                    return
                }
            }
        }
        let service = WorktreeService(environment: loginEnvironment)
        let repoURL = URL(fileURLWithPath: repo.path)
        let worktreeURL = URL(fileURLWithPath: workspace.path)
        do {
            try await Task.detached { try service.remove(repo: repoURL, worktree: worktreeURL) }.value
            try store.deleteWorkspace(id: id)
            processes.removeValue(forKey: id)
            if selectedWorkspaceId == id { selectedWorkspaceId = nil }
            reload()
        } catch {
            errorMessage = "Could not remove \(workspace.name): \(error)"
        }
    }

    static func archiveMessage(_ state: PTYState) -> String {
        switch state {
        case .exited(let code): "The archive script exited with \(code)."
        case .signaled(let signal): "The archive script was stopped by signal \(signal)."
        case .running, .failedToStart: "The archive script could not start."
        }
    }

    // MARK: Conversations

    /// Loads the workspace's tabs and shows the selected conversation (else the newest, else a new one). Its
    /// agent starts in the background, so the model list is there and the first message does not wait; the
    /// other tabs' agents start when their tab is shown (user decision, 2026-09-23).
    public func showConversations(workspace: Workspace) async {
        reloadConversations(workspaceId: workspace.id)
        let open = conversations[workspace.id] ?? []
        if let id = selectedConversationIds[workspace.id], open.contains(where: { $0.id == id }) {
            await showConversation(workspace: workspace, conversationId: id)
        } else if let newest = open.last {
            await showConversation(workspace: workspace, conversationId: newest.id)
        } else {
            await newConversation(workspace: workspace, agent: .claude)
        }
    }

    /// Switches the workspace to one of its tabs. The agent of the tab left behind keeps running.
    public func showConversation(workspace: Workspace, conversationId: String) async {
        selectedConversationIds[workspace.id] = conversationId
        selectedFiles[workspace.id] = nil
        if chats[conversationId] == nil {
            guard let record = try? store.session(id: conversationId), let agent = AgentKind(rawValue: record.agent) else { return }
            do {
                try await makeChat(workspace: workspace, record: record, agent: agent)
            } catch {
                errorMessage = "Could not open the \(agent.displayName) conversation: \(error)"
                return
            }
        }
        startInBackground(chats[conversationId])
    }

    /// Opens a new tab with an empty conversation. Earlier ones stay open and running.
    @discardableResult
    public func newConversation(workspace: Workspace, agent: AgentKind) async -> ChatSessionModel? {
        do {
            let record = ChatSessionRecord(workspaceId: workspace.id, agent: agent.rawValue)
            try store.add(record)
            reloadConversations(workspaceId: workspace.id)
            selectedConversationIds[workspace.id] = record.id
            selectedFiles[workspace.id] = nil
            let chat = try await makeChat(workspace: workspace, record: record, agent: agent)
            startInBackground(chat)
            return chat
        } catch {
            errorMessage = "Could not start a new conversation: \(error)"
            return nil
        }
    }

    /// Closes a tab: stops its agent and hides it. The conversation stays in the store.
    public func closeConversation(workspace: Workspace, conversationId: String) async {
        await stopChat(conversationId: conversationId)
        if var record = try? store.session(id: conversationId) {
            record.closedAt = Date()
            try? store.update(record)
        }
        reloadConversations(workspaceId: workspace.id)
        if selectedConversationIds[workspace.id] == conversationId {
            selectedConversationIds[workspace.id] = nil
            await showConversations(workspace: workspace)
        }
    }

    /// Opens `path` in a tab of the workspace, or shows its tab if it is already open.
    public func openFile(workspaceId: String, path: String) {
        var files = openFiles[workspaceId] ?? []
        if !files.contains(path) { files.append(path) }
        openFiles[workspaceId] = files
        selectedFiles[workspaceId] = path
    }

    public func showFile(workspaceId: String, path: String) {
        guard openFiles[workspaceId]?.contains(path) == true else { return }
        selectedFiles[workspaceId] = path
    }

    /// Closes a file tab; if it was on screen, the selected conversation comes back.
    public func closeFile(workspaceId: String, path: String) {
        openFiles[workspaceId]?.removeAll { $0 == path }
        if selectedFiles[workspaceId] == path { selectedFiles[workspaceId] = nil }
    }

    /// Returns the workspace's last open conversation with `agent` (or a new one), started.
    public func openChat(workspace: Workspace, agent: AgentKind) async -> ChatSessionModel? {
        guard let chat = await prepareChat(workspace: workspace, agent: agent) else { return nil }
        await chat.start()
        return chat
    }

    /// Shows the workspace's last open conversation with `agent`, or a new one, without waiting for its agent.
    @discardableResult
    public func prepareChat(workspace: Workspace, agent: AgentKind) async -> ChatSessionModel? {
        if let chat = existingChat(workspaceId: workspace.id), chat.agent == agent { return chat }
        reloadConversations(workspaceId: workspace.id)
        if let record = (conversations[workspace.id] ?? []).last(where: { $0.agent == agent.rawValue }) {
            await showConversation(workspace: workspace, conversationId: record.id)
            return chats[record.id]
        }
        return await newConversation(workspace: workspace, agent: agent)
    }

    private func startInBackground(_ chat: ChatSessionModel?) {
        guard let chat, chat.state == .idle else { return }
        Task { await chat.start() }
    }

    @discardableResult
    private func makeChat(workspace: Workspace, record: ChatSessionRecord, agent: AgentKind) async throws -> ChatSessionModel {
        let current = self.workspace(id: workspace.id) ?? workspace
        let environment = self.environment(for: current)
        let launch = try await resolveLaunch(agent, cwd: URL(fileURLWithPath: current.path), environment: environment)
        let history = try store.messages(sessionId: record.id).map(ChatItem.init(record:))
        let store = self.store
        let conversationId = record.id
        let workspaceId = workspace.id
        let chat = ChatSessionModel(
            agent: agent,
            launch: launch,
            history: history,
            resumeSessionId: record.acpSessionId,
            onPersist: { [weak self] item in
                try? store.upsert(ChatMessageRecord(item: item, sessionId: conversationId))
                if item.kind == .user { self?.titleIfNeeded(conversationId: conversationId, workspaceId: workspaceId, from: item.text) }
            },
            onSessionReady: { sessionId in
                // Re-read: the stored record may have gained a title since this chat was made.
                guard var stored = try? store.session(id: conversationId), stored.acpSessionId != sessionId else { return }
                stored.acpSessionId = sessionId
                try? store.update(stored)
            }
        )
        chats[conversationId] = chat
        chatWorkspaceIds[conversationId] = workspaceId
        return chat
    }

    private func titleIfNeeded(conversationId: String, workspaceId: String, from text: String) {
        guard var record = try? store.session(id: conversationId), record.title == nil else { return }
        record.title = ChatSessionRecord.title(from: text)
        try? store.update(record)
        reloadConversations(workspaceId: workspaceId)
    }

    private func reloadConversations(workspaceId: String) {
        var open = (try? store.openConversations(workspaceId: workspaceId)) ?? []
        // Conversations saved before titles existed get one from their first message.
        for index in open.indices where open[index].title == nil {
            guard let first = try? store.firstUserMessage(sessionId: open[index].id) else { continue }
            open[index].title = ChatSessionRecord.title(from: first)
            try? store.update(open[index])
        }
        conversations[workspaceId] = open
    }

    private func stopChat(conversationId: String) async {
        chatWorkspaceIds[conversationId] = nil
        await chats.removeValue(forKey: conversationId)?.stop()
    }

    private func stopChats(workspaceId: String) async {
        for (conversationId, owner) in chatWorkspaceIds where owner == workspaceId {
            await stopChat(conversationId: conversationId)
        }
    }

    /// Stops every chat's agent process.
    public func stopAllAgents() async {
        for chat in chats.values { await chat.stop() }
        chats.removeAll()
        chatWorkspaceIds.removeAll()
    }

    /// Called before quitting, so no agent, terminal or script outlives Rocky.
    public func stopAllProcesses() async {
        await stopAllAgents()
        let all = Array(processes.values)
        await withTaskGroup(of: Void.self) { group in
            for workspaceProcesses in all {
                group.addTask { await workspaceProcesses.stopAll() }
            }
        }
    }

    // MARK: Scripts and terminals

    /// Starts the workspace's run script. In `nonconcurrent` mode it first stops every other workspace's run.
    public func startRun(workspaceId: String) async {
        guard let workspace = self.workspace(id: workspaceId) else { return }
        let config: ScriptConfig
        do {
            config = try scriptConfig(for: workspace)
        } catch {
            errorMessage = "\(error)"
            return
        }
        guard let script = config.run else {
            errorMessage = "\(workspace.name) has no run script. Add one in the repo settings or in rocky.json."
            return
        }
        let own = processesCreatingIfNeeded(for: workspaceId)
        if own.run?.state.isRunning == true { return }
        if config.runMode == .nonconcurrent {
            for (id, other) in processes where id != workspaceId {
                if let session = other.run, session.state.isRunning { await session.stop() }
            }
        }
        own.run = startScript(script, title: "Run", in: workspace)
    }

    public func stopRun(workspaceId: String) async {
        await processes[workspaceId]?.run?.stop()
    }

    /// Opens a terminal tab: the login shell, in the worktree, with the workspace environment.
    @discardableResult
    public func openTerminal(workspaceId: String) -> PTYSession? {
        guard let workspace = self.workspace(id: workspaceId) else { return nil }
        let own = processesCreatingIfNeeded(for: workspaceId)
        let environment = self.environment(for: workspace)
        let shell = terminalShell(environment)
        let session = PTYSession(
            // The panel numbers terminals by position: "Terminal 1", "Terminal 2"…
            title: "Terminal",
            command: PTYCommand(
                executable: shell.executable,
                arguments: shell.arguments,
                environment: environment,
                cwd: URL(fileURLWithPath: workspace.path)
            ),
            // SIGHUP is what closing a terminal window sends; an interactive bash ignores SIGTERM.
            stopSignal: SIGHUP,
            stopGracePeriod: processStopGracePeriod
        )
        own.terminals.append(session)
        session.start()
        return session
    }

    public func closeTerminal(workspaceId: String, sessionId: UUID) async {
        guard let own = processes[workspaceId], let session = own.terminals.first(where: { $0.id == sessionId }) else { return }
        await session.stop()
        own.terminals.removeAll { $0.id == sessionId }
    }

    /// The environment of every process started for `workspace`: agent, terminal and script (spec Section 3).
    public func environment(for workspace: Workspace) -> [String: String] {
        guard let repo = repo(id: workspace.repoId) else {
            return WorkspaceEnvironment.make(login: loginEnvironment, claudeConfigDir: nil)
        }
        let context = WorkspaceContext(
            name: workspace.name,
            path: workspace.path,
            rootPath: repo.path,
            defaultBranch: workspace.baseRef.map(WorkspaceContext.branchName(fromBaseRef:)),
            port: workspace.port
        )
        return WorkspaceEnvironment.make(
            login: loginEnvironment,
            workspace: context,
            repoVariables: repoVariableValues(repoId: repo.id),
            claudeConfigDir: repo.claudeConfigDir
        )
    }

    private func repoVariableValues(repoId: String) -> [String: String] {
        var values: [String: String] = [:]
        for variable in repoVars(repoId: repoId) {
            guard variable.isSecret else {
                if let value = variable.value { values[variable.name] = value }
                continue
            }
            do {
                if let value = try secrets.read(account: Self.secretAccount(repoId: repoId, name: variable.name)) {
                    values[variable.name] = value
                }
            } catch {
                errorMessage = "Could not read \(variable.name) from the Keychain: \(error)"
            }
        }
        return values
    }

    private func scriptConfig(for workspace: Workspace) throws -> ScriptConfig {
        guard let repo = repo(id: workspace.repoId) else {
            return ScriptConfig(setup: nil, run: nil, archive: nil, runMode: .concurrent, source: .repoSettings)
        }
        return try ScriptConfigResolver.resolve(workspace: URL(fileURLWithPath: workspace.path), repo: repo)
    }

    private func startScript(_ script: String, title: String, in workspace: Workspace) -> PTYSession {
        let session = PTYSession(
            title: title,
            command: .script(script, environment: environment(for: workspace), cwd: URL(fileURLWithPath: workspace.path)),
            stopGracePeriod: processStopGracePeriod
        )
        session.start()
        return session
    }

    private func processesCreatingIfNeeded(for workspaceId: String) -> WorkspaceProcesses {
        if let existing = processes[workspaceId] { return existing }
        let created = WorkspaceProcesses()
        processes[workspaceId] = created
        return created
    }

    private func resolveLaunch(_ agent: AgentKind, cwd: URL, environment: [String: String]) async throws -> AgentLaunch {
        let makeLaunch = self.makeLaunch
        let paths = self.paths
        do {
            return try makeLaunch(agent, cwd, environment, paths)
        } catch AgentLauncherError.adapterNotInstalled(let kind) {
            busyMessage = kind == .claude ? "Installing the Claude adapter (one time)…" : "Installing OpenCode (one time)…"
            defer { busyMessage = nil }
            let install = installAdapter
            try await Task.detached { try install(kind, nil, paths, environment) }.value
            refreshInstalledAgentVersions()
            return try makeLaunch(agent, cwd, environment, paths)
        }
    }

    // MARK: Agent updates

    /// Reads which versions of the agents are installed (package.json files, no process).
    public func refreshInstalledAgentVersions() {
        let prefix = paths.adapterPrefix
        for kind in AgentKind.allCases {
            var version = agentVersions[kind] ?? AgentVersion(installed: nil, tested: AgentLauncher.testedVersion(for: kind))
            version.installed = AgentLauncher.installedVersion(kind, prefix: prefix)
            version.claudeCode = kind == .claude ? AgentLauncher.bundledClaudeCodeVersion(prefix: prefix) : nil
            agentVersions[kind] = version
        }
    }

    /// Asks npm for the newest version of each agent: on its own at most once a day (at launch), or now with
    /// `force`. It only checks; updating is `updateAgent`.
    public func checkAgentUpdates(force: Bool = false) async {
        if !force, let lastAgentCheck, Date().timeIntervalSince(lastAgentCheck) < Self.agentCheckInterval { return }
        guard !isCheckingAgents else { return }
        isCheckingAgents = true
        defer { isCheckingAgents = false }
        refreshInstalledAgentVersions()
        let fetch = latestVersion
        var failures: [String] = []
        for kind in AgentKind.allCases {
            do {
                agentVersions[kind]?.latest = try await fetch(AgentLauncher.package(for: kind))
            } catch {
                failures.append(kind.displayName)
            }
        }
        if failures.isEmpty {
            let now = Date()
            lastAgentCheck = now
            defaults.set(now, forKey: Self.lastAgentCheckKey)
            agentUpdateError = nil
        } else {
            agentUpdateError = "Could not reach npm for \(failures.joined(separator: " and "))."
        }
    }

    /// Installs the newest version of an agent, or with `toTested` the one this build was tested with. New
    /// conversations use it; open ones keep the version they started with until restarted.
    public func updateAgent(_ kind: AgentKind, toTested: Bool = false) async {
        guard updatingAgent == nil else { return }
        let version = toTested ? AgentLauncher.testedVersion(for: kind) : agentVersions[kind]?.latest
        guard let version else { return }
        updatingAgent = kind
        defer { updatingAgent = nil }
        let install = installAdapter
        let paths = self.paths
        let environment = loginEnvironment
        do {
            try await Task.detached { try install(kind, version, paths, environment) }.value
            agentUpdateError = nil
        } catch {
            agentUpdateError = "Could not install \(kind.displayName) \(version): \(error)"
        }
        refreshInstalledAgentVersions()
    }

    private func reload() {
        do {
            repos = try store.repos()
            var byRepo: [String: [Workspace]] = [:]
            for repo in repos { byRepo[repo.id] = try store.workspaces(repoId: repo.id) }
            workspaces = byRepo
        } catch {
            errorMessage = "\(error)"
        }
    }
}

extension ChatItem {
    init(record: ChatMessageRecord) {
        self.init(
            id: UUID(uuidString: record.id) ?? UUID(),
            kind: Kind(rawValue: record.kind) ?? .agent,
            text: record.text,
            status: record.status,
            attachments: record.attachments ?? [],
            toolKind: record.toolKind,
            createdAt: record.createdAt,
            completedAt: record.completedAt
        )
    }
}

extension ChatMessageRecord {
    init(item: ChatItem, sessionId: String) {
        self.init(
            id: item.id.uuidString,
            sessionId: sessionId,
            seq: 0,
            kind: item.kind.rawValue,
            text: item.text,
            status: item.status,
            attachments: item.attachments.isEmpty ? nil : item.attachments,
            toolKind: item.toolKind,
            createdAt: item.createdAt,
            completedAt: item.completedAt
        )
    }
}
