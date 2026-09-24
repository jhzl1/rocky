import Foundation
import Observation

public struct RockyPaths: Sendable {
    public let database: URL
    public let adapterPrefix: URL
    public let logs: URL
    /// `AGT-03`'s failure logs, one folder per workspace, outside every worktree.
    public let ciLogs: URL

    /// `ciLogs` defaults to a `ci-logs` folder next to the database.
    public init(database: URL, adapterPrefix: URL, logs: URL, ciLogs: URL? = nil) {
        self.database = database
        self.adapterPrefix = adapterPrefix
        self.logs = logs
        self.ciLogs = ciLogs ?? database.deletingLastPathComponent().appendingPathComponent("ci-logs", isDirectory: true)
    }

    /// `~/Library/Application Support/Rocky` for data, the Claude adapter and the CI logs (`ci-logs`),
    /// `~/Library/Logs/Rocky` for agent stderr.
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

/// The login shell's environment, readable off the main actor by Rocky's own `gh` runs.
final class LoginEnvironmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var environment: [String: String] = [:]

    var value: [String: String] {
        get { lock.withLock { environment } }
        set { lock.withLock { environment = newValue } }
    }
}

/// Lets the pull request monitor, made in `AppModel.init` before `self` can be captured, call the model's loader.
@MainActor
final class PullRequestLoaderBox {
    weak var model: AppModel?
}

/// ACC-01's probe of one repository (`AppModel.githubReaders`): each asked login's answer, and whether they settle
/// the default. An account that did not answer leaves it open: it might have been the one to pick.
struct GitHubReadProbe: Sendable {
    var canRead: [String: Bool] = [:]
    var isSettled = true
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

/// What `GST-02`'s Pull does once its git steps ran: send the agent to commit first, report a fast-forward, or send the
/// agent to merge or rebase a diverged branch.
enum BaseSyncStep: Equatable, Sendable {
    case commitFirst, fastForwarded
    case diverged(rebase: Bool)
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
    public var selectedWorkspaceId: String? {
        didSet {
            // Seeing a workspace reads what finished there (ROW-04).
            if let selectedWorkspaceId, isWindowActive { unreadWorkspaceIds.remove(selectedWorkspaceId) }
            // Opened again at the next launch (user decision, 2026-09-23).
            defaults.set(selectedWorkspaceId, forKey: Self.lastWorkspaceKey)
            // The repository account's token, so the workspace's first process does not wait for gh (ENV-01).
            if let workspace = selectedWorkspace {
                Task { await prepareEnvironment(for: workspace) }
            }
            // PR-07: the selected workspace's pull request refreshes at once, then on the schedule.
            pullRequests.select(selectedWorkspaceId)
        }
    }
    /// Workspaces where a turn ended or failed while the user was not watching them: another workspace was selected,
    /// or Rocky's window was in the background (ROW-04). In memory only (user decision).
    public private(set) var unreadWorkspaceIds: Set<String> = []
    /// Whether Rocky's window is active, i.e. the user is looking at Rocky; set by the window. Coming back to it reads
    /// the selected workspace.
    public var isWindowActive = true {
        didSet {
            if isWindowActive, let selectedWorkspaceId { unreadWorkspaceIds.remove(selectedWorkspaceId) }
            // PR-07: a refresh on return; polling itself follows `isWindowVisible`.
            pullRequests.windowKeyChanged(isWindowActive)
        }
    }
    /// Whether any of Rocky's window can be seen (not minimized, hidden, fully covered or on another Space); set by
    /// the window. PR-07 polls while it can, even with another app in front (user decision, 2026-09-24).
    public var isWindowVisible = true {
        didSet { pullRequests.windowVisibilityChanged(isWindowVisible) }
    }
    /// Plays the alert sound; set by the app. Called only for what the user is not watching (user decision,
    /// 2026-09-23: a sound and the Dock's number, no system notification).
    @ObservationIgnored public var onAlert: (@MainActor (ChatAttention) -> Void)?
    /// Each workspace's task title (ROW-02), from `RockyStore.conversationTitles()`.
    public private(set) var workspaceTitles: [String: String] = [:]
    public var errorMessage: String?
    public var archiveFailure: ArchiveFailure?
    public private(set) var busyMessage: String?
    public private(set) var loginEnvironment: [String: String] = [:] {
        didSet { loginBox.value = loginEnvironment }
    }
    /// The GitHub accounts of `gh` and their tokens (ACC-01), in memory only.
    @ObservationIgnored public let githubAccounts: GitHubAccounts
    /// The login environment for Rocky's own `gh` runs, which happen off the main actor.
    @ObservationIgnored private let loginBox: LoginEnvironmentBox
    @ObservationIgnored private let lookUpGitHubRepository: @Sendable (URL, [String: String]) -> GitHubRepository?
    /// Each repository's GitHub remote, looked up once per launch (`git remote get-url origin`, `ssh -G`).
    @ObservationIgnored private var githubRepositoryLookups: [String: Task<GitHubRepository?, Never>] = [:]
    /// Each repository's default account as last resolved, for `environment(for:)`, which cannot wait for gh.
    @ObservationIgnored private var defaultGitHubLogins: [String: String] = [:]
    /// ACC-01's probe of each repository whose owner is no login: which accounts can read it, asked once per launch
    /// for the order of logins it was asked with, so a new `gh auth login` (read again by the settings) asks again.
    @ObservationIgnored private var githubReadProbes: [String: (order: [String], probe: Task<GitHubReadProbe, Never>)] = [:]
    /// Each workspace's pull request panel and its refresh schedule (PR-07). Views observe it directly.
    @ObservationIgnored public let pullRequests: PullRequestMonitor
    /// Rocky's one GitHub session (ephemeral: nothing reaches the disk); tests pass a stub.
    @ObservationIgnored private let githubSession: URLSession
    /// One client per login, each reading that login's token from `githubAccounts`.
    @ObservationIgnored private var githubClients: [String: GitHubClient] = [:]
    /// The pull request head each workspace last fetched its branch for (GST-01's upstream fetch), so a head is
    /// fetched once, even when the fetch failed.
    @ObservationIgnored private var fetchedPullRequestHeads: [String: String] = [:]
    /// Each repository's GitHub remote once looked up, for what cannot wait for the lookup (the compare URL).
    @ObservationIgnored private var knownGitHubRepositories: [String: GitHubRepository] = [:]
    /// Shows a line in the window's toast (`GST-02`, `GST-03`, `ERR-01`); set by the app.
    @ObservationIgnored public var onToast: (@MainActor (String) -> Void)?
    /// The tab each workspace's right panel shows (`PNL-03`), in memory; none is Checks.
    public var rightPanelTabs: [String: RightPanelTab] = [:]
    /// The pull request actions running in each workspace, so their buttons spin and ignore a second click.
    public private(set) var runningPullRequestActions: [String: Set<PullRequestAction>] = [:]
    /// `PR-05`: the merge method each workspace picked from the menu, until Rocky quits (user decision: never stored).
    private var mergeMethodPicks: [String: MergeMethod] = [:]
    /// `PR-05`'s first click: the workspaces whose merge button says "Confirm …", each with the token of its window, so
    /// an older window's end does not cancel a newer one.
    private var mergeConfirmations: [String: UUID] = [:]
    /// `PR-05`'s errors, shown under the header until the next merge, another method or their ×.
    public private(set) var mergeErrors: [String: String] = [:]
    /// `SET-01`: archive a workspace when Rocky sees its pull request merge. Off by default (Conductor's
    /// `archive_on_merge`).
    public var archiveOnMerge = false {
        didSet { defaults.set(archiveOnMerge, forKey: Self.archiveOnMergeKey) }
    }
    static let archiveOnMergeKey = "archiveOnMerge"

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
    /// Kept across launches with the selected workspace, so Rocky reopens the last session.
    public private(set) var selectedConversationIds: [String: String] = [:] {
        didSet { defaults.set(selectedConversationIds, forKey: Self.lastConversationsKey) }
    }
    /// The first read of the login shell's environment, at launch. The last session's workspace is selected before it
    /// ends, so the window shows it at once; its agents wait for this, or they would start without the user's PATH.
    @ObservationIgnored private var launchEnvironment: Task<Void, Never>?
    private static let lastWorkspaceKey = "lastWorkspaceId"
    private static let lastConversationsKey = "lastConversationIds"
    /// Files opened in tabs next to the conversations (from a file badge), by workspace. Kept only while Rocky runs.
    public private(set) var openFiles: [String: [String]] = [:]
    /// The file tab each workspace shows instead of its conversation; none shows the selected conversation.
    public private(set) var selectedFiles: [String: String] = [:]
    /// The last command list each repository's agent announced (KIT-01), so a new conversation has one while its own
    /// agent starts. In memory only: the agent sends it again after every start. Observed: the popup shows it.
    private var lastCommands: [CommandListKey: [SlashCommand]] = [:]

    private struct CommandListKey: Hashable {
        let repoId: String
        let agent: AgentKind
    }
    /// Observed for the same reason as `chats`. Created only in actions, never while a view reads it.
    private var processes: [String: WorkspaceProcesses] = [:]
    /// CMD-08: the terminal each conversation runs a Claude Code terminal command in, keyed by conversation. At most
    /// one per conversation, kept only while Rocky runs. Observed: the conversation's view shows it.
    private var embeddedTerminals: [String: EmbeddedTerminal] = [:]

    private struct EmbeddedTerminal {
        let workspaceId: String
        let session: PTYSession
    }

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
        processStopGracePeriod: Duration = .seconds(5),
        runGH: @escaping @Sendable (_ arguments: [String], _ environment: [String: String]) throws -> String = { arguments, environment in
            try GitHubCLI.run(arguments, environment: environment)
        },
        lookUpGitHubRepository: @escaping @Sendable (_ clone: URL, _ environment: [String: String]) -> GitHubRepository? = { clone, environment in
            GitHubRemote.repository(ofClone: clone, environment: environment)
        },
        githubSession: URLSession = GitHubClient.makeSession()
    ) {
        let loaderBox = PullRequestLoaderBox()
        self.pullRequests = PullRequestMonitor(store: store, load: { workspaceId, includeLocal, comments in
            guard let model = loaderBox.model else { throw CancellationError() }
            return try await model.loadPullRequest(workspaceId: workspaceId, includeLocal: includeLocal, comments: comments)
        })
        self.githubSession = githubSession
        let loginBox = LoginEnvironmentBox()
        self.loginBox = loginBox
        // Rocky's own gh runs get the login environment without GH_TOKEN and GITHUB_TOKEN, or gh would report the
        // variable's account instead of the keyring's.
        self.githubAccounts = GitHubAccounts(runGH: { arguments in
            try runGH(arguments, GitHubCLI.environment(from: loginBox.value))
        })
        self.lookUpGitHubRepository = lookUpGitHubRepository
        self.store = store
        self.paths = paths
        self.captureEnvironment = captureEnvironment
        self.makeLaunch = makeLaunch
        self.installAdapter = installAdapter
        self.latestVersion = latestVersion
        self.defaults = defaults
        self.lastAgentCheck = defaults.object(forKey: Self.lastAgentCheckKey) as? Date
        self.selectedConversationIds = defaults.dictionary(forKey: Self.lastConversationsKey) as? [String: String] ?? [:]
        self.archiveOnMerge = defaults.bool(forKey: Self.archiveOnMergeKey)
        self.secrets = secrets
        self.terminalShell = terminalShell
        self.processStopGracePeriod = processStopGracePeriod
        loaderBox.model = self
        // SET-01: a merge the monitor sees may archive its workspace.
        pullRequests.onMerged = { [weak self] workspaceId in self?.pullRequestMerged(workspaceId: workspaceId) }
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

    /// The slash commands `chat`'s message box offers (CMD-05): its own list once its agent has announced one
    /// (`confirmed`), else the last list of its repository and agent, possibly empty, until its own arrives. A Claude
    /// Code list has the terminal commands too (CMD-08, `TerminalOnlyCommand.offered`).
    public func commands(for chat: ChatSessionModel) -> (commands: [SlashCommand], confirmed: Bool) {
        let (commands, confirmed) = announcedCommands(for: chat)
        return (TerminalOnlyCommand.offered(commands, agent: chat.agent, confirmed: confirmed), confirmed)
    }

    private func announcedCommands(for chat: ChatSessionModel) -> (commands: [SlashCommand], confirmed: Bool) {
        if chat.commandsReceived { return (chat.commands, true) }
        guard let conversationId = chats.first(where: { $0.value === chat })?.key,
              let workspaceId = chatWorkspaceIds[conversationId],
              let repoId = workspace(id: workspaceId)?.repoId else { return ([], false) }
        return (lastCommands[CommandListKey(repoId: repoId, agent: chat.agent)] ?? [], false)
    }

    /// Whether an agent is working in any of the workspace's conversations (the sidebar's progress arc).
    public func isAgentWorking(workspaceId: String) -> Bool {
        chats.contains { chatWorkspaceIds[$0.key] == workspaceId && $0.value.state == .running }
    }

    /// The workspace's sidebar state (ROW-03, ROW-07): needs you › error › working › unread › pull request › merged ›
    /// idle. The pull request comes from its stored state (PR-07), so every workspace shows one, also after a relaunch.
    public func status(workspaceId: String) -> WorkspaceStatus {
        let own = chats.filter { chatWorkspaceIds[$0.key] == workspaceId }.map(\.value)
        return WorkspaceStatus.resolve(
            needsYou: own.contains { $0.pendingPermission != nil || $0.pendingQuestion != nil },
            failure: own.lazy.compactMap(\.failure).first ?? setupFailure(workspaceId: workspaceId),
            working: own.contains { $0.state == .running },
            unread: unreadWorkspaceIds.contains(workspaceId),
            pullRequest: pullRequests.panels[workspaceId]?.stored
        )
    }

    /// The row's title: the task title, or the workspace name (drawn dimmer) until a conversation has one (ROW-02).
    public func title(for workspace: Workspace) -> (text: String, isFallback: Bool) {
        if let title = workspaceTitles[workspace.id] { return (title, false) }
        return (workspace.name, true)
    }

    private func setupFailure(workspaceId: String) -> String? {
        guard let setup = processes[workspaceId]?.setup, !setup.stopRequested else { return nil }
        return switch setup.state {
        case .exited(let code) where code != 0: "Setup exited with \(code). See the Setup tab."
        case .failedToStart: "Setup could not start. See the Setup tab."
        default: nil
        }
    }

    /// The Dock's number: workspaces with something unread or an agent waiting for you, except the one on screen.
    public var attentionCount: Int {
        let waiting = chats.compactMap { id, chat in
            chat.pendingPermission != nil || chat.pendingQuestion != nil ? chatWorkspaceIds[id] : nil
        }
        var workspaceIds = unreadWorkspaceIds.union(waiting)
        if isWindowActive, let selectedWorkspaceId { workspaceIds.remove(selectedWorkspaceId) }
        return workspaceIds.count
    }

    /// A conversation's news reaches the user only when they are not watching its workspace: another one is
    /// selected, or the window is in the background. A turn that ended or failed also marks it unread (ROW-04).
    private func attention(_ kind: ChatAttention, workspaceId: String) {
        // AGT-00, PR-07: a turn that ends refreshes its workspace's pull request, watched or not.
        if kind == .finished || kind == .failed {
            Task { await pullRequests.refresh(workspaceId: workspaceId, reason: .turnEnded) }
        }
        let isWatching = isWindowActive && selectedWorkspaceId == workspaceId
        guard !isWatching else { return }
        if kind != .needsYou { unreadWorkspaceIds.insert(workspaceId) }
        onAlert?(kind)
    }

    private func refreshWorkspaceTitles() {
        if let titles = try? store.conversationTitles() { workspaceTitles = titles }
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
        let environment = Task { await refreshEnvironment() }
        launchEnvironment = environment
        // The last session: the workspace that was on screen, which shows its last conversation.
        if selectedWorkspaceId == nil, let last = defaults.string(forKey: Self.lastWorkspaceKey), workspace(id: last) != nil {
            selectedWorkspaceId = last
        }
        await environment.value
        refreshInstalledAgentVersions()
        // Once a day at most: one HTTPS request per agent, no timer.
        Task { await checkAgentUpdates() }
    }

    /// Captures the login shell environment again (menu "Refresh Shell Environment"). Running processes keep the
    /// environment they started with.
    public func refreshEnvironment() async {
        let capture = captureEnvironment
        do {
            loginEnvironment = try await Task.blocking { try capture() }.value
        } catch {
            loginEnvironment = ProcessInfo.processInfo.environment
            errorMessage = "Could not read your login shell environment (\(error)). Agents use Rocky's own environment."
        }
    }

    public func addRepo(at url: URL) async {
        let service = WorktreeService(environment: loginEnvironment)
        let isRoot = await Task.blocking { service.isRepositoryRoot(url) }.value
        guard isRoot else {
            errorMessage = "\(url.path) is not the root of a git repository."
            return
        }
        do {
            let color = RepoMonogram.pickColor(used: repos.compactMap(\.colorIndex))
            try store.add(Repo(name: url.lastPathComponent, path: url.path, colorIndex: color))
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
        // The conversation on screen reopens at once with the new instance: its view only opens a conversation when
        // the workspace appears, so it waited on "Opening the conversation…" until the user left and came back (user
        // report, 2026-09-24). Other workspaces reopen theirs when selected, so no agent starts unseen.
        if let selected = selectedWorkspace, selected.repoId == repoId,
           let conversationId = selectedConversationIds[selected.id], chats[conversationId] == nil {
            await showConversation(workspace: selected, conversationId: conversationId)
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

    /// Saves the paths or globs, one per line, that new workspaces of the repo get linked from the main clone on top
    /// of the environment files `WorktreeLinker` finds on its own, and the `!<pattern>` lines turning those defaults
    /// off (`LinkedPaths.Setting.text`). Stored one clean entry per line; blank is none.
    public func setLinkedPaths(repoId: String, _ text: String) {
        guard var repo = repo(id: repoId) else { return }
        let entries = ScriptConfigResolver.linkEntries(text)
        repo.linkedPaths = entries.isEmpty ? nil : entries.joined(separator: "\n")
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
            let created = try await Task.blocking {
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
            // rocky.json is read from the new worktree. When it is invalid, Setup does not run and the links come
            // from the repo settings alone.
            var config: ScriptConfig?
            do {
                config = try scriptConfig(for: workspace)
            } catch {
                errorMessage = "\(error)"
            }
            // Before Setup, which may read the environment files (a migration reading DATABASE_URL from .env).
            await linkMainCloneFiles(
                into: workspace,
                repo: repo,
                extraEntries: config?.links ?? ScriptConfigResolver.linkEntries(repo.linkedPaths)
            )
            // Setup runs once, right after the worktree exists (spec Section 3). A failure shows in its tab and
            // leaves the workspace usable.
            if let setup = config?.setup {
                await prepareEnvironment(for: workspace)
                processesCreatingIfNeeded(for: workspace.id).setup = startScript(setup, title: "Setup", in: workspace)
            }
        } catch {
            errorMessage = "Could not create a workspace: \(error)"
        }
    }

    /// Symlinks the main clone's environment files and `extraEntries` into a new workspace (see `WorktreeLinker`).
    /// A problem is added to `errorMessage` and never stops the workspace or its Setup.
    ///
    /// `git worktree add` has already run the repo's post-checkout hook, and a repo whose hook runs its own
    /// setup-worktree script (veritas, celes-platform) has these links by now. The linker leaves every existing
    /// destination alone, so either one may run first.
    private func linkMainCloneFiles(into workspace: Workspace, repo: Repo, extraEntries: [String]) async {
        let linker = WorktreeLinker(environment: loginEnvironment)
        let mainClone = URL(fileURLWithPath: repo.path)
        let worktree = URL(fileURLWithPath: workspace.path)
        let problem: String?
        do {
            let result = try await Task.blocking {
                try linker.link(mainClone: mainClone, into: worktree, extraEntries: extraEntries)
            }.value
            problem = result.rejected.isEmpty ? nil : Self.rejectedLinksMessage(result.rejected, workspaceName: workspace.name)
        } catch {
            problem = "Could not link the main folder's environment files into \(workspace.name): \(error)"
        }
        guard let problem else { return }
        // An earlier problem of the same creation, such as a failed fetch, stays in the message.
        errorMessage = [errorMessage, problem].compactMap { $0 }.joined(separator: " ")
    }

    static func rejectedLinksMessage(_ rejected: [String], workspaceName: String) -> String {
        let list = rejected.map { "\"\($0)\"" }.joined(separator: ", ")
        return "Rocky did not link \(list) into \(workspaceName): linked files must be paths inside the main folder."
    }

    /// Stops the workspace's agent, scripts and terminals, runs its archive script, then removes the worktree
    /// folder and keeps its branch. A failing archive script deletes nothing and sets `archiveFailure`;
    /// `skipArchive` is the user's "Remove Anyway". Git still refuses while there are uncommitted changes, unless
    /// `stashingChanges` (PR-06's "Archive anyway") puts them in a git stash of the repository first.
    public func removeWorkspace(id: String, skipArchive: Bool = false, stashingChanges: Bool = false) async {
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
                await prepareEnvironment(for: workspace)
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
        let branchService = GitBranchService(environment: loginEnvironment)
        let repoURL = URL(fileURLWithPath: repo.path)
        let worktreeURL = URL(fileURLWithPath: workspace.path)
        let stashMessage = stashingChanges ? "Rocky archived \(workspace.name)" : nil
        do {
            try await Task.blocking {
                if let stashMessage { try branchService.stashAll(worktree: worktreeURL, message: stashMessage) }
                try service.remove(repo: repoURL, worktree: worktreeURL)
            }.value
            try store.deleteWorkspace(id: id)
            processes.removeValue(forKey: id)
            fetchedPullRequestHeads[id] = nil
            rightPanelTabs[id] = nil
            mergeMethodPicks[id] = nil
            mergeConfirmations[id] = nil
            mergeErrors[id] = nil
            if selectedWorkspaceId == id { selectedWorkspaceId = nil }
            reload()
            // AGT-03's logs live outside the worktree, so they go with the workspace.
            let ciLogs = CILogs.folder(for: id, in: paths.ciLogs)
            await Task.blocking { _ = try? FileManager.default.removeItem(at: ciLogs) }.value
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
        await launchEnvironment?.value
        await prepareEnvironment(for: workspace)
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
        chat.onAttention = { [weak self] kind in self?.attention(kind, workspaceId: workspaceId) }
        let commandKey = CommandListKey(repoId: current.repoId, agent: agent)
        chat.onCommands = { [weak self] commands in self?.lastCommands[commandKey] = commands }
        chats[conversationId] = chat
        chatWorkspaceIds[conversationId] = workspaceId
        return chat
    }

    /// The conversation's first message that is not a command names it (TITLE-01); a command leaves it untitled.
    private func titleIfNeeded(conversationId: String, workspaceId: String, from text: String) {
        guard var record = try? store.session(id: conversationId), record.title == nil,
              let title = Self.title(from: text, commands: knownCommands(for: record)) else { return }
        record.title = title
        try? store.update(record)
        reloadConversations(workspaceId: workspaceId)
    }

    private func reloadConversations(workspaceId: String) {
        var open = (try? store.openConversations(workspaceId: workspaceId)) ?? []
        // Conversations saved before titles existed get one from their first message that is not a command.
        for index in open.indices where open[index].title == nil {
            let commands = knownCommands(for: open[index])
            let userMessages = ((try? store.messages(sessionId: open[index].id)) ?? []).lazy
                .filter { $0.kind == ChatItem.Kind.user.rawValue }
            guard let title = userMessages.compactMap({ Self.title(from: $0.text, commands: commands) }).first else { continue }
            open[index].title = title
            try? store.update(open[index])
        }
        conversations[workspaceId] = open
        refreshWorkspaceTitles()
    }

    /// The list the title rule checks for a conversation: its chat's own, else the last one of its repository and
    /// agent; nil while neither has arrived.
    private func knownCommands(for record: ChatSessionRecord) -> [SlashCommand]? {
        if let chat = chats[record.id], chat.commandsReceived { return chat.commands }
        guard let agent = AgentKind(rawValue: record.agent), let repoId = workspace(id: record.workspaceId)?.repoId else { return nil }
        return lastCommands[CommandListKey(repoId: repoId, agent: agent)]
    }

    /// TITLE-01's rule. While the conversation's list is unknown (at launch, before any agent has started), a message
    /// that starts with "/name" counts as a command: a wrong title stays for good, a missing one comes with the next
    /// message.
    nonisolated static func title(from message: String, commands: [SlashCommand]?) -> String? {
        guard let commands else {
            return SlashCommand.leadingName(in: message) == nil ? ChatSessionRecord.title(from: message) : nil
        }
        return ChatSessionRecord.title(from: message, commands: commands)
    }

    /// Stops the conversation's agent and its embedded terminal (closing the tab, changing the Claude instance).
    private func stopChat(conversationId: String) async {
        chatWorkspaceIds[conversationId] = nil
        await chats.removeValue(forKey: conversationId)?.stop()
        await closeEmbeddedTerminal(conversationId: conversationId)
    }

    /// The workspace's agents and embedded terminals (removing it or its repository).
    private func stopChats(workspaceId: String) async {
        for (conversationId, owner) in chatWorkspaceIds where owner == workspaceId {
            await stopChat(conversationId: conversationId)
        }
        for (conversationId, terminal) in embeddedTerminals where terminal.workspaceId == workspaceId {
            await closeEmbeddedTerminal(conversationId: conversationId)
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
        let embedded = embeddedTerminals.values.map(\.session)
        embeddedTerminals.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for workspaceProcesses in all {
                group.addTask { await workspaceProcesses.stopAll() }
            }
            for session in embedded {
                group.addTask { await session.stop() }
            }
        }
    }

    // MARK: Terminal commands

    /// The conversation's embedded terminal (CMD-08), running or finished; nil when none is open.
    public func embeddedTerminal(conversationId: String) -> PTYSession? {
        embeddedTerminals[conversationId]?.session
    }

    /// Opens the conversation's embedded terminal on one of Claude Code's terminal commands (CMD-08), replacing the
    /// one it had. It runs Rocky's own Claude Code directly, not through a shell, so its exit is the "finished"
    /// signal (Conductor types the command into a shell instead): the command and its arguments are its one
    /// argument, the worktree its folder, and the workspace environment its own, the repository's
    /// `CLAUDE_CONFIG_DIR` included, so it reads the configuration of the conversation's Claude instance. It does
    /// not resume the conversation's session. nil, with `errorMessage` set, when Claude Code is not installed.
    @discardableResult
    public func openEmbeddedTerminal(conversationId: String, command: TerminalOnlyCommand) async -> PTYSession? {
        let workspaceId = chatWorkspaceIds[conversationId] ?? (try? store.session(id: conversationId))?.workspaceId
        await launchEnvironment?.value
        guard let workspaceId, let workspace = self.workspace(id: workspaceId) else { return nil }
        guard let claude = AgentLauncher.installedClaudeCodeBinary(prefix: paths.adapterPrefix) else {
            errorMessage = "Rocky's Claude Code is not installed yet. Start a Claude Code conversation, then run \(command.label) again."
            return nil
        }
        var environment = self.environment(for: workspace)
        // Rocky installs its agents at the versions it was tested with; this copy must not update itself.
        environment["DISABLE_AUTOUPDATER"] = "1"
        let session = PTYSession(
            title: command.label,
            command: PTYCommand(
                executable: claude.path,
                arguments: [command.prompt],
                environment: environment,
                cwd: URL(fileURLWithPath: workspace.path)
            ),
            // What closing a terminal window sends, as for the panel's terminals.
            stopSignal: SIGHUP,
            stopGracePeriod: processStopGracePeriod
        )
        let previous = embeddedTerminals.updateValue(EmbeddedTerminal(workspaceId: workspaceId, session: session), forKey: conversationId)
        await previous?.session.stop()
        // Closed while the previous one stopped: it never starts.
        guard embeddedTerminals[conversationId]?.session === session else { return nil }
        session.start()
        return session
    }

    /// Stops the conversation's embedded terminal if it still runs, and closes it (CMD-08's Done and ×).
    public func closeEmbeddedTerminal(conversationId: String) async {
        guard let terminal = embeddedTerminals.removeValue(forKey: conversationId) else { return }
        await terminal.session.stop()
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
        await prepareEnvironment(for: workspace)
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

    /// Opens a terminal tab: the login shell, in the worktree, with the workspace environment. It waits for the
    /// repository account's token the first time (ENV-01).
    @discardableResult
    public func openTerminal(workspaceId: String) async -> PTYSession? {
        guard let found = self.workspace(id: workspaceId) else { return nil }
        await prepareEnvironment(for: found)
        // Re-read: the workspace may have been removed or renamed meanwhile.
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
            githubToken: githubToken(for: repo),
            repoVariables: repoVariableValues(repoId: repo.id),
            claudeConfigDir: repo.claudeConfigDir
        )
    }

    // MARK: GitHub account (ACC-01, ENV-01)

    /// The repository's GitHub remote, from `git remote get-url origin` (and `ssh -G` for an SSH alias), looked up
    /// once per launch. nil when origin is missing or not on github.com.
    public func githubRepository(for repo: Repo) async -> GitHubRepository? {
        await launchEnvironment?.value
        let lookup: Task<GitHubRepository?, Never>
        if let running = githubRepositoryLookups[repo.id] {
            lookup = running
        } else {
            let lookUp = lookUpGitHubRepository
            let clone = URL(fileURLWithPath: repo.path)
            let environment = loginEnvironment
            lookup = Task.blocking { lookUp(clone, environment) }
            githubRepositoryLookups[repo.id] = lookup
        }
        let repository = await lookup.value
        knownGitHubRepositories[repo.id] = repository
        return repository
    }

    /// The repository's account: its setting, else the default (`defaultGitHubLogin(for:)`).
    public func githubLogin(for repo: Repo) async -> String? {
        let current = self.repo(id: repo.id) ?? repo
        if let login = current.githubLogin { return login }
        return await defaultGitHubLogin(for: current)
    }

    /// ACC-01's default: the gh login equal to the remote's owner; else, for a repository whose owner is no login (an
    /// organization's), the first account, the active one first, whose token can read it (`githubReaders`); else gh's
    /// active account. nil for a repository without a GitHub remote, and when gh is missing or has no account.
    public func defaultGitHubLogin(for repo: Repo) async -> String? {
        var login: String?
        if let repository = await githubRepository(for: repo) {
            do {
                let logins = try await githubAccounts.logins()
                let active = try await githubAccounts.activeLogin()
                let order = GitHubAccounts.readProbeOrder(owner: repository.owner, logins: logins, active: active)
                let canRead = order.isEmpty ? [:] : await githubReaders(of: repository, repoId: repo.id, order: order)
                login = GitHubAccounts.defaultLogin(owner: repository.owner, logins: logins, active: active, canRead: canRead)
            } catch {
                // No gh or no account: the panel says "GitHub access required" (ERR-01).
            }
        }
        defaultGitHubLogins[repo.id] = login
        return login
    }

    /// ACC-01's probe: asks the logins of `order` in turn whether their token can read the repository, one request
    /// each (`GitHubClient.canRead`), and stops at the first that can. Asked once per launch for each repository and
    /// order, never on a timer, and shared by concurrent callers. A probe that an account left unanswered (offline,
    /// rate limited) is asked again by the next caller, since that account might have come first.
    private func githubReaders(of repository: GitHubRepository, repoId: String, order: [String]) async -> [String: Bool] {
        let probe: Task<GitHubReadProbe, Never>
        if let known = githubReadProbes[repoId], known.order == order {
            probe = known.probe
        } else {
            let clients = order.map { (login: $0, client: githubClient(login: $0)) }
            probe = Task { await Self.probeReaders(of: repository, clients: clients) }
            githubReadProbes[repoId] = (order, probe)
        }
        let result = await probe.value
        if !result.isSettled, githubReadProbes[repoId]?.probe == probe {
            githubReadProbes[repoId] = nil
        }
        return result.canRead
    }

    /// A login gh has no token for cannot read; any other failure leaves the login unanswered.
    private static func probeReaders(of repository: GitHubRepository, clients: [(login: String, client: GitHubClient)]) async -> GitHubReadProbe {
        var result = GitHubReadProbe()
        for (login, client) in clients {
            do {
                let readable = try await client.canRead(repository: repository)
                result.canRead[login] = readable
                if readable { return result }
            } catch is GitHubAccountError {
                result.canRead[login] = false
            } catch {
                result.isSettled = false
            }
        }
        return result
    }

    /// Stores the repository's account; nil goes back to the default. Running agents, terminals and scripts keep the
    /// token they started with; the next process of the repository gets the new account's (ENV-01).
    public func setGitHubLogin(repoId: String, _ login: String?) {
        guard var repo = repo(id: repoId) else { return }
        let chosen = (login?.isEmpty ?? true) ? nil : login
        guard chosen != repo.githubLogin else { return }
        repo.githubLogin = chosen
        do {
            try store.update(repo)
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Fetches the repository account's token once per launch, so `environment(for:)` can give it to a process as
    /// `GH_TOKEN`. Every place that starts a workspace process awaits it first. A failure does not stop the process:
    /// it starts without the token, and the panel says "GitHub access required" (ERR-01).
    public func prepareEnvironment(for workspace: Workspace) async {
        await launchEnvironment?.value
        guard let repo = repo(id: workspace.repoId), let login = await githubLogin(for: repo) else { return }
        _ = try? await githubAccounts.token(for: login)
    }

    /// The token fetched for the repository's account in this launch, if any. Never runs gh.
    private func githubToken(for repo: Repo) -> String? {
        guard let login = repo.githubLogin ?? defaultGitHubLogins[repo.id] else { return nil }
        return githubAccounts.cachedToken(for: login)
    }

    // MARK: Pull request (PR-07)

    /// What the workspace's panel header shows (HDR-02, ERR-01): "Working…" while its selected conversation's turn
    /// runs (AGT-00).
    public func pullRequestHeader(workspaceId: String) -> HeaderPresentation {
        let working = existingChat(workspaceId: workspaceId)?.state == .running
        return (pullRequests.panels[workspaceId] ?? PullRequestPanelState()).header(agentWorking: working)
    }

    /// The GitHub client of a login: every request carries that login's token, fetched once per launch (ACC-01).
    func githubClient(login: String) -> GitHubClient {
        if let client = githubClients[login] { return client }
        let accounts = githubAccounts
        let client = GitHubClient(session: githubSession, token: { try await accounts.token(for: login) })
        githubClients[login] = client
        return client
    }

    /// The monitor's loader: the repository and its account (ACC-01), the branch's local status on event triggers
    /// only (GST-01), the snapshot against the base (Decisions), and the pending comments while they are visible
    /// (REV-01). A tick runs no git and no gh.
    func loadPullRequest(workspaceId: String, includeLocal: Bool, comments: Bool) async throws -> (PullRequestSnapshot, LocalGitStatus?, [PendingComment]?) {
        await launchEnvironment?.value
        guard let workspace = self.workspace(id: workspaceId), let repo = self.repo(id: workspace.repoId) else {
            throw CancellationError()
        }
        guard let repository = await githubRepository(for: repo) else { throw PullRequestLoadError.noGitHubRemote }
        let login = await githubLogin(for: repo)
        pullRequests.setLogin(login, workspaceId: workspaceId)
        guard let login else { throw GitHubAccountError.notLoggedIn(nil) }
        let client = githubClient(login: login)
        let previous = pullRequests.panels[workspaceId]
        let known = previous?.snapshot?.pullRequest

        var local: LocalGitStatus?
        if includeLocal {
            let gitBase = known.map { "origin/\($0.baseRefName)" } ?? workspace.baseRef
            local = await localStatus(of: workspace, base: gitBase)
        }
        // The live branch, so a branch the agent renamed keeps its pull request (Decisions).
        let branch = local?.branch ?? previous?.local?.branch ?? workspace.branch
        // The pull request's base once known, else the workspace's; nil compares with the default branch.
        let base = known?.baseRefName ?? workspace.baseRef.map(WorkspaceContext.branchName(fromBaseRef:))
        var snapshot = try await client.snapshot(repository: repository, branch: branch, base: base)
        if let pr = snapshot.pullRequest, pr.baseRefName != (base ?? snapshot.repository.defaultBranchName) {
            // The first sight of a pull request whose base is another branch: its base names every label and compare.
            snapshot = try await client.snapshot(repository: repository, branch: branch, base: pr.baseRefName)
        }
        if includeLocal, let pr = snapshot.pullRequest, !pr.isMerged, let current = local {
            local = await fetchPullRequestHead(pr, workspace: workspace) ?? current
        }
        var pending: [PendingComment]?
        if comments, let pr = snapshot.pullRequest, !pr.isMerged {
            // Comments failing leave the last ones on screen; the snapshot still counts.
            pending = try? await client.pendingComments(repository: repository, number: pr.number)
        }
        return (snapshot, local, pending)
    }

    /// GST-01's local status, off the main actor; nil when git fails (the worktree is gone, for example).
    private func localStatus(of workspace: Workspace, base: String?) async -> LocalGitStatus? {
        let service = GitBranchService(environment: environment(for: workspace))
        let worktree = URL(fileURLWithPath: workspace.path)
        return await Task.blocking { try? service.status(worktree: worktree, base: base) }.value
    }

    /// GST-01's upstream: when GitHub's head differs from `refs/remotes/origin/<branch>`, fetch the branch once, so
    /// ahead and behind the upstream are current. Returns the status after the fetch; nil when nothing was fetched.
    private func fetchPullRequestHead(_ pr: PullRequestInfo, workspace: Workspace) async -> LocalGitStatus? {
        guard fetchedPullRequestHeads[workspace.id] != pr.headRefOid, !pr.headRefOid.isEmpty else { return nil }
        fetchedPullRequestHeads[workspace.id] = pr.headRefOid
        let service = GitBranchService(environment: environment(for: workspace))
        let worktree = URL(fileURLWithPath: workspace.path)
        let branch = pr.headRefName
        let head = pr.headRefOid
        let base = "origin/\(pr.baseRefName)"
        return await Task.blocking { () -> LocalGitStatus? in
            guard service.remoteBranchOid(worktree: worktree, branch: branch) != head else { return nil }
            guard (try? service.fetch(worktree: worktree, branch: branch)) != nil else { return nil }
            return try? service.status(worktree: worktree, base: base)
        }.value
    }

    // MARK: Pull request actions (GST-03, CHK-02)

    /// The base every label, prompt and compare names (Decisions): the pull request's once there is one, else the
    /// workspace's `baseRef` as a branch name, else the repository's default branch (Open question 9).
    public func pullRequestBase(workspaceId: String) -> String? {
        let snapshot = pullRequests.panels[workspaceId]?.snapshot
        if let base = snapshot?.pullRequest?.baseRefName { return base }
        if let baseRef = workspace(id: workspaceId)?.baseRef { return WorkspaceContext.branchName(fromBaseRef: baseRef) }
        return snapshot?.repository.defaultBranchName
    }

    public func isRunning(_ action: PullRequestAction, workspaceId: String) -> Bool {
        runningPullRequestActions[workspaceId]?.contains(action) == true
    }

    /// `GST-03`'s Pull, `git pull --ff-only`. Not with uncommitted changes, whose button says "Commit or discard the
    /// changes first".
    public func pullBranch(workspaceId: String) async {
        guard let workspace = workspace(id: workspaceId),
              (pullRequests.panels[workspaceId]?.local?.uncommitted ?? 0) == 0 else { return }
        await runBranchStep(.pull, workspace: workspace) { service, worktree in
            try service.pull(worktree: worktree)
        }
    }

    /// `GST-03`'s Push: `git push`, or `git push -u origin HEAD` for a branch without an upstream. A push the remote
    /// refuses says "The remote has new commits. Pull first."
    public func pushBranch(workspaceId: String) async {
        guard let workspace = workspace(id: workspaceId) else { return }
        let hasUpstream = pullRequests.panels[workspaceId]?.local?.upstream != nil
        await runBranchStep(.push, workspace: workspace) { service, worktree in
            try service.push(worktree: worktree, hasUpstream: hasUpstream)
        }
    }

    /// `CHK-02`: GitHub's re-run of the failed jobs, once per distinct workflow run of the failed check runs (status
    /// contexts of other CI systems cannot be re-run), then a refresh, which shows them running again.
    public func rerunFailedChecks(workspaceId: String) async {
        guard let pr = pullRequests.panels[workspaceId]?.snapshot?.pullRequest,
              let workspace = workspace(id: workspaceId), let repo = repo(id: workspace.repoId) else { return }
        let runIds = pr.failedWorkflowRunIds
        guard !runIds.isEmpty else { return }
        let ran = await perform(.rerun, workspaceId: workspaceId) {
            do {
                guard let repository = await self.githubRepository(for: repo) else { throw PullRequestLoadError.noGitHubRemote }
                let client = try await self.githubClient(for: repo)
                for runId in runIds {
                    try await client.rerunFailedJobs(repository: repository, runId: runId)
                }
            } catch {
                self.onToast?("Couldn’t re-run the failed jobs: \(Self.gitHubFailureText(error))")
            }
        }
        guard ran else { return }
        await pullRequests.refresh(workspaceId: workspaceId, reason: .action)
    }

    /// Runs one of `GST-03`'s git steps off the main actor. The token comes first, so an HTTPS remote signs with the
    /// repository's account (`ENV-01`); a failure's text goes to the toast (`ERR-01`); then a refresh (`PR-07`).
    private func runBranchStep(
        _ action: PullRequestAction,
        workspace: Workspace,
        _ step: @escaping @Sendable (GitBranchService, URL) throws -> Void
    ) async {
        let ran = await perform(action, workspaceId: workspace.id) {
            await self.prepareEnvironment(for: workspace)
            let current = self.workspace(id: workspace.id) ?? workspace
            let service = GitBranchService(environment: self.environment(for: current))
            let worktree = URL(fileURLWithPath: current.path)
            let failure = await Task.blocking { () -> GitBranchError? in
                do {
                    try step(service, worktree)
                    return nil
                } catch {
                    return GitBranchService.branchError(error)
                }
            }.value
            if let failure { self.onToast?(failure.description) }
        }
        guard ran else { return }
        await pullRequests.refresh(workspaceId: workspace.id, reason: .action)
    }

    /// Marks `action` running in the workspace while `body` runs. Returns false, without running it, when that action
    /// already runs there.
    @discardableResult
    private func perform(_ action: PullRequestAction, workspaceId: String, _ body: @MainActor () async -> Void) async -> Bool {
        guard !isRunning(action, workspaceId: workspaceId) else { return false }
        runningPullRequestActions[workspaceId, default: []].insert(action)
        await body()
        runningPullRequestActions[workspaceId]?.remove(action)
        if runningPullRequestActions[workspaceId]?.isEmpty == true { runningPullRequestActions[workspaceId] = nil }
        return true
    }

    /// The client of the repository's account. Without an account: "GitHub access required" (`ERR-01`).
    private func githubClient(for repo: Repo) async throws -> GitHubClient {
        guard let login = await githubLogin(for: repo) else { throw GitHubAccountError.notLoggedIn(nil) }
        return githubClient(login: login)
    }

    /// What a failed GitHub action says in the toast: GitHub's own message, else `ERR-01`'s label. Neither carries a
    /// token.
    static func gitHubFailureText(_ error: Error) -> String {
        let panelError = PanelError(error)
        return panelError.detail ?? panelError.label
    }

    // MARK: Actions through the agent (AGT-00…AGT-06, GST-02)

    /// `AGT-00`: whether the panel's agent buttons can send now. They cannot while the selected conversation's turn
    /// runs, or while its agent is stopped.
    public func agentActionAvailability(workspaceId: String) -> AgentActionAvailability {
        guard let chat = existingChat(workspaceId: workspaceId) else { return .available }
        switch chat.state {
        case .running: return .working
        case .stopped: return .stopped
        case .idle, .starting, .ready: return .available
        }
    }

    /// `AGT-00`: `text` goes, as if typed, to the workspace's selected conversation, whose agent starts if needed, and
    /// the workspace shows that conversation instead of a file tab. Never queued (user decision): while its turn runs,
    /// or with its agent stopped, nothing is sent, also when the turn started while this one waited. Returns when the
    /// turn ends, whose end refreshes the pull request (`PR-07`).
    public func sendAgentAction(workspaceId: String, text: String, attachments: [URL]) async {
        guard agentActionAvailability(workspaceId: workspaceId) == .available, let workspace = workspace(id: workspaceId) else { return }
        if existingChat(workspaceId: workspaceId) == nil {
            await showConversations(workspace: workspace)
        }
        guard let chat = existingChat(workspaceId: workspaceId) else { return }
        selectedFiles[workspaceId] = nil
        guard agentActionAvailability(workspaceId: workspaceId) == .available else { return }
        await chat.send(text, attachments: attachments)
    }

    /// `AGT-01`: the agent commits, pushes and runs `gh pr create` against the base; `draft` adds `--draft`.
    public func createPullRequest(workspaceId: String, draft: Bool) async {
        guard let base = pullRequestBase(workspaceId: workspaceId) else { return }
        await sendAgentAction(workspaceId: workspaceId, text: AgentPrompts.createPullRequest(base: base, draft: draft), attachments: [])
    }

    /// `AGT-02`.
    public func commitAndPush(workspaceId: String) async {
        await sendAgentAction(workspaceId: workspaceId, text: AgentPrompts.commitAndPush(), attachments: [])
    }

    /// `AGT-06`.
    public func resolveIncompatibility(workspaceId: String) async {
        await sendAgentAction(workspaceId: workspaceId, text: AgentPrompts.resolveIncompatibility(), attachments: [])
    }

    /// `AGT-04`, rebasing or merging by the worktree's `git config pull.rebase`.
    public func resolveConflicts(workspaceId: String) async {
        guard agentActionAvailability(workspaceId: workspaceId) == .available,
              let workspace = workspace(id: workspaceId), let base = pullRequestBase(workspaceId: workspaceId) else { return }
        let rebase = await prefersRebase(workspace)
        await sendAgentAction(workspaceId: workspaceId, text: AgentPrompts.resolveConflicts(base: base, rebase: rebase), attachments: [])
    }

    /// `AGT-01`'s "Create PR manually": GitHub's compare page of the base with the live branch. nil until the
    /// repository's GitHub remote has been looked up (the panel's first refresh does it).
    public func compareURL(workspaceId: String) -> URL? {
        guard let workspace = workspace(id: workspaceId), let repository = knownGitHubRepositories[workspace.repoId],
              let base = pullRequestBase(workspaceId: workspaceId) else { return nil }
        let branch = pullRequests.panels[workspaceId]?.local?.branch ?? workspace.branch
        var components = URLComponents()
        components.scheme = "https"
        components.host = GitHubRemote.host
        components.path = "/\(repository.owner)/\(repository.name)/compare/\(base)...\(branch)"
        components.queryItems = [URLQueryItem(name: "expand", value: "1")]
        return components.url
    }

    /// `AGT-03`: the failure logs of the failed checks, saved and attached, and a line for each check without one,
    /// then the prompt.
    public func fixFailingChecks(workspaceId: String) async {
        guard agentActionAvailability(workspaceId: workspaceId) == .available,
              let workspace = workspace(id: workspaceId), let repo = repo(id: workspace.repoId),
              let pr = pullRequests.panels[workspaceId]?.snapshot?.pullRequest else { return }
        var prepared: (notes: [String], logs: [URL])?
        await perform(.fixErrors, workspaceId: workspaceId) {
            prepared = await self.prepareCILogs(for: pr, workspace: workspace, repo: repo)
        }
        guard let prepared else { return }
        await sendAgentAction(workspaceId: workspaceId, text: AgentPrompts.fixFailingChecks(notes: prepared.notes), attachments: prepared.logs)
    }

    /// `GST-02`, Conductor's order: uncommitted changes go to the agent; else `git fetch origin <base>`; a branch with
    /// no commits of its own fast-forwards (`git merge --ff-only`, "Pulled latest changes. You're up to date!"); a
    /// diverged one goes to the agent, to merge or rebase by `git config pull.rebase`. Rocky itself never creates a
    /// merge commit and never force-pushes.
    public func pullFromBase(workspaceId: String) async {
        guard agentActionAvailability(workspaceId: workspaceId) == .available,
              let workspace = workspace(id: workspaceId), let base = pullRequestBase(workspaceId: workspaceId) else { return }
        var outcome: Result<BaseSyncStep, GitBranchError>?
        await perform(.pullFromBase, workspaceId: workspaceId) {
            await self.prepareEnvironment(for: workspace)
            let current = self.workspace(id: workspace.id) ?? workspace
            let service = GitBranchService(environment: self.environment(for: current))
            let worktree = URL(fileURLWithPath: current.path)
            outcome = await Task.blocking { () -> Result<BaseSyncStep, GitBranchError> in
                do {
                    return .success(try AppModel.syncWithBase(base, service: service, worktree: worktree))
                } catch {
                    return .failure(GitBranchService.branchError(error))
                }
            }.value
        }
        switch outcome {
        case .success(.commitFirst):
            await sendAgentAction(workspaceId: workspaceId, text: AgentPrompts.commitThenBringInBase(base: base), attachments: [])
        case .success(.diverged(let rebase)):
            await sendAgentAction(workspaceId: workspaceId, text: AgentPrompts.bringInBase(base: base, rebase: rebase), attachments: [])
        case .success(.fastForwarded):
            onToast?("Pulled latest changes. You're up to date!")
            await pullRequests.refresh(workspaceId: workspaceId, reason: .action)
        case .failure(let failure):
            onToast?(failure.description)
            await pullRequests.refresh(workspaceId: workspaceId, reason: .action)
        case nil:
            return
        }
    }

    /// `GST-02`'s git steps, blocking: what the worktree's own status and `origin/<base>` say comes next.
    nonisolated static func syncWithBase(_ base: String, service: GitBranchService, worktree: URL) throws -> BaseSyncStep {
        let remoteBase = "origin/\(base)"
        if try service.status(worktree: worktree, base: remoteBase).uncommitted > 0 { return .commitFirst }
        try service.fetch(worktree: worktree, branch: base)
        guard try service.ownCommits(worktree: worktree, since: remoteBase) == 0 else {
            return .diverged(rebase: service.prefersRebase(worktree: worktree))
        }
        try service.fastForward(worktree: worktree, to: remoteBase)
        return .fastForwarded
    }

    private func prefersRebase(_ workspace: Workspace) async -> Bool {
        let service = GitBranchService(environment: environment(for: workspace))
        let worktree = URL(fileURLWithPath: workspace.path)
        return await Task.blocking { service.prefersRebase(worktree: worktree) }.value
    }

    /// `AGT-03`'s attachments and notes. The workspace's old logs are deleted first. Each failed GitHub Actions check
    /// run gets the last 1000 lines of its job's log saved and attached; a job that never started, or whose log cannot
    /// be read, gives its annotations; any other check a line with its URL.
    private func prepareCILogs(for pr: PullRequestInfo, workspace: Workspace, repo: Repo) async -> (notes: [String], logs: [URL])? {
        let root = paths.ciLogs
        let workspaceId = workspace.id
        let folder: URL
        do {
            folder = try await Task.blocking { try CILogs.freshFolder(for: workspaceId, in: root) }.value
        } catch {
            onToast?("Couldn’t prepare the CI logs: \(error.localizedDescription)")
            return nil
        }
        let repository = await githubRepository(for: repo)
        let client = try? await githubClient(for: repo)
        var notes: [String] = []
        var logs: [URL] = []
        for check in pr.checks where check.state == .failed {
            if let repository, let client, let jobId = check.checkRunId, check.workflowRunId != nil {
                if check.startedAt != nil,
                   let log = await saveCILog(client: client, repository: repository, jobId: jobId, checkName: check.name, folder: folder) {
                    logs.append(log)
                    continue
                }
                let messages = (try? await client.annotations(repository: repository, checkRunId: jobId)) ?? []
                if !messages.isEmpty {
                    notes += messages.map { AgentPrompts.checkNote(name: check.name, detail: $0) }
                    continue
                }
            }
            notes.append(AgentPrompts.checkNote(name: check.name, detail: check.url?.absoluteString ?? "failed"))
        }
        return (notes, logs)
    }

    /// Downloads a job's log to a temporary file (never into memory), keeps its last lines in `folder` and deletes the
    /// download. nil when GitHub has no log for it.
    private func saveCILog(client: GitHubClient, repository: GitHubRepository, jobId: Int, checkName: String, folder: URL) async -> URL? {
        guard let download = try? await client.jobLog(repository: repository, jobId: jobId) else { return nil }
        return await Task.blocking { () -> URL? in
            defer { try? FileManager.default.removeItem(at: download) }
            return try? CILogs.save(tailOf: download, checkName: checkName, in: folder)
        }.value
    }

    // MARK: Comments (REV-01, AGT-05)

    /// `AGT-05`: the pending comments with these `ids` (nil: every one, "Add all to chat"), in the panel's order, go
    /// to the agent as one prompt (`AGT-00`), and their rows show the check. Nothing goes while the conversation cannot
    /// take a prompt, nor without a comment to send.
    public func sendComments(workspaceId: String, ids: [String]?) async {
        guard agentActionAvailability(workspaceId: workspaceId) == .available,
              let panel = pullRequests.panels[workspaceId], let pr = panel.snapshot?.pullRequest else { return }
        let chosen = ids.map { Set($0) }
        let comments = panel.comments.filter { chosen?.contains($0.id) ?? true }
        guard !comments.isEmpty else { return }
        pullRequests.markCommentsAdded(comments.map(\.id), workspaceId: workspaceId)
        let prompt = AgentPrompts.reviewComments(number: pr.number, comments: comments)
        await sendAgentAction(workspaceId: workspaceId, text: prompt, attachments: [])
    }

    /// `REV-01`'s Hide: the comment leaves the list for this pull request, also after a relaunch.
    public func hideComment(workspaceId: String, id: String) {
        pullRequests.hideComment(id, workspaceId: workspaceId)
    }

    // MARK: Merge, ready for review and archive (PR-05, PR-06, PR-08, SET-01)

    /// How long `PR-05`'s "Confirm …" waits for the second click.
    public static let mergeConfirmationTime: Duration = .seconds(4)

    /// The methods the merge button offers (`PR-05`): the repository's, in the order squash, rebase, merge; none
    /// before the first refresh.
    public func mergeMethods(workspaceId: String) -> [MergeMethod] {
        guard let snapshot = pullRequests.panels[workspaceId]?.snapshot else { return [] }
        return MergeMethods.available(repository: snapshot.repository)
    }

    /// The method the merge button uses: the menu's pick until Rocky quits (never stored), else
    /// `MergeMethods.initial`. Rebase does not count while GitHub cannot rebase the branch cleanly, unless it is the
    /// repository's only method. nil before the first refresh.
    public func mergeMethod(workspaceId: String) -> MergeMethod? {
        guard let snapshot = pullRequests.panels[workspaceId]?.snapshot else { return nil }
        var usable = MergeMethods.available(repository: snapshot.repository)
        if snapshot.pullRequest?.canBeRebased == false, usable.count > 1 {
            usable.removeAll { $0 == .rebase }
        }
        if let pick = mergeMethodPicks[workspaceId], usable.contains(pick) { return pick }
        return MergeMethods.initial(available: usable, viewerDefault: snapshot.repository.viewerDefaultMergeMethod)
    }

    /// The menu's pick, kept for the workspace until Rocky quits. It cancels a confirmation (`PR-05`).
    public func setMergeMethod(workspaceId: String, _ method: MergeMethod) {
        mergeMethodPicks[workspaceId] = method
        mergeConfirmations[workspaceId] = nil
        mergeErrors[workspaceId] = nil
    }

    /// Whether the merge button says "Confirm …" (`PR-05`). The header's button and the Git status row's share it.
    public func isConfirmingMerge(workspaceId: String) -> Bool {
        mergeConfirmations[workspaceId] != nil
    }

    /// `PR-05`'s two clicks: the first turns the merge button into "Confirm …" for `mergeConfirmationTime`, the second
    /// within that time merges.
    public func confirmOrMerge(workspaceId: String) async {
        guard !isRunning(.merge, workspaceId: workspaceId) else { return }
        guard mergeConfirmations[workspaceId] != nil else {
            let token = UUID()
            mergeConfirmations[workspaceId] = token
            mergeErrors[workspaceId] = nil
            Task { [weak self] in
                try? await Task.sleep(for: Self.mergeConfirmationTime)
                guard let self, self.mergeConfirmations[workspaceId] == token else { return }
                self.mergeConfirmations[workspaceId] = nil
            }
            return
        }
        await merge(workspaceId: workspaceId)
    }

    /// `PR-05`: GitHub's `mergePullRequest` with the workspace's method, then a refresh. A refusal shows under the
    /// header (`mergeErrors`). Rocky never deletes the branch, here or on GitHub.
    public func merge(workspaceId: String) async {
        mergeConfirmations[workspaceId] = nil
        guard let pr = pullRequests.panels[workspaceId]?.snapshot?.pullRequest, !pr.isMerged,
              let method = mergeMethod(workspaceId: workspaceId),
              let workspace = workspace(id: workspaceId), let repo = repo(id: workspace.repoId) else { return }
        mergeErrors[workspaceId] = nil
        let ran = await perform(.merge, workspaceId: workspaceId) {
            do {
                let client = try await self.githubClient(for: repo)
                try await client.merge(id: pr.id, method: method)
            } catch {
                self.mergeErrors[workspaceId] = "Couldn’t merge: \(Self.gitHubFailureText(error))"
            }
        }
        guard ran else { return }
        await pullRequests.refresh(workspaceId: workspaceId, reason: .action)
    }

    /// Hides `PR-05`'s error line.
    public func dismissMergeError(workspaceId: String) {
        mergeErrors[workspaceId] = nil
    }

    /// `PR-08`: GitHub's `markPullRequestReadyForReview`, with no confirmation, then a refresh. A failure goes to the
    /// toast, like CHK-02's re-run.
    public func markReadyForReview(workspaceId: String) async {
        guard let pr = pullRequests.panels[workspaceId]?.snapshot?.pullRequest, pr.isDraft,
              let workspace = workspace(id: workspaceId), let repo = repo(id: workspace.repoId) else { return }
        let ran = await perform(.readyForReview, workspaceId: workspaceId) {
            do {
                let client = try await self.githubClient(for: repo)
                try await client.markReadyForReview(id: pr.id)
            } catch {
                self.onToast?("Couldn’t mark the pull request ready for review: \(Self.gitHubFailureText(error))")
            }
        }
        guard ran else { return }
        await pullRequests.refresh(workspaceId: workspaceId, reason: .action)
    }

    /// The worktree's uncommitted changes and untracked files right now, for `PR-06`'s question and `SET-01`'s check;
    /// nil when git cannot tell (the worktree is gone, for example).
    public func uncommittedChangeCount(workspaceId: String) async -> Int? {
        guard let workspace = workspace(id: workspaceId) else { return nil }
        let service = GitBranchService(environment: loginEnvironment)
        let worktree = URL(fileURLWithPath: workspace.path)
        return await Task.blocking { try? service.status(worktree: worktree, base: nil).uncommitted }.value
    }

    /// `PR-06`'s question before archiving a worktree with changes: "tokyo has 3 uncommitted changes. Archive anyway?"
    public static func archiveQuestion(workspaceName: String, uncommitted: Int) -> String {
        "\(workspaceName) has \(uncommitted) uncommitted \(uncommitted == 1 ? "change" : "changes"). Archive anyway?"
    }

    /// `PR-06`: today's remove flow (the archive script, then the worktree's removal; the branch and the remote branch
    /// stay). `stashingChanges` is the answer Archive to `archiveQuestion`: the changes go to a git stash of the
    /// repository first, so git can remove the worktree and nothing is lost.
    public func archiveMergedWorkspace(workspaceId: String, stashingChanges: Bool = false) async {
        await perform(.archive, workspaceId: workspaceId) {
            await self.removeWorkspace(id: workspaceId, stashingChanges: stashingChanges)
        }
    }

    /// `SET-01`: with Archive on merge on, a merge the monitor sees archives the workspace (`PR-06`).
    private func pullRequestMerged(workspaceId: String) {
        guard archiveOnMerge, let workspace = workspace(id: workspaceId) else { return }
        Task { await archiveAfterMerge(workspace) }
    }

    /// `SET-01` never asks: a worktree with uncommitted changes is left as it is, and the toast says so; one git
    /// cannot read is left alone too. "Archived tokyo" once the workspace is gone.
    private func archiveAfterMerge(_ workspace: Workspace) async {
        guard let uncommitted = await uncommittedChangeCount(workspaceId: workspace.id) else { return }
        guard uncommitted == 0 else {
            onToast?("\(workspace.name) merged but has uncommitted changes; not archived")
            return
        }
        await archiveMergedWorkspace(workspaceId: workspace.id)
        if self.workspace(id: workspace.id) == nil {
            onToast?("Archived \(workspace.name)")
        }
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
            try await Task.blocking { try install(kind, nil, paths, environment) }.value
            refreshInstalledAgentVersions()
            return try makeLaunch(agent, cwd, environment, paths)
        }
    }

    // MARK: Keyboard

    /// The workspaces the sidebar lists, top to bottom, leaving out folded repositories and search misses (KBD-01).
    /// ⌘1…⌘9 pick from it. The sidebar keeps it current; while the sidebar is hidden it keeps the last order shown.
    public var visibleWorkspaceIds: [String] = []
    /// Set by ⌘K (KBD-01). The sidebar shows itself, focuses its search field and sets it back to false.
    public var isSearchFocusRequested = false

    /// Where ⌘N creates a workspace (KBD-01): the selected workspace's repository, else the first one; nil, which
    /// disables ⌘N, without repositories.
    public var newWorkspaceRepoId: String? {
        selectedWorkspace?.repoId ?? repos.first?.id
    }

    /// ⌘1…⌘9: selects the workspace at `number` (from 1) in `visibleWorkspaceIds`, if there is one.
    public func selectVisibleWorkspace(number: Int) {
        let index = number - 1
        guard visibleWorkspaceIds.indices.contains(index) else { return }
        selectedWorkspaceId = visibleWorkspaceIds[index]
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
            try await Task.blocking { try install(kind, version, paths, environment) }.value
            agentUpdateError = nil
        } catch {
            agentUpdateError = "Could not install \(kind.displayName) \(version): \(error)"
        }
        refreshInstalledAgentVersions()
    }

    private func reload() {
        do {
            var repos = try store.repos()
            if repos.contains(where: { $0.colorIndex == nil }) { repos = try assignMissingRepoColors(repos) }
            self.repos = repos
            var byRepo: [String: [Workspace]] = [:]
            for repo in repos { byRepo[repo.id] = try store.workspaces(repoId: repo.id) }
            workspaces = byRepo
            pullRequests.seed(byRepo.values.flatMap { $0 })
            refreshWorkspaceTitles()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Repositories added before colors were stored get one each, oldest first, the way a new repository does.
    private func assignMissingRepoColors(_ repos: [Repo]) throws -> [Repo] {
        var used = repos.compactMap(\.colorIndex)
        var result = repos
        for index in result.indices.sorted(by: { result[$0].createdAt < result[$1].createdAt }) where result[index].colorIndex == nil {
            let color = RepoMonogram.pickColor(used: used)
            result[index].colorIndex = color
            try store.update(result[index])
            used.append(color)
        }
        return result
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
