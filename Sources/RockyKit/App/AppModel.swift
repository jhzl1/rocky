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

/// App state: repos, their workspaces, and one running chat per workspace.
@MainActor
@Observable
public final class AppModel {
    public private(set) var repos: [Repo] = []
    public private(set) var workspaces: [String: [Workspace]] = [:]
    public var selectedWorkspaceId: String?
    public var errorMessage: String?
    public private(set) var busyMessage: String?
    public private(set) var loginEnvironment: [String: String] = [:]

    @ObservationIgnored public let store: RockyStore
    @ObservationIgnored public let paths: RockyPaths
    @ObservationIgnored private let captureEnvironment: @Sendable () throws -> [String: String]
    @ObservationIgnored private let makeLaunch: @Sendable (AgentKind, URL, [String: String], RockyPaths) throws -> AgentLaunch
    @ObservationIgnored private let installAdapter: @Sendable (RockyPaths, [String: String]) throws -> Void
    @ObservationIgnored private var chats: [String: ChatSessionModel] = [:]

    public init(
        store: RockyStore,
        paths: RockyPaths,
        captureEnvironment: @escaping @Sendable () throws -> [String: String] = { try LoginEnvironment.capture() },
        makeLaunch: @escaping @Sendable (AgentKind, URL, [String: String], RockyPaths) throws -> AgentLaunch = { kind, cwd, environment, paths in
            try AgentLauncher.launch(kind, cwd: cwd, environment: environment, adapterPrefix: paths.adapterPrefix, logsDirectory: paths.logs)
        },
        installAdapter: @escaping @Sendable (RockyPaths, [String: String]) throws -> Void = { paths, environment in
            try AgentLauncher.installClaudeAdapter(prefix: paths.adapterPrefix, environment: environment)
        }
    ) {
        self.store = store
        self.paths = paths
        self.captureEnvironment = captureEnvironment
        self.makeLaunch = makeLaunch
        self.installAdapter = installAdapter
    }

    public var selectedWorkspace: Workspace? {
        workspaces.values.joined().first { $0.id == selectedWorkspaceId }
    }

    public func repo(id: String) -> Repo? {
        repos.first { $0.id == id }
    }

    public func existingChat(workspaceId: String) -> ChatSessionModel? {
        chats[workspaceId]
    }

    /// Loads persisted state and captures the login environment once (spec Section 1).
    public func bootstrap() async {
        reload()
        await refreshEnvironment()
    }

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

    public func setClaudeConfigDir(repoId: String, _ directory: String?) {
        guard var repo = repo(id: repoId) else { return }
        repo.claudeConfigDir = (directory?.isEmpty ?? true) ? nil : directory
        do {
            try store.update(repo)
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Forgets the repo in Rocky. Its folder and worktrees stay on disk.
    public func removeRepo(id: String) async {
        for workspace in workspaces[id] ?? [] {
            await chats.removeValue(forKey: workspace.id)?.stop()
        }
        do {
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
            let workspace = Workspace(repoId: repo.id, name: created.name, path: created.path.path, branch: created.branch)
            try store.add(workspace)
            reload()
            selectedWorkspaceId = workspace.id
            if created.fetchFailed {
                errorMessage = "git fetch failed; \(created.name) was created from the last fetched \(created.baseRef)."
            }
        } catch {
            errorMessage = "Could not create a workspace: \(error)"
        }
    }

    /// Removes the worktree folder and keeps its branch. Git refuses while there are uncommitted changes.
    public func removeWorkspace(id: String) async {
        guard let workspace = workspaces.values.joined().first(where: { $0.id == id }),
              let repo = repo(id: workspace.repoId) else { return }
        await chats.removeValue(forKey: id)?.stop()
        let service = WorktreeService(environment: loginEnvironment)
        let repoURL = URL(fileURLWithPath: repo.path)
        let worktreeURL = URL(fileURLWithPath: workspace.path)
        do {
            try await Task.detached { try service.remove(repo: repoURL, worktree: worktreeURL) }.value
            try store.deleteWorkspace(id: id)
            if selectedWorkspaceId == id { selectedWorkspaceId = nil }
            reload()
        } catch {
            errorMessage = "Could not remove \(workspace.name): \(error)"
        }
    }

    /// Returns the workspace's chat for `agent`, starting it and resuming that agent's last session.
    public func openChat(workspace: Workspace, agent: AgentKind) async -> ChatSessionModel? {
        if let chat = chats[workspace.id], chat.agent == agent { return chat }
        await chats.removeValue(forKey: workspace.id)?.stop()
        guard let repo = repo(id: workspace.repoId) else { return nil }
        let environment = WorkspaceEnvironment.make(login: loginEnvironment, claudeConfigDir: repo.claudeConfigDir)
        do {
            let launch = try await resolveLaunch(agent, cwd: URL(fileURLWithPath: workspace.path), environment: environment)
            let existing = try store.latestSession(workspaceId: workspace.id, agent: agent.rawValue)
            var record = existing ?? ChatSessionRecord(workspaceId: workspace.id, agent: agent.rawValue)
            if existing == nil { try store.add(record) }
            let history = try store.messages(sessionId: record.id).map(ChatItem.init(record:))
            let store = self.store
            let recordId = record.id
            let chat = ChatSessionModel(agent: agent, launch: launch, history: history, resumeSessionId: record.acpSessionId) { item in
                try? store.upsert(ChatMessageRecord(item: item, sessionId: recordId))
            }
            chats[workspace.id] = chat
            await chat.start()
            if let sessionId = chat.sessionId, sessionId != record.acpSessionId {
                record.acpSessionId = sessionId
                try store.update(record)
            }
            return chat
        } catch {
            errorMessage = "Could not start \(agent.displayName): \(error)"
            return nil
        }
    }

    /// Called before quitting, so no agent process outlives Rocky.
    public func stopAllAgents() async {
        for chat in chats.values { await chat.stop() }
        chats.removeAll()
    }

    private func resolveLaunch(_ agent: AgentKind, cwd: URL, environment: [String: String]) async throws -> AgentLaunch {
        let makeLaunch = self.makeLaunch
        let paths = self.paths
        do {
            return try makeLaunch(agent, cwd, environment, paths)
        } catch AgentLauncherError.adapterNotInstalled {
            busyMessage = "Installing the Claude adapter (one time)…"
            defer { busyMessage = nil }
            let install = installAdapter
            try await Task.detached { try install(paths, environment) }.value
            return try makeLaunch(agent, cwd, environment, paths)
        }
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
            status: record.status
        )
    }
}

extension ChatMessageRecord {
    init(item: ChatItem, sessionId: String) {
        self.init(id: item.id.uuidString, sessionId: sessionId, seq: 0, kind: item.kind.rawValue, text: item.text, status: item.status)
    }
}
