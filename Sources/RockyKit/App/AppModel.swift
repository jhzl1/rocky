import Foundation
import Observation

public struct RockyPaths: Sendable {
    public let database: URL
    public let adapterPrefix: URL
    public let logs: URL
    /// `AGT-03`'s failure logs, one folder per workspace, outside every worktree.
    public let ciLogs: URL
    /// `AGM-04`'s model catalog (`AgentModelCatalog`).
    public let agentModels: URL

    /// `ciLogs` defaults to a `ci-logs` folder next to the database, `agentModels` to `agent-models.json` there.
    public init(database: URL, adapterPrefix: URL, logs: URL, ciLogs: URL? = nil, agentModels: URL? = nil) {
        self.database = database
        self.adapterPrefix = adapterPrefix
        self.logs = logs
        let support = database.deletingLastPathComponent()
        self.ciLogs = ciLogs ?? support.appendingPathComponent("ci-logs", isDirectory: true)
        self.agentModels = agentModels ?? support.appendingPathComponent("agent-models.json")
    }

    /// `~/Library/Application Support/Rocky` for data, the Claude adapter, the CI logs (`ci-logs`) and the model
    /// catalog (`agent-models.json`), `~/Library/Logs/Rocky` for agent stderr.
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

/// What `AppModel.pickModel` did with a pick in the model menu (M2.8 Decision 5). The menu stays open after a pick
/// (`AGM-07`) except when another tab takes over (`AGM-03`), and the model cannot reach the menu: the view closes it
/// for `.openedConversation`.
public enum ModelPick: Sendable, Equatable {
    /// The conversation's own agent: its model changed, or waits for its session while the agent starts (`AGM-05`).
    case setModel
    /// `AGM-02`: the empty conversation switched to the picked agent, in its tab.
    case switchedInPlace
    /// `AGM-03`: a new conversation with the picked agent opened, selected, with the draft.
    case openedConversation
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
            if oldValue != selectedWorkspaceId {
                // The workspace left behind stops reading comments (REV-01) and drops its full diff (GIT-01): only the
                // selected workspace keeps one. The new workspace's panel says what it shows once it appears.
                if let oldValue {
                    pullRequests.setCommentsVisible(false, workspaceId: oldValue)
                    changes[oldValue] = nil
                    // FIL-07: a workspace that is not selected keeps nothing of its All files tab and reads nothing.
                    fileTrees[oldValue] = nil
                    staleFileTrees[oldValue] = nil
                    // FIL-08: nor for Quick Open, which the window closes with the selection.
                    if quickOpenWorkspaceId == oldValue { quickOpenWorkspaceId = nil }
                }
                visibleRightPanelTab = nil
                // A diff tab on screen in the new workspace needs its full diff at once (DIFF-01), panel or not.
                refreshShownChangesIfStale()
            }
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
    /// The tab each workspace's right panel shows (`PNL-03`), in memory; none is Changes (`rightPanelTab(workspaceId:)`).
    public var rightPanelTabs: [String: RightPanelTab] = [:]
    /// The tab the selected workspace's right panel shows while the panel is open, else nil. Set by `RightPanel`. It
    /// decides what runs: REV-01's comments are read while it is Checks, the full diff is computed while it is Changes
    /// or All files (`showsChanges(workspaceId:)`), and the worktree's files are read while it is All files
    /// (`showsFiles(workspaceId:)`, FIL-07).
    public var visibleRightPanelTab: RightPanelTab? = nil {
        didSet {
            guard visibleRightPanelTab != oldValue else { return }
            if let selectedWorkspaceId {
                pullRequests.setCommentsVisible(visibleRightPanelTab == .checks, workspaceId: selectedWorkspaceId)
            }
            refreshShownChangesIfStale()
            refreshShownFilesIfNeeded()
        }
    }
    /// GIT-03: every workspace's `+A −D` and changed file count, from `GitChangesService.shortstat` after each change
    /// on disk, or from its full diff while that is computed. In memory; computed once when the workspace is loaded.
    public private(set) var diffStats: [String: DiffStat] = [:]
    /// GIT-01: the selected workspace's changes against its base, computed while it shows them
    /// (`showsChanges(workspaceId:)`) and dropped when another workspace is selected.
    public private(set) var changes: [String: WorkspaceChanges] = [:]
    /// ERR-02: the last git failure of each workspace's Changes tab.
    public private(set) var changesFailures: [String: ChangesFailure] = [:]
    /// GIT-04: each workspace's commit sheet state while its commit runs, and after a failure until the sheet closes
    /// (`dismissCommit`). The Changes tab shows its sheet while there is one, so a sheet that went with its tab (a
    /// workspace switch from the menu) comes back with it.
    public private(set) var commits: [String: CommitProgress] = [:]
    /// GIT-01: each workspace's FSEvents stream, from `watchWorkspace`.
    @ObservationIgnored private let watchWorkspace: @Sendable (URL, @escaping @Sendable (FolderEvents) -> Void) -> any WorkspaceWatch
    @ObservationIgnored private var watchers: [String: any WorkspaceWatch] = [:]
    /// The workspaces whose stream is running or starting; a stream that finishes starting for a workspace no longer
    /// here is stopped at once.
    @ObservationIgnored private var watchedWorkspaceIds: Set<String> = []
    /// Workspaces that changed on disk while their full diff was not computed (hidden, or git busy): it is computed
    /// again when it shows.
    @ObservationIgnored private var staleChanges: Set<String> = []
    /// Each workspace's git refresh in flight, so events that arrive meanwhile become one more run, not more processes.
    @ObservationIgnored private var gitRefreshes: [String: GitRefresh] = [:]

    private struct GitRefresh {
        let task: Task<Void, Never>
        var runsAgain = false
    }
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
    /// `AGM-02`, `AGM-03`, `KIT-11`: the unsent draft (text, files and line chip) a pick in the model menu moved, by the
    /// conversation that takes it (M2.8 Decision 1). The next `ChatView` for that conversation takes it once
    /// (`takePendingDraft`): a switched conversation gets a new view, since its chat is new, and so does a new tab.
    @ObservationIgnored public private(set) var pendingDrafts: [String: MessageHistory.Entry] = [:]
    /// `AGM-02`: each conversation's agent switch in flight, so a later pick, or the tab closing, wins over an earlier
    /// one still building its chat.
    @ObservationIgnored private var agentSwitches: [String: UUID] = [:]
    /// The first read of the login shell's environment, at launch. The last session's workspace is selected before it
    /// ends, so the window shows it at once; its agents wait for this, or they would start without the user's PATH.
    @ObservationIgnored private var launchEnvironment: Task<Void, Never>?
    private static let lastWorkspaceKey = "lastWorkspaceId"
    private static let lastConversationsKey = "lastConversationIds"
    /// Files opened in tabs next to the conversations (from a file badge), by workspace. Kept only while Rocky runs.
    public private(set) var openFiles: [String: [String]] = [:]
    /// The file tab each workspace shows instead of its conversation; none shows the selected conversation.
    public private(set) var selectedFiles: [String: String] = [:]
    /// DIFF-01: each workspace's diff tabs, worktree-relative paths in tab order, drawn after its file tabs. One tab per
    /// file. A path that leaves `changes` keeps its tab, which then shows the file unchanged (the plan's "one tab per
    /// worktree file"). Kept only while Rocky runs.
    public private(set) var diffTabs: [String: [String]] = [:]
    /// The diff tab each workspace shows instead of its conversation. At most one of this and `selectedFiles` is set
    /// for a workspace. A diff tab on screen keeps the workspace's full diff computed (`showsChanges(workspaceId:)`).
    public private(set) var selectedDiffTabs: [String: String] = [:] {
        didSet { refreshShownChangesIfStale() }
    }
    /// Each diff tab's mode (`DIFF-01`'s Diff | Edit), by workspace and path; a tab without one shows its diff.
    public private(set) var diffTabModes: [String: [String: DiffTabMode]] = [:]
    /// DIFF-05 and CMT-06: the diff tab each workspace was last asked to scroll, to its first hunk (a badge) or to a
    /// line (a chip).
    public private(set) var diffScrollRequests: [String: DiffScrollRequest] = [:]
    /// CMT-06: the serial of the chip request each workspace's diff tab has scrolled to (`lineScrollHandled`).
    public private(set) var handledLineScrolls: [String: Int] = [:]
    /// CMT-02: each diff tab's comment box, by workspace and worktree-relative path, while its tab is open: a tab
    /// switch or Diff | Edit brings the box back with its range, its text and its conversation. In memory only, and
    /// dropped when the tab closes, the comment goes or it is cancelled. Rocky stores no comment (CMT-05): the
    /// conversation keeps it.
    public private(set) var commentDrafts: [String: [String: CommentDraft]] = [:]
    /// EDIT-01…EDIT-03: the files open in the editor, by workspace and absolute path (a diff tab's file through
    /// `editorPath(worktree:relativePath:)`, a file tab's path as it is). One buffer per file, whichever tabs show it,
    /// so two tabs never hold two versions of one file. Kept while a tab of the workspace holds the file, in memory only:
    /// unsaved edits stay across tab and workspace switches until the tab closes.
    public private(set) var editors: [String: [String: EditorState]] = [:]
    /// EDIT-04: each worktree file's text at the workspace's base, by worktree-relative path, read once per base and
    /// path (`loadEditorBase`).
    public private(set) var editorBases: [String: [String: EditorBase]] = [:]
    /// The editors whose save is on its way ("workspace id" NUL "path"), so a second ⌘S writes nothing.
    @ObservationIgnored private var savingEditors: Set<String> = []
    /// FIL-01…FIL-07: the selected workspace's All files tab, git's list and the folders read so far, filled while the
    /// tab shows and dropped when another workspace is selected. Its expanded folders are stored per workspace.
    public private(set) var fileTrees: [String: FileTreeState] = [:]
    /// What changed on disk since the tab's last read (FIL-07): events while it is hidden only mark it here, and
    /// showing it reads what is marked.
    @ObservationIgnored private var staleFileTrees: [String: StaleFileTree] = [:]
    /// Each workspace's file reads in flight, so events that arrive meanwhile become one more run, not more processes.
    @ObservationIgnored private var fileReads: [String: FileRead] = [:]
    /// Each worktree's path as FSEvents reports it (`FileWatcher.canonicalPath`, `/private/var/…` for `/var/…`), resolved
    /// once off the main actor when its stream starts: the tree's events and the badges' paths are matched with it.
    @ObservationIgnored private var canonicalWorktrees: [String: String] = [:]
    /// The All files tab's reads (`WorktreeFiles`); tests pass their own.
    @ObservationIgnored private let worktreeFiles: @Sendable ([String: String]) -> any WorktreeFileReading
    /// FIL-05: each workspace's one preview tab, a worktree-relative path of `diffTabs`: the tree's single click opens
    /// it or replaces it; a double-click, a double-click on its tab or the first edit keeps it (it leaves this).
    public private(set) var previewTabs: [String: String] = [:]
    /// FIL-05's Reveal: the row each workspace's All files tab is to scroll into view, once it is drawn; the tab clears
    /// it (`revealHandled`).
    public private(set) var revealedPaths: [String: String] = [:]
    /// FIL-08: each workspace's recently opened worktree files, worktree-relative, newest first, at most
    /// `QuickOpen.recentLimit`. Read from the store once per launch, the first time Quick Open or an open needs them,
    /// and written on every open of a worktree tab (`showWorktreeTab`).
    public private(set) var recentFiles: [String: [String]] = [:]
    /// FIL-08: the workspace Quick Open shows, from `quickOpenWillShow` to `quickOpenDidHide`. It admits a read of git's
    /// list (`readFilesOnce`), no folder, and keeps the full diff computed for its status letters (`showsChanges`).
    @ObservationIgnored private var quickOpenWorkspaceId: String?

    private struct StaleFileTree: Sendable {
        var list = false
        /// Worktree-relative folders whose rows show and whose listings an event named.
        var folders: Set<String> = []
    }

    private struct FileRead {
        let task: Task<Void, Never>
        var runsAgain = false
    }
    /// The last command list each repository's agent announced (KIT-01), so a new conversation has one while its own
    /// agent starts. In memory only: the agent sends it again after every start. Observed: the popup shows it.
    private var lastCommands: [CommandListKey: [SlashCommand]] = [:]

    private struct CommandListKey: Hashable {
        let repoId: String
        let agent: AgentKind
    }
    /// `AGM-04`, `KIT-12`: every agent's models as a session last reported them, read from `paths.agentModels` once at
    /// launch and written when a list changes. Observed: the model menu lists another agent's models from here.
    public private(set) var modelCatalog: AgentModelCatalog
    /// `loadModelsIfNeeded`'s runs in flight and their failures, by agent and Claude instance (`modelProbeKey`).
    @ObservationIgnored private var modelProbes: [String: Task<Void, Never>] = [:]
    private var modelProbeFailures: [String: String] = [:]
    /// Observed for the same reason as `chats`. Created only in actions, never while a view reads it.
    private var processes: [String: WorkspaceProcesses] = [:]
    /// `KBD-04`: each workspace's count of ⌃` presses (`requestTerminalToggle`). In memory only.
    public private(set) var terminalToggleRequests: [String: Int] = [:]
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
        githubSession: URLSession = GitHubClient.makeSession(),
        watchWorkspace: @escaping @Sendable (_ worktree: URL, _ onChange: @escaping @Sendable (FolderEvents) -> Void) -> any WorkspaceWatch = { worktree, onChange in
            FileWatcher(
                paths: FileWatcher.workspacePaths(worktree: worktree),
                excluding: FileWatcher.excludedFolders,
                debounce: FileWatcher.debounce,
                onChange: onChange
            )
        },
        worktreeFiles: @escaping @Sendable (_ environment: [String: String]) -> any WorktreeFileReading = { WorktreeFiles(environment: $0) }
    ) {
        self.watchWorkspace = watchWorkspace
        self.worktreeFiles = worktreeFiles
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
        self.modelCatalog = AgentModelCatalog(file: paths.agentModels)
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

    /// `AGM-04`: the models `agent` last reported for the workspace's repository, under its Claude instance for Claude
    /// Code; nil when it never reported any on this Mac. Reading them starts no process.
    public func knownModels(agent: AgentKind, workspaceId: String) -> [SessionConfigOption.Choice]? {
        let claudeInstance = workspace(id: workspaceId).flatMap { repo(id: $0.repoId) }?.claudeConfigDir
        return modelCatalog.models(agent: agent, claudeInstance: claudeInstance)
    }

    /// `AGM-04` without a Start button (user decision, 2026-09-25: "la idea es que cargue solo, sin yo tener que darle a
    /// un botón"): an agent with no list for the workspace's repository reports one by itself. It runs once, in the
    /// background and in no conversation, only until its session reports its models; the catalog records them and the
    /// agent stops. One run per agent and Claude instance at a time; a failure stays for the menu to show, and the
    /// next call tries again.
    public func loadModelsIfNeeded(agent: AgentKind, workspaceId: String) {
        guard knownModels(agent: agent, workspaceId: workspaceId)?.isEmpty != false,
              let workspace = workspace(id: workspaceId) else { return }
        let key = modelProbeKey(agent: agent, workspace: workspace)
        guard modelProbes[key] == nil else { return }
        modelProbeFailures[key] = nil
        modelProbes[key] = Task { [weak self] in
            await self?.probeModels(agent: agent, workspace: workspace, key: key)
            self?.modelProbes[key] = nil
        }
    }

    /// Why `loadModelsIfNeeded`'s last run got no list for `agent` in the workspace's repository; a new run clears it.
    public func modelsFailure(agent: AgentKind, workspaceId: String) -> String? {
        guard let workspace = workspace(id: workspaceId) else { return nil }
        return modelProbeFailures[modelProbeKey(agent: agent, workspace: workspace)]
    }

    /// Claude Code's lists are kept per Claude instance, OpenCode's once (`AgentModelCatalog`), and so are the runs.
    private func modelProbeKey(agent: AgentKind, workspace: Workspace) -> String {
        let instance = agent == .claude ? repo(id: workspace.repoId)?.claudeConfigDir ?? "default" : ""
        return "\(agent.rawValue)|\(instance)"
    }

    /// The run itself: the agent started like a conversation's (the login environment, the account's token, its
    /// install on first use), with no history and nothing persisted, stopped once its session is up or has failed.
    private func probeModels(agent: AgentKind, workspace: Workspace, key: String) async {
        await launchEnvironment?.value
        await prepareEnvironment(for: workspace)
        let current = self.workspace(id: workspace.id) ?? workspace
        let claudeInstance = repo(id: current.repoId)?.claudeConfigDir
        let chat: ChatSessionModel
        do {
            let launch = try await resolveLaunch(agent, cwd: URL(fileURLWithPath: current.path), environment: environment(for: current))
            chat = ChatSessionModel(agent: agent, launch: launch)
        } catch {
            modelProbeFailures[key] = "\(error)"
            return
        }
        chat.onModelOption = { [weak self] option in
            self?.modelCatalog.record(option, agent: agent, claudeInstance: claudeInstance)
        }
        // An agent that neither answers nor fails would leave the menu's spinner forever: past the limit it is stopped
        // and counts as failed (AGM-04). The install on first use, above, is not timed.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: Self.modelProbeTimeout)
            guard !Task.isCancelled else { return false }
            await chat.stop()
            return true
        }
        await chat.start()
        watchdog.cancel()
        let timedOut = await watchdog.value
        let failure = chat.failure
        await chat.stop()
        if knownModels(agent: agent, workspaceId: current.id)?.isEmpty != false {
            modelProbeFailures[key] = timedOut
                ? "it didn't answer in \(Int(Self.modelProbeTimeout.components.seconds)) s"
                : failure ?? "\(agent.displayName) reported no models."
        }
    }

    /// How long `loadModelsIfNeeded` waits for the agent's session (AGM-04).
    static let modelProbeTimeout = Duration.seconds(30)

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
            diffTabs[id] = nil
            selectedDiffTabs[id] = nil
            diffTabModes[id] = nil
            diffScrollRequests[id] = nil
            handledLineScrolls[id] = nil
            commentDrafts[id] = nil
            editors[id] = nil
            editorBases[id] = nil
            previewTabs[id] = nil
            revealedPaths[id] = nil
            recentFiles[id] = nil
            fileTrees[id] = nil
            staleFileTrees[id] = nil
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

    /// Loads the workspace's tabs and shows the selected conversation (else the newest, else a new one with the
    /// default agent, CNV-02). Its agent starts in the background, so the model list is there and the first message
    /// does not wait; the other tabs' agents start when their tab is shown (user decision, 2026-09-23).
    public func showConversations(workspace: Workspace) async {
        reloadConversations(workspaceId: workspace.id)
        let open = conversations[workspace.id] ?? []
        if let id = selectedConversationIds[workspace.id], open.contains(where: { $0.id == id }) {
            await showConversation(workspace: workspace, conversationId: id)
        } else if let newest = open.last {
            await showConversation(workspace: workspace, conversationId: newest.id)
        } else {
            await newConversation(workspace: workspace)
        }
    }

    /// Switches the workspace to one of its tabs. The agent of the tab left behind keeps running.
    public func showConversation(workspace: Workspace, conversationId: String) async {
        selectedConversationIds[workspace.id] = conversationId
        showConversationTab(workspaceId: workspace.id)
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

    /// CNV-01, KIT-11: "+" makes the conversation at once, with the default agent (CNV-02).
    @discardableResult
    public func newConversation(workspace: Workspace) async -> ChatSessionModel? {
        await newConversation(workspace: workspace, agent: defaultAgent(repoId: workspace.repoId))
    }

    /// CNV-02: the agent of the conversation where you last sent a message in the repository (any of its workspaces,
    /// open or closed tabs, KIT-13), else Claude Code. Opening a conversation with another agent does not change it by
    /// itself: only a sent message does. A failed read falls back to Claude Code too, since a new conversation must
    /// not wait on it.
    func defaultAgent(repoId: String) -> AgentKind {
        (try? store.lastUsedAgent(repoId: repoId)) ?? .claude
    }

    /// Opens a new tab at the end with an empty conversation with `agent`, selected: the agent actions, and a pick of
    /// another agent's model in a conversation with messages (`AGM-03`, `KIT-11`). Its agent starts in the background
    /// and takes `model` once its session reports its options (nil keeps the agent's default, `AGM-04`'s Start button);
    /// `draft` waits for the tab's message box (`pendingDrafts`). Earlier tabs stay open and running.
    @discardableResult
    public func newConversation(
        workspace: Workspace,
        agent: AgentKind,
        model: String? = nil,
        draft: MessageHistory.Entry? = nil
    ) async -> ChatSessionModel? {
        do {
            let record = ChatSessionRecord(workspaceId: workspace.id, agent: agent.rawValue)
            try store.add(record)
            // Before the tab is selected, so its message box finds the draft when it first appears.
            if let draft, !draft.isEmpty { pendingDrafts[record.id] = draft }
            reloadConversations(workspaceId: workspace.id)
            selectedConversationIds[workspace.id] = record.id
            showConversationTab(workspaceId: workspace.id)
            let chat = try await makeChat(workspace: workspace, record: record, agent: agent)
            chat.pendingModel = modelChoice(model, agent: agent, workspaceId: workspace.id, chat: nil)
            startInBackground(chat)
            return chat
        } catch {
            errorMessage = "Could not start a new conversation: \(error)"
            return nil
        }
    }

    /// `AGM-01`…`AGM-06`, `KIT-11`: a model picked in the conversation's model menu, of `agent`'s; nil `model` is the
    /// agent's default (`AGM-04`'s Start button). For the conversation's own agent the model changes, or waits for the
    /// session while the agent starts (`AGM-05`). Another agent's switches an empty conversation in place (`AGM-02`),
    /// and opens a new conversation when this one has a user message, sent or queued (`AGM-03`, `AGM-06`): its history
    /// lives in the agent's session and cannot move. `draft` is the message box's unsent text, files and chip, which
    /// go to whichever conversation takes over. nil when nothing happened: the conversation is gone, or the new chat
    /// could not be made (`errorMessage` says why).
    @discardableResult
    public func pickModel(
        conversationId: String,
        agent: AgentKind,
        model: String?,
        draft: MessageHistory.Entry? = nil
    ) async -> ModelPick? {
        let chat = chats[conversationId]
        if let chat, chat.agent == agent {
            guard let model else { return .setModel }
            let hasSession = chat.state == .ready || chat.state == .running
            if hasSession, chat.option(SessionConfigOption.model) != nil {
                await chat.setOption(SessionConfigOption.model, to: model)
            } else {
                // Starting, or stopped: the session that comes next reports the options, and takes the pick then.
                let workspaceId = chatWorkspaceIds[conversationId] ?? ""
                chat.pendingModel = modelChoice(model, agent: agent, workspaceId: workspaceId, chat: chat)
            }
            return .setModel
        }
        guard let record = try? store.session(id: conversationId), let workspace = workspace(id: record.workspaceId) else {
            return nil
        }
        if hasMessages(conversationId: conversationId) {
            let opened = await newConversation(workspace: workspace, agent: agent, model: model, draft: draft)
            return opened == nil ? nil : .openedConversation
        }
        let switched = await switchAgent(conversationId: conversationId, to: agent, model: model, draft: draft)
        return switched ? .switchedInPlace : nil
    }

    /// `AGM-02`, `KIT-11`: an empty conversation's agent switches in place, keeping its record, its tab's place and its
    /// selection, in an order that leaves no gap (M2.8 Decision 2), so "Opening the conversation…" never shows and the
    /// open model menu stays:
    /// 1. the new chat is built, awaiting the environment and the launch (the agent's first use installs it), while
    ///    the old one stays on screen;
    /// 2. the record takes the new agent and loses its session id, which the new agent could not load;
    /// 3. the old chat stops, even while it starts, and the new one takes its place, on the same main-actor turn;
    /// 4. the new one starts, with `model` pending (nil keeps the agent's default) and `draft` waiting for its message
    ///    box.
    ///
    /// False when it did not switch: the conversation is gone or has a message, a later pick took over, or the chat
    /// could not be made (`errorMessage` says why).
    @discardableResult
    public func switchAgent(conversationId: String, to agent: AgentKind, model: String?, draft: MessageHistory.Entry? = nil) async -> Bool {
        guard let record = try? store.session(id: conversationId), record.closedAt == nil,
              let workspace = workspace(id: record.workspaceId), !hasMessages(conversationId: conversationId) else { return false }
        let token = UUID()
        agentSwitches[conversationId] = token
        var switched = record
        switched.agent = agent.rawValue
        switched.acpSessionId = nil
        let fresh: ChatSessionModel
        do {
            fresh = try await buildChat(workspace: workspace, record: switched, agent: agent)
        } catch {
            if agentSwitches[conversationId] == token {
                agentSwitches[conversationId] = nil
                errorMessage = "Could not switch the conversation to \(agent.displayName): \(error)"
            }
            return false
        }
        // A later pick, or the tab closing, took over while this one waited. Read again: the old chat may have stored
        // its session id meanwhile, or sent a message.
        guard agentSwitches[conversationId] == token else { return false }
        agentSwitches[conversationId] = nil
        guard var stored = try? store.session(id: conversationId), stored.closedAt == nil,
              !hasMessages(conversationId: conversationId) else { return false }
        stored.agent = agent.rawValue
        stored.acpSessionId = nil
        do {
            try store.update(stored)
        } catch {
            errorMessage = "Could not switch the conversation to \(agent.displayName): \(error)"
            return false
        }
        reloadConversations(workspaceId: workspace.id)
        // From here to the stop's first suspension is one main-actor turn: the tab never lacks a chat, and the old
        // agent is stopped before anything else runs.
        let old = chats[conversationId]
        fresh.pendingModel = modelChoice(model, agent: agent, workspaceId: workspace.id, chat: nil)
        if let draft, !draft.isEmpty { pendingDrafts[conversationId] = draft }
        register(fresh, conversationId: conversationId, workspaceId: workspace.id)
        await old?.stop()
        // A Claude Code terminal command's terminal (CMD-08) belongs to the old agent: the new chat never shows it.
        await closeEmbeddedTerminal(conversationId: conversationId)
        startInBackground(fresh)
        return true
    }

    /// The draft a pick moved to this conversation (`pendingDrafts`), once: the next `ChatView` for it puts it in its
    /// message box.
    public func takePendingDraft(conversationId: String) -> MessageHistory.Entry? {
        pendingDrafts.removeValue(forKey: conversationId)
    }

    /// `AGM-03`, `AGM-06`: the conversation has a user message in its transcript, or one queued.
    private func hasMessages(conversationId: String) -> Bool {
        if let chat = chats[conversationId] {
            return chat.items.contains { $0.kind == .user } || !chat.queue.isEmpty
        }
        let stored = (try? store.messages(sessionId: conversationId)) ?? []
        return stored.contains { $0.kind == ChatItem.Kind.user.rawValue }
    }

    /// A picked model with its name, for the toast when the agent turns out not to have it (`AGM-02`): from the
    /// conversation's own options, else the catalog, else the value itself.
    private func modelChoice(_ value: String?, agent: AgentKind, workspaceId: String, chat: ChatSessionModel?) -> SessionConfigOption.Choice? {
        guard let value else { return nil }
        let own = chat?.agent == agent ? chat?.option(SessionConfigOption.model)?.choices : nil
        let known = own ?? knownModels(agent: agent, workspaceId: workspaceId)
        return known?.first { $0.value == value } ?? SessionConfigOption.Choice(value: value, name: value)
    }

    /// Closes a tab: stops its agent and hides it. The conversation stays in the store.
    public func closeConversation(workspace: Workspace, conversationId: String) async {
        agentSwitches[conversationId] = nil
        pendingDrafts[conversationId] = nil
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
        selectedDiffTabs[workspaceId] = nil
        selectedFiles[workspaceId] = path
    }

    public func showFile(workspaceId: String, path: String) {
        guard openFiles[workspaceId]?.contains(path) == true else { return }
        selectedDiffTabs[workspaceId] = nil
        selectedFiles[workspaceId] = path
    }

    /// The selected conversation comes back over the workspace's file and diff tabs, which stay open.
    private func showConversationTab(workspaceId: String) {
        selectedFiles[workspaceId] = nil
        selectedDiffTabs[workspaceId] = nil
    }

    /// Closes a file tab; if it was on screen, the selected conversation comes back. Its editor goes with it, unsaved
    /// edits included (the tab asks first, `EDIT-02`), unless a diff tab shows the same file.
    public func closeFile(workspaceId: String, path: String) {
        openFiles[workspaceId]?.removeAll { $0 == path }
        if selectedFiles[workspaceId] == path { selectedFiles[workspaceId] = nil }
        dropEditorIfUnused(workspaceId: workspaceId, path: path)
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
        Task {
            // A chat stopped before this ran (AGM-02 replaced it at once) stays stopped: `start()` would take a stopped
            // chat for a Restart, and its agent would run with nobody to stop it.
            guard chat.state == .idle else { return }
            await chat.start()
        }
    }

    /// The conversation's chat, made and registered once: a second caller gets the first one's.
    @discardableResult
    private func makeChat(workspace: Workspace, record: ChatSessionRecord, agent: AgentKind) async throws -> ChatSessionModel {
        let chat = try await buildChat(workspace: workspace, record: record, agent: agent)
        // Made by another caller while this one waited (its tab shown while a line comment opened it, CMT-05): that
        // chat is the conversation's, and a second one would run a second agent nobody stops. This one never started.
        if let existing = chats[record.id] { return existing }
        register(chat, conversationId: record.id, workspaceId: workspace.id)
        return chat
    }

    private func register(_ chat: ChatSessionModel, conversationId: String, workspaceId: String) {
        chats[conversationId] = chat
        chatWorkspaceIds[conversationId] = workspaceId
    }

    /// A chat for `record`, with its history and the model's hooks, neither registered nor started (`AGM-02` builds one
    /// before it replaces the conversation's). It waits for the login environment, the repository account's token and
    /// the agent's launch, which installs the agent on its first use.
    private func buildChat(workspace: Workspace, record: ChatSessionRecord, agent: AgentKind) async throws -> ChatSessionModel {
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
        // AGM-04: under the Claude instance the chat started with, which a later change of the setting does not reach.
        let claudeInstance = repo(id: current.repoId)?.claudeConfigDir
        chat.onModelOption = { [weak self] option in
            self?.modelCatalog.record(option, agent: agent, claudeInstance: claudeInstance)
        }
        chat.onToast = { [weak self] text in self?.onToast?(text) }
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

    /// `KBD-04`: ⌃` (View ▸ Toggle Terminal) in the workspace. The menu command cannot reach the state it toggles, the
    /// terminal panel's selected tab and its fold, which are the workspace view's (M2.8 Decision 11): it bumps the
    /// workspace's serial in `terminalToggleRequests`, and the view acts on each new value.
    public func requestTerminalToggle(workspaceId: String) {
        terminalToggleRequests[workspaceId, default: 0] += 1
    }

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

    /// What the workspace's panel header shows (HDR-02, ERR-01), whether or not a turn runs.
    public func pullRequestHeader(workspaceId: String) -> HeaderPresentation {
        (pullRequests.panels[workspaceId] ?? PullRequestPanelState()).header()
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
        showConversationTab(workspaceId: workspaceId)
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

    // MARK: Changes (GIT-01, GIT-03, GIT-05, CHG-01…CHG-03)

    /// The tab a workspace's right panel shows: the one it picked, else Changes, the design's default (M2.7 fell back to
    /// Checks). The pull request pill still picks Checks.
    public func rightPanelTab(workspaceId: String) -> RightPanelTab {
        rightPanelTabs[workspaceId] ?? .changes
    }

    /// Whether the workspace's full diff is computed on each change: it is selected and shows it, in its Changes tab, in
    /// its All files tab (FIL-02's letters, FIL-05's "Becoming changed"), in a diff tab on screen, so an open diff
    /// follows the agent with the panel on Checks or closed, or in Quick Open (FIL-08's letters and changed files).
    private func showsChanges(workspaceId: String) -> Bool {
        guard workspaceId == selectedWorkspaceId else { return false }
        return visibleRightPanelTab == .changes || visibleRightPanelTab == .files || selectedDiffTabs[workspaceId] != nil
            || quickOpenWorkspaceId == workspaceId
    }

    /// GIT-01's "on a change": the sidebar's stats for every workspace, and the full diff for the one on screen. Called
    /// on the main actor for each batch of the workspace's stream; `events` name the folders (FIL-07's tree reads them).
    private func filesChanged(workspaceId: String, events: FolderEvents) {
        guard workspace(id: workspaceId) != nil else { return }
        Task { await refreshChanges(workspaceId: workspaceId) }
        // EDIT-03: the workspace's open editors look at their files.
        checkEditors(workspaceId: workspaceId)
        // FIL-07: the All files tab's list and the folders the events name.
        fileTreeChanged(workspaceId: workspaceId, events: events)
    }

    /// Runs git for the workspace now: its stats, and its full diff while it shows it (the Changes tab's Refresh, a
    /// change on disk). Serialized per workspace: asked again while a run is in flight, it runs once more after it, so a
    /// burst of events never piles up git processes. Returns once the workspace's state is current.
    public func refreshChanges(workspaceId: String) async {
        if let running = gitRefreshes[workspaceId] {
            gitRefreshes[workspaceId]?.runsAgain = true
            await running.task.value
            return
        }
        let task = Task { await runGitRefreshes(workspaceId: workspaceId) }
        gitRefreshes[workspaceId] = GitRefresh(task: task)
        await task.value
    }

    private func runGitRefreshes(workspaceId: String) async {
        repeat {
            gitRefreshes[workspaceId]?.runsAgain = false
            await refreshGitOnce(workspaceId: workspaceId)
        } while gitRefreshes[workspaceId]?.runsAgain == true
        gitRefreshes[workspaceId] = nil
    }

    /// What one git run found: the full diff, the stats alone, a worktree busy with a rebase, merge or index lock
    /// (GIT-01 skips it until the next event), or git's failure.
    private enum GitReading: Sendable {
        case changes(WorkspaceChanges)
        case stat(DiffStat)
        case busy
        case failed(String)
    }

    private func refreshGitOnce(workspaceId: String) async {
        await launchEnvironment?.value
        guard let workspace = workspace(id: workspaceId) else { return }
        let wantsChanges = showsChanges(workspaceId: workspaceId)
        let service = GitChangesService(environment: environment(for: workspace))
        let worktree = URL(fileURLWithPath: workspace.path)
        let baseRef = workspace.baseRef
        let reading = await Task.blocking { () -> GitReading in
            guard !GitChangesService.isBusy(worktree: worktree) else { return .busy }
            do {
                let base = try service.base(worktree: worktree, baseRef: baseRef)
                // The full diff has the totals too: one reading, not two.
                if wantsChanges {
                    return .changes(try service.changes(worktree: worktree, base: base))
                }
                return .stat(try service.shortstat(worktree: worktree, base: base))
            } catch {
                return .failed(GitBranchService.branchError(error).description)
            }
        }.value
        // Removed while git ran.
        guard self.workspace(id: workspaceId) != nil else { return }
        switch reading {
        case .changes(let found):
            if showsChanges(workspaceId: workspaceId) { changes[workspaceId] = found }
            diffStats[workspaceId] = found.stat
            staleChanges.remove(workspaceId)
            if changesFailures[workspaceId]?.action == .diff { changesFailures[workspaceId] = nil }
        case .stat(let stat):
            diffStats[workspaceId] = stat
            staleChanges.insert(workspaceId)
        case .busy:
            staleChanges.insert(workspaceId)
        case .failed(let message):
            staleChanges.insert(workspaceId)
            if wantsChanges { changesFailures[workspaceId] = ChangesFailure(action: .diff, message: message) }
        }
        // The tab came into view while git ran without it: its diff is due now.
        if !wantsChanges { refreshShownChangesIfStale() }
    }

    /// The selected workspace's full diff, when it shows it and has none yet or changed since the last one.
    private func refreshShownChangesIfStale() {
        guard let workspaceId = selectedWorkspaceId, showsChanges(workspaceId: workspaceId),
              changes[workspaceId] == nil || staleChanges.contains(workspaceId) else { return }
        // Marked current now, so a second call before the run starts asks for nothing more.
        staleChanges.remove(workspaceId)
        Task { await refreshChanges(workspaceId: workspaceId) }
    }

    /// GIT-01: one stream per workspace, started when the model loads it and stopped when it goes, with the state
    /// kept for it. A new stream reads the stats once, so the sidebar has them without waiting for a change.
    private func syncWatchers() {
        let ids = Set(workspaces.values.joined().map(\.id))
        for id in watchedWorkspaceIds.subtracting(ids) {
            watchedWorkspaceIds.remove(id)
            watchers.removeValue(forKey: id)?.stop()
            diffStats[id] = nil
            changes[id] = nil
            changesFailures[id] = nil
            commits[id] = nil
            staleChanges.remove(id)
            editors[id] = nil
            editorBases[id] = nil
            fileTrees[id] = nil
            staleFileTrees[id] = nil
            canonicalWorktrees[id] = nil
            previewTabs[id] = nil
            revealedPaths[id] = nil
            recentFiles[id] = nil
            commentDrafts[id] = nil
            handledLineScrolls[id] = nil
        }
        for workspace in workspaces.values.joined() where !watchedWorkspaceIds.contains(workspace.id) {
            startWatching(workspace)
        }
    }

    private func startWatching(_ workspace: Workspace) {
        let workspaceId = workspace.id
        watchedWorkspaceIds.insert(workspaceId)
        let watch = watchWorkspace
        let worktree = URL(fileURLWithPath: workspace.path)
        let onChange: @Sendable (FolderEvents) -> Void = { [weak self] events in
            guard let self else { return }
            Task { @MainActor in self.filesChanged(workspaceId: workspaceId, events: events) }
        }
        Task {
            // Reading the worktree's `.git` file and resolving paths touch the disk: not on the main actor.
            let (watcher, canonical) = await Task.blocking { (watch(worktree, onChange), FileWatcher.canonicalPath(worktree)) }.value
            guard watchedWorkspaceIds.contains(workspaceId) else {
                watcher.stop()
                return
            }
            canonicalWorktrees[workspaceId] = canonical
            watchers[workspaceId] = watcher
            await refreshChanges(workspaceId: workspaceId)
        }
    }

    /// The worktree-relative path of the diff tab on screen: CHG-03's selected row and where ⌥⌘↓ / ⌥⌘↑ start.
    public func selectedChangedFile(workspaceId: String) -> String? {
        selectedDiffTabs[workspaceId]
    }

    /// CHG-03's ⌥⌘↓ (`step` 1) and ⌥⌘↑ (-1): the next or previous file of the Changes tab's list, in its diff tab.
    public func showAdjacentChangedFile(workspaceId: String, step: Int) {
        let current = selectedChangedFile(workspaceId: workspaceId)
        guard let next = changes[workspaceId]?.file(after: current, step: step) else { return }
        openDiff(workspaceId: workspaceId, path: next.path)
    }

    /// GIT-05: the files' uncommitted changes go, tracked ones back to HEAD and untracked ones to the Trash; committed
    /// changes stay. The diff tabs of the files discarded close, and a failure shows in the Changes tab with git's last
    /// lines (ERR-02).
    public func discardChanges(workspaceId: String, paths: [String]) async {
        guard let workspace = workspace(id: workspaceId), let current = changes[workspaceId] else { return }
        let files = paths.compactMap { current.file(at: $0) }.filter(\.isUncommitted)
        guard !files.isEmpty else { return }
        let service = GitChangesService(environment: environment(for: workspace))
        let worktree = URL(fileURLWithPath: workspace.path)
        let targets = files.map { (path: $0.path, isUntracked: $0.isUntracked) }
        let (discarded, failure) = await Task.blocking { () -> ([String], String?) in
            var discarded: [String] = []
            var failures: [String] = []
            for target in targets {
                do {
                    try service.discard(worktree: worktree, path: target.path, isUntracked: target.isUntracked)
                    discarded.append(target.path)
                } catch {
                    failures.append(GitBranchService.branchError(error).description)
                }
            }
            return (discarded, failures.isEmpty ? nil : failures.joined(separator: "\n"))
        }.value
        for path in discarded {
            closeDiff(workspaceId: workspaceId, path: path)
        }
        await refreshChanges(workspaceId: workspaceId)
        if let failure {
            changesFailures[workspaceId] = ChangesFailure(action: .discard, message: failure)
        } else if changesFailures[workspaceId]?.action == .discard {
            changesFailures[workspaceId] = nil
        }
    }

    /// Hides the Changes tab's failure line.
    public func dismissChangesFailure(workspaceId: String) {
        changesFailures[workspaceId] = nil
    }

    // MARK: Commit (GIT-04, ERR-02)

    /// What one commit came to: made, or git's failure ("git commit exited 1", or why it did not run).
    private enum CommitOutcome: Sendable {
        case committed
        case failed(String)
    }

    /// GIT-04's Commit: `git add -A`, then `git commit` with `subject` and `description` (trimmed; an empty description
    /// is left out), in the worktree with the workspace environment. Hooks run, and what they write streams into
    /// `commits` while it runs. A failure keeps the message, the output and git's exit status for the sheet (ERR-02);
    /// a commit that worked says "Committed" and reads the changes again. Returns whether the commit was made.
    public func commitChanges(workspaceId: String, subject: String, description: String) async -> Bool {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard workspace(id: workspaceId) != nil, !subject.isEmpty, commits[workspaceId]?.isRunning != true else { return false }
        commits[workspaceId] = CommitProgress(subject: subject, description: description)
        // The login shell's environment first, or the hooks would run without the user's PATH.
        await launchEnvironment?.value
        guard let workspace = workspace(id: workspaceId) else {
            commits[workspaceId] = nil
            return false
        }
        let service = GitChangesService(environment: environment(for: workspace))
        let worktree = URL(fileURLWithPath: workspace.path)
        let body: String? = description.isEmpty ? nil : description
        // The lines reach the sheet in the order git wrote them: one stream, read here on the main actor.
        let (output, sink) = AsyncStream<[String]>.makeStream()
        let run = Task.blocking { () -> CommitOutcome in
            defer { sink.finish() }
            do {
                try service.commit(worktree: worktree, subject: subject, description: body) { sink.yield($0) }
                return .committed
            } catch let failure as GitCommitFailure {
                return .failed(failure.summary)
            } catch {
                return .failed(GitBranchService.branchError(error).description)
            }
        }
        for await lines in output {
            commits[workspaceId]?.append(lines)
        }
        let outcome = await run.value
        // Removed while git ran.
        guard self.workspace(id: workspaceId) != nil else {
            commits[workspaceId] = nil
            return false
        }
        switch outcome {
        case .committed:
            // The workspace's stream reports the commit too; this reads it now, so the sheet closes onto the new list.
            await refreshChanges(workspaceId: workspaceId)
            commits[workspaceId] = nil
            onToast?("Committed")
            return true
        case .failed(let message):
            commits[workspaceId]?.fail(message)
            return false
        }
    }

    /// The commit sheet closed: the failure it showed goes. A commit that still runs keeps its state, and its sheet.
    public func dismissCommit(workspaceId: String) {
        guard commits[workspaceId]?.isRunning == false else { return }
        commits[workspaceId] = nil
    }

    // MARK: Diff tabs (DIFF-01…DIFF-05)

    /// DIFF-01: shows the worktree file at `path` (worktree-relative) in its diff tab, opening the tab after the
    /// workspace's others if needed. A `mode` is the tab's from now on; without one a new tab shows its diff and an
    /// open tab keeps its mode (CHG-03's click selects the tab, its Edit asks for the editor).
    public func openDiff(workspaceId: String, path: String, mode: DiffTabMode? = nil) {
        guard workspace(id: workspaceId) != nil else { return }
        // Opened as a regular tab (the Changes tab, a badge, ⌥⌘↓): the preview of the same file is kept (FIL-05).
        if previewTabs[workspaceId] == path { previewTabs[workspaceId] = nil }
        showWorktreeTab(workspaceId: workspaceId, path: path, mode: mode)
    }

    /// The worktree tab of `path` on screen, opened after the workspace's others if needed; `mode` is its mode from now
    /// on. Every open goes through here (`openDiff`, `openFromTree`), so the file becomes the workspace's newest recent
    /// file (FIL-08); selecting a tab already on screen (`showDiff`) does not.
    private func showWorktreeTab(workspaceId: String, path: String, mode: DiffTabMode?) {
        var tabs = diffTabs[workspaceId] ?? []
        if !tabs.contains(path) { tabs.append(path) }
        diffTabs[workspaceId] = tabs
        if let mode { diffTabModes[workspaceId, default: [:]][path] = mode }
        selectedFiles[workspaceId] = nil
        selectedDiffTabs[workspaceId] = path
        recordRecentFile(path, workspaceId: workspaceId)
    }

    public func showDiff(workspaceId: String, path: String) {
        guard diffTabs[workspaceId]?.contains(path) == true else { return }
        selectedFiles[workspaceId] = nil
        selectedDiffTabs[workspaceId] = path
    }

    /// Closes a diff tab; if it was on screen, the selected conversation comes back, as for a file tab. Its editor and
    /// base go with it, unsaved edits included (the tab asks first, `EDIT-02`), unless a file tab shows the same file.
    public func closeDiff(workspaceId: String, path: String) {
        diffTabs[workspaceId]?.removeAll { $0 == path }
        if selectedDiffTabs[workspaceId] == path { selectedDiffTabs[workspaceId] = nil }
        forgetWorktreeTab(workspaceId: workspaceId, path: path)
    }

    /// What a worktree tab that closed, or a preview that was replaced, leaves behind: its mode, its base, its comment
    /// box (CMT-02), its preview mark, and its editor unless a file tab shows the same file.
    private func forgetWorktreeTab(workspaceId: String, path: String) {
        diffTabModes[workspaceId]?[path] = nil
        editorBases[workspaceId]?[path] = nil
        commentDrafts[workspaceId]?[path] = nil
        if previewTabs[workspaceId] == path { previewTabs[workspaceId] = nil }
        if let workspace = workspace(id: workspaceId) {
            dropEditorIfUnused(workspaceId: workspaceId, path: Self.editorPath(worktree: workspace.path, relativePath: path))
        }
    }

    /// The mode the tab picked. The view shows the diff of a file that cannot be edited (`FileDiff.isEditable`)
    /// whatever was picked.
    public func diffMode(workspaceId: String, path: String) -> DiffTabMode {
        diffTabModes[workspaceId]?[path] ?? .diff
    }

    public func setDiffMode(_ mode: DiffTabMode, workspaceId: String, path: String) {
        guard diffTabs[workspaceId]?.contains(path) == true else { return }
        diffTabModes[workspaceId, default: [:]][path] = mode
    }

    /// DIFF-05 and FIL-05: a file badge of the conversation. A worktree file in Changes opens its diff tab on the diff,
    /// scrolled to its first hunk. While the workspace's changes are not read (its panel on Checks or closed), a worktree
    /// file opens that way too, and the tab reads them. Any other worktree file opens its worktree tab in Edit, the tab
    /// the tree opens, so one file never has two tabs and two buffers. A file outside the worktree opens a file tab, as
    /// before M3.
    public func openBadgeFile(workspaceId: String, path: String) {
        guard let workspace = workspace(id: workspaceId), let relative = worktreeRelativePath(of: path, in: workspace) else {
            openFile(workspaceId: workspaceId, path: path)
            return
        }
        if let current = changes[workspaceId], current.file(at: relative) == nil {
            openDiff(workspaceId: workspaceId, path: relative, mode: .edit)
            return
        }
        openDiff(workspaceId: workspaceId, path: relative, mode: .diff)
        requestDiffScroll(workspaceId: workspaceId, path: relative, line: nil)
    }

    /// CMT-06: a line chip of the conversation. Its path resolves like a file badge's (`openBadgeFile`): a worktree file
    /// in Changes, or any while the changes are not read, opens its diff tab on the diff, scrolled to the range's first
    /// line; a file no longer changed opens its worktree tab in Edit, the unchanged file's tab (FIL-05); a file outside
    /// the worktree a file tab.
    public func openLineRange(workspaceId: String, attachment: LineRangeAttachment) {
        guard let workspace = workspace(id: workspaceId), let relative = worktreeRelativePath(of: attachment.path, in: workspace) else {
            openFile(workspaceId: workspaceId, path: attachment.path)
            return
        }
        if let current = changes[workspaceId], current.file(at: relative) == nil {
            openDiff(workspaceId: workspaceId, path: relative, mode: .edit)
            return
        }
        openDiff(workspaceId: workspaceId, path: relative, mode: .diff)
        requestDiffScroll(workspaceId: workspaceId, path: relative, line: CommentLine(side: attachment.side, number: attachment.start))
    }

    /// The diff tab scrolled to the line `serial` asked for, so it does not scroll there again each time it appears.
    /// The request itself stays as it was: a badge's first-hunk request is told apart by having no line.
    public func lineScrollHandled(workspaceId: String, serial: Int) {
        guard diffScrollRequests[workspaceId]?.serial == serial, handledLineScrolls[workspaceId] != serial else { return }
        handledLineScrolls[workspaceId] = serial
    }

    private func requestDiffScroll(workspaceId: String, path: String, line: CommentLine?) {
        let serial = (diffScrollRequests[workspaceId]?.serial ?? 0) + 1
        diffScrollRequests[workspaceId] = DiffScrollRequest(path: path, serial: serial, line: line)
    }

    /// `path` relative to the workspace's worktree, when it is a file inside it: spelled as the worktree's own path, or
    /// resolved as FSEvents reports it (`canonicalWorktrees`, `/private/var/…` for `/var/…`), so a badge whose path the
    /// agent resolved reaches the same tab, and the same buffer, as the tree's. No disk is touched: both spellings of
    /// the worktree are known, and a link inside it (a linked `.env`) stays the worktree's file.
    func worktreeRelativePath(of path: String, in workspace: Workspace) -> String? {
        if let relative = Self.worktreeRelativePath(of: path, worktree: workspace.path) { return relative }
        guard let canonical = canonicalWorktrees[workspace.id], canonical != workspace.path else { return nil }
        return Self.worktreeRelativePath(of: path, worktree: canonical)
    }

    /// `path` relative to the worktree at `worktree`, when it is a file inside it; nil otherwise. A plain comparison of
    /// the absolute paths, which touches no disk: badges carry the path the agent was given, the worktree's own.
    static func worktreeRelativePath(of path: String, worktree: String) -> String? {
        let root = worktree.hasSuffix("/") ? worktree : worktree + "/"
        guard path.hasPrefix(root), path.count > root.count else { return nil }
        return String(path.dropFirst(root.count))
    }

    /// DIFF-03's "Binary file · 24 KB → 31 KB": the file's size at the base (git's object) and on disk, nil for the
    /// side it lacks (an added file has no base, a deleted one no file).
    public func binarySizes(workspaceId: String, path: String) async -> (old: Int?, new: Int?) {
        guard let workspace = workspace(id: workspaceId), let current = changes[workspaceId],
              let file = current.file(at: path) else { return (nil, nil) }
        let service = GitChangesService(environment: environment(for: workspace))
        let worktree = URL(fileURLWithPath: workspace.path)
        let base = current.base
        let oldPath: String? = file.status == .added ? nil : (file.oldPath ?? file.path)
        let newPath: String? = file.status == .deleted ? nil : file.path
        return await Task.blocking { () -> (old: Int?, new: Int?) in
            let old = oldPath.flatMap { service.blobSize(worktree: worktree, commit: base, path: $0) }
            let new = newPath.flatMap { path -> Int? in
                let attributes = try? FileManager.default.attributesOfItem(atPath: worktree.appendingPathComponent(path).path)
                return attributes?[.size] as? Int
            }
            return (old, new)
        }.value
    }

    // MARK: All files (FIL-01…FIL-07)

    /// Whether the workspace's All files tab shows now: it is selected and its panel is open on that tab. Git's list and
    /// the folders are read only then (FIL-07).
    private func showsFiles(workspaceId: String) -> Bool {
        workspaceId == selectedWorkspaceId && visibleRightPanelTab == .files
    }

    /// FIL-03's Show Ignored Files of the workspace's repository.
    public func showsIgnoredFiles(workspaceId: String) -> Bool {
        workspace(id: workspaceId).flatMap { repo(id: $0.repoId) }?.showsIgnoredFiles ?? false
    }

    /// The selected workspace's tab state, made the first time it is needed from the expanded folders the store keeps
    /// for it: the first time ever there are none, so only the top level shows. nil for another workspace, which keeps
    /// nothing.
    private func prepareFileTree(workspaceId: String) -> FileTreeState? {
        if let state = fileTrees[workspaceId] { return state }
        guard workspaceId == selectedWorkspaceId, workspace(id: workspaceId) != nil else { return nil }
        var state = FileTreeState()
        do {
            state.expanded = try store.expandedFolders(workspaceId: workspaceId)
        } catch {
            errorMessage = "Could not read the expanded folders: \(error)"
        }
        fileTrees[workspaceId] = state
        return state
    }

    /// FIL-07: git's list when the tab has none or it is stale, and the listings its rows need that are missing or
    /// stale. When the tab is hidden, or everything is current, nothing runs.
    private func refreshShownFilesIfNeeded() {
        guard let workspaceId = selectedWorkspaceId, showsFiles(workspaceId: workspaceId),
              let state = prepareFileTree(workspaceId: workspaceId), needsRead(state, workspaceId: workspaceId) else { return }
        Task { await refreshFiles(workspaceId: workspaceId) }
    }

    /// Whether git's list is missing or stale: all Quick Open reads (FIL-08).
    private func needsList(_ state: FileTreeState, workspaceId: String) -> Bool {
        state.list == nil || staleFileTrees[workspaceId]?.list == true
    }

    private func needsRead(_ state: FileTreeState, workspaceId: String) -> Bool {
        let stale = staleFileTrees[workspaceId]
        if needsList(state, workspaceId: workspaceId) { return true }
        let shown = FileTree.shownFolders(
            listings: state.listings,
            expanded: state.expanded,
            list: state.list,
            showsIgnored: showsIgnoredFiles(workspaceId: workspaceId)
        )
        return shown.contains { state.listings[$0] == nil || stale?.folders.contains($0) == true }
    }

    /// Reads what the shown tab needs, serialized per workspace like `refreshChanges`: asked again while a read is in
    /// flight, it reads once more after it. Returns once the tab's state is current.
    func refreshFiles(workspaceId: String) async {
        if let running = fileReads[workspaceId] {
            fileReads[workspaceId]?.runsAgain = true
            await running.task.value
            return
        }
        let task = Task { await runFileReads(workspaceId: workspaceId) }
        fileReads[workspaceId] = FileRead(task: task)
        await task.value
    }

    private func runFileReads(workspaceId: String) async {
        repeat {
            fileReads[workspaceId]?.runsAgain = false
            await readFilesOnce(workspaceId: workspaceId)
        } while fileReads[workspaceId]?.runsAgain == true
        fileReads[workspaceId] = nil
    }

    /// What one read found: git's list when it was read, its failure, and the folders read.
    private struct FileTreeReading: Sendable {
        var list: FileList?
        var listFailure: String?
        var listings: [String: [FileEntry]] = [:]
    }

    /// One read, in one blocking job: `ls-files` when the list is missing or stale, then the folders from the root down
    /// through the expanded ones the rows reach, reading only those missing or stale (FIL-07). A folder that cannot be
    /// read lists nothing, so it is not read again until an event names it. For Quick Open alone (FIL-08), with the
    /// All files tab hidden, only the list is read, and the folders an event marked stay marked for the tab.
    private func readFilesOnce(workspaceId: String) async {
        await launchEnvironment?.value
        let readsFolders = showsFiles(workspaceId: workspaceId)
        guard readsFolders || quickOpenWorkspaceId == workspaceId, let workspace = workspace(id: workspaceId),
              let state = fileTrees[workspaceId],
              readsFolders ? needsRead(state, workspaceId: workspaceId) : needsList(state, workspaceId: workspaceId) else { return }
        // Cleared now: an event during the read marks what it names again, and the next run reads it.
        let stale: StaleFileTree
        if readsFolders {
            stale = staleFileTrees.removeValue(forKey: workspaceId) ?? StaleFileTree()
        } else {
            stale = StaleFileTree(list: staleFileTrees[workspaceId]?.list ?? false)
            staleFileTrees[workspaceId]?.list = false
        }
        let readsList = state.list == nil || stale.list
        let previous = state.list
        let cached = state.listings
        let expanded = state.expanded
        let showsIgnored = showsIgnoredFiles(workspaceId: workspaceId)
        let reader = worktreeFiles(environment(for: workspace))
        let worktree = URL(fileURLWithPath: workspace.path)
        let reading = await Task.blocking { () -> FileTreeReading in
            var result = FileTreeReading()
            var list = previous
            if readsList {
                do {
                    let found = try reader.list(worktree: worktree, reusing: previous)
                    result.list = found
                    list = found
                } catch {
                    result.listFailure = GitBranchService.branchError(error).description
                }
            }
            guard readsFolders else { return result }
            var pending = [""]
            var visited: Set<String> = []
            while let folder = pending.popLast() {
                guard visited.insert(folder).inserted else { continue }
                var entries = cached[folder]
                if entries == nil || stale.folders.contains(folder) {
                    let read = (try? reader.listing(worktree: worktree, folder: folder)) ?? []
                    result.listings[folder] = read
                    entries = read
                }
                pending += FileTree.shownSubfolders(of: folder, entries: entries ?? [], expanded: expanded, list: list, showsIgnored: showsIgnored)
            }
            return result
        }.value
        // Another workspace was selected, or this one removed, while it ran.
        guard var current = fileTrees[workspaceId] else { return }
        var changed = false
        if let list = reading.list, list != current.list {
            current.list = list
            changed = true
        }
        if readsList, current.listFailure != reading.listFailure {
            current.listFailure = reading.listFailure
            changed = true
        }
        for (folder, entries) in reading.listings where current.listings[folder] != entries {
            current.listings[folder] = entries
            changed = true
        }
        if changed { fileTrees[workspaceId] = current }
    }

    /// FIL-07 after a batch of events: git's list is stale, and so is each folder the events name (or a subtree
    /// holds). A folder whose rows show is read again while the tab shows, or when it shows next; any other is dropped
    /// from the cache, so it is read when it opens. While the tab is hidden nothing runs.
    private func fileTreeChanged(workspaceId: String, events: FolderEvents) {
        guard var state = fileTrees[workspaceId], let workspace = workspace(id: workspaceId) else { return }
        var folders: Set<String> = []
        var subtrees: Set<String> = []
        // As the worktree's own path spells it and as FSEvents does, so tests' events and FSEvents' are both read.
        for root in Set([workspace.path, canonicalWorktrees[workspaceId] ?? workspace.path]) {
            let named = FileTree.invalidated(by: events, worktree: root)
            folders.formUnion(named.folders)
            subtrees.formUnion(named.subtrees)
        }
        let shown = FileTree.shownFolders(
            listings: state.listings,
            expanded: state.expanded,
            list: state.list,
            showsIgnored: showsIgnoredFiles(workspaceId: workspaceId)
        )
        let inSubtree = { (folder: String) in
            subtrees.contains { $0.isEmpty || folder == $0 || folder.hasPrefix($0 + "/") }
        }
        let hit = folders.union(state.listings.keys.filter(inSubtree)).union(shown.filter(inSubtree))
        var stale = staleFileTrees[workspaceId] ?? StaleFileTree()
        stale.list = true
        var dropped = false
        for folder in hit {
            if shown.contains(folder) {
                stale.folders.insert(folder)
            } else if state.listings.removeValue(forKey: folder) != nil {
                dropped = true
            }
        }
        staleFileTrees[workspaceId] = stale
        if dropped { fileTrees[workspaceId] = state }
        if showsFiles(workspaceId: workspaceId) {
            Task { await refreshFiles(workspaceId: workspaceId) }
        }
    }

    /// FIL-02's disclosure: a folder opens or closes, and the workspace's expanded folders are stored. An opened folder
    /// is read again each time, since a folder FSEvents leaves out (`node_modules`, shown with Show Ignored Files)
    /// hears of no change.
    public func setFolder(_ path: String, expanded: Bool, workspaceId: String) {
        guard var state = prepareFileTree(workspaceId: workspaceId), state.expanded.contains(path) != expanded else { return }
        if expanded {
            state.expanded.insert(path)
            staleFileTrees[workspaceId, default: StaleFileTree()].folders.insert(path)
        } else {
            state.expanded.remove(path)
        }
        fileTrees[workspaceId] = state
        storeExpandedFolders(state.expanded, workspaceId: workspaceId)
        refreshShownFilesIfNeeded()
    }

    /// The "⋯" menu's Collapse All Folders: the stored set is emptied too.
    public func collapseAllFolders(workspaceId: String) {
        guard var state = prepareFileTree(workspaceId: workspaceId), !state.expanded.isEmpty else { return }
        state.expanded = []
        fileTrees[workspaceId] = state
        storeExpandedFolders([], workspaceId: workspaceId)
    }

    /// FIL-03's Show Ignored Files, remembered per repository: its column alone is written, and the model's copy of the
    /// repository follows. Ignored folders left expanded show again, and their listings are read.
    public func setShowsIgnoredFiles(_ shows: Bool, repoId: String) {
        guard let index = repos.firstIndex(where: { $0.id == repoId }), repos[index].showsIgnoredFiles != shows else { return }
        do {
            try store.setShowsIgnoredFiles(shows, repoId: repoId)
        } catch {
            errorMessage = "Could not save Show Ignored Files: \(error)"
            return
        }
        repos[index].showsIgnoredFiles = shows
        refreshShownFilesIfNeeded()
    }

    private func storeExpandedFolders(_ expanded: Set<String>, workspaceId: String) {
        do {
            try store.setExpandedFolders(expanded, workspaceId: workspaceId)
        } catch {
            errorMessage = "Could not save the expanded folders: \(error)"
        }
    }

    /// FIL-05 from the tree and Quick Open (`path` worktree-relative): a single click, the tree's Return or Quick Open's
    /// ⌥Return (`keep` false) opens the workspace's one preview tab or replaces it, unless the preview has unsaved
    /// edits. A double-click's second click keeps the preview it opened; a file opened to keep (`keep` true, Quick
    /// Open's Return) gets a kept tab after the others and leaves the preview alone: only a new preview replaces the
    /// preview. A file in Changes opens in Diff mode, or as its open tab was left; any other in Edit, its only mode. A
    /// tab already open is only shown, and a kept one never turns into the preview.
    public func openFromTree(workspaceId: String, path: String, keep: Bool) {
        guard let workspace = workspace(id: workspaceId) else { return }
        var tabs = diffTabs[workspaceId] ?? []
        let preview = previewTabs[workspaceId]
        if !tabs.contains(path) {
            if !keep, let preview, let index = tabs.firstIndex(of: preview),
               !isEditorDirty(workspaceId: workspaceId, path: Self.editorPath(worktree: workspace.path, relativePath: preview)) {
                tabs[index] = path
                diffTabs[workspaceId] = tabs
                forgetWorktreeTab(workspaceId: workspaceId, path: preview)
            } else {
                tabs.append(path)
                diffTabs[workspaceId] = tabs
            }
            if !keep { previewTabs[workspaceId] = path }
        } else if keep, preview == path {
            previewTabs[workspaceId] = nil
        }
        // Before the changes are read the tab picks nothing: it shows its diff, and Edit once it is known unchanged.
        var mode: DiffTabMode?
        if let current = changes[workspaceId], current.file(at: path) == nil { mode = .edit }
        showWorktreeTab(workspaceId: workspaceId, path: path, mode: mode)
    }

    /// FIL-05: a double-click on the preview tab, or the first edit, keeps it: the next click in the tree opens another.
    public func keepPreview(workspaceId: String) {
        previewTabs[workspaceId] = nil
    }

    /// FIL-05's Reveal in All Files and the tree's Reveal Active File (`path` worktree-relative): the panel's tab turns
    /// to All files, the file's folders are expanded and stored, and the tab scrolls its row into view once it is drawn
    /// (`revealedPaths`). The view opens the panel and clears the filter.
    public func reveal(workspaceId: String, path: String) {
        guard workspace(id: workspaceId) != nil else { return }
        rightPanelTabs[workspaceId] = .files
        let ancestors = FileTree.ancestors(of: path)
        if var state = prepareFileTree(workspaceId: workspaceId) {
            if !state.expanded.isSuperset(of: ancestors) {
                state.expanded.formUnion(ancestors)
                fileTrees[workspaceId] = state
                storeExpandedFolders(state.expanded, workspaceId: workspaceId)
            }
        } else {
            let stored = (try? store.expandedFolders(workspaceId: workspaceId)) ?? []
            if !stored.isSuperset(of: ancestors) { storeExpandedFolders(stored.union(ancestors), workspaceId: workspaceId) }
        }
        revealedPaths[workspaceId] = path
        refreshShownFilesIfNeeded()
    }

    /// The All files tab scrolled the revealed row into view.
    public func revealHandled(workspaceId: String) {
        revealedPaths[workspaceId] = nil
    }

    // MARK: Quick Open (FIL-08)

    /// Quick Open is about to show for the selected workspace: its file list's state is made if needed, its recent
    /// files are read from the store once per launch, and git's list is read only when there is none or an event made
    /// it stale since the last read, so at most once per opening. The read lists no folder, and Quick Open never makes
    /// the All files tab count as shown: events while it is open only mark the list stale, and typing reads nothing.
    /// Its status letters need the full diff, which is computed now if it is missing or stale (`showsChanges`).
    public func quickOpenWillShow(workspaceId: String) {
        guard workspaceId == selectedWorkspaceId, let state = prepareFileTree(workspaceId: workspaceId) else { return }
        quickOpenWorkspaceId = workspaceId
        loadRecentFilesIfNeeded(workspaceId: workspaceId)
        refreshShownChangesIfStale()
        if needsList(state, workspaceId: workspaceId) {
            Task { await refreshFiles(workspaceId: workspaceId) }
        }
    }

    /// Quick Open closed: nothing more is read for it.
    public func quickOpenDidHide() {
        quickOpenWorkspaceId = nil
    }

    private func loadRecentFilesIfNeeded(workspaceId: String) {
        guard recentFiles[workspaceId] == nil else { return }
        do {
            recentFiles[workspaceId] = try store.recentFiles(workspaceId: workspaceId)
        } catch {
            errorMessage = "Could not read the recent files: \(error)"
            recentFiles[workspaceId] = []
        }
    }

    /// FIL-08: `path` becomes the workspace's newest recent file, in the store and here. A store failure says so and
    /// changes nothing else: the tab still opens, and the list stays as the store has it.
    private func recordRecentFile(_ path: String, workspaceId: String) {
        loadRecentFilesIfNeeded(workspaceId: workspaceId)
        do {
            try store.recordRecentFile(path: path, workspaceId: workspaceId, at: Date())
        } catch {
            errorMessage = "Could not save the recent files: \(error)"
            return
        }
        var recent = recentFiles[workspaceId] ?? []
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        recentFiles[workspaceId] = Array(recent.prefix(QuickOpen.recentLimit))
    }

    // MARK: Editing (EDIT-01…EDIT-04)

    /// The key of a worktree tab's file in `editors`: the worktree's path joined with the tab's relative path, as the diff
    /// tab builds its file's URL.
    public static func editorPath(worktree: String, relativePath: String) -> String {
        URL(fileURLWithPath: worktree).appendingPathComponent(relativePath).path
    }

    public func editor(workspaceId: String, path: String) -> EditorState? {
        editors[workspaceId]?[path]
    }

    /// Whether the file's editor has unsaved edits: its tab's dot (DIFF-01) and the question on close (EDIT-02).
    public func isEditorDirty(workspaceId: String, path: String) -> Bool {
        editors[workspaceId]?[path]?.document?.buffer.isDirty ?? false
    }

    /// EDIT-01: reads the file at `path` (absolute) into the editor, off the main actor. A file already open keeps its
    /// buffer, so its unsaved edits survive the tab being hidden and shown again.
    public func openEditor(workspaceId: String, path: String) async {
        guard workspace(id: workspaceId) != nil, editors[workspaceId]?[path] == nil else { return }
        editors[workspaceId, default: [:]][path] = .loading
        let url = URL(fileURLWithPath: path)
        let snapshot = await Task.blocking { TextFile.snapshot(of: url) }.value
        // Closed, or the workspace removed, while it was read.
        guard editors[workspaceId]?[path] == .loading else { return }
        editors[workspaceId]?[path] = EditorState(snapshot)
    }

    /// The editor's text as it is typed (EDIT-01). A read-only file (over 2 MB) takes none.
    public func setEditorText(_ text: String, workspaceId: String, path: String) {
        guard var document = editors[workspaceId]?[path]?.document, !document.isReadOnly, document.buffer.text != text else { return }
        document.buffer.text = text
        editors[workspaceId]?[path] = .document(document)
        // FIL-05: the first edit keeps a preview tab, so a preview never holds unsaved edits.
        if let preview = previewTabs[workspaceId], let workspace = workspace(id: workspaceId),
           Self.editorPath(worktree: workspace.path, relativePath: preview) == path {
            previewTabs[workspaceId] = nil
        }
    }

    /// What one save found: written with its new stamp and size, the file changed since the buffer read it (and what
    /// it holds now), or the write's failure.
    private enum SaveResult: Sendable {
        case saved(FileStamp, size: Int)
        case changed(TextFile.Snapshot)
        case failed(String)
    }

    /// EDIT-02's ⌘S and Save: writes the editor's text over the file in one step, with the file's line endings and byte
    /// order mark, at a link's target (`TextFile.write`). EDIT-03 and Review Focus 3: the file must still be what the
    /// buffer loaded, or the version Keep Mine was chosen over; otherwise nothing is written and the conflict banner
    /// shows. A file only touched (its date moved, not its bytes) is taken in and written. A save inside the worktree
    /// refreshes the changes, so the diff and the change bars follow. Returns whether the file was written.
    @discardableResult
    public func saveEditor(workspaceId: String, path: String) async -> Bool {
        let key = workspaceId + "\u{0}" + path
        guard !savingEditors.contains(key), let first = editors[workspaceId]?[path]?.document, !first.isReadOnly,
              first.buffer.isDirty || first.buffer.keepsMine else { return false }
        savingEditors.insert(key)
        defer { savingEditors.remove(key) }
        let url = URL(fileURLWithPath: path)
        for _ in 0..<2 {
            guard let document = editors[workspaceId]?[path]?.document else { return false }
            let buffer = document.buffer
            let text = buffer.text
            let data = document.format.encode(text)
            // The check and the write are one job, so the agent's window between them stays small (Known risks).
            let result = await Task.blocking { () -> SaveResult in
                let current = TextFile.snapshot(of: url)
                guard buffer.canSave(current: current.stamp) else { return .changed(current) }
                do {
                    return .saved(try TextFile.write(data, to: url), size: data.count)
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value
            // Closed while it was written.
            guard var latest = editors[workspaceId]?[path]?.document else { return false }
            switch result {
            case .saved(let stamp, let size):
                latest.buffer.saved(text, stamp: stamp)
                latest.size = size
                editors[workspaceId]?[path] = .document(latest)
                if let workspace = workspace(id: workspaceId), Self.worktreeRelativePath(of: path, worktree: workspace.path) != nil {
                    Task { await refreshChanges(workspaceId: workspaceId) }
                }
                return true
            case .changed(let current):
                _ = latest.buffer.diskChanged(to: current.text ?? "", stamp: current.stamp)
                editors[workspaceId]?[path] = .document(latest)
                guard latest.buffer.canSave(current: current.stamp), latest.buffer.isDirty || latest.buffer.keepsMine else { return false }
            case .failed(let message):
                errorMessage = "Couldn’t save \(url.lastPathComponent): \(message)"
                return false
            }
        }
        return false
    }

    /// The file of the tab `workspaceId` shows over its conversation: its diff tab's file or its file tab's, as an
    /// `editors` key; nil while a conversation shows.
    public func visibleEditorPath(workspaceId: String) -> String? {
        if let diff = selectedDiffTabs[workspaceId] {
            guard let workspace = workspace(id: workspaceId) else { return nil }
            return Self.editorPath(worktree: workspace.path, relativePath: diff)
        }
        return selectedFiles[workspaceId]
    }

    /// File ▸ Save (⌘S, KBD-02): whether the file on screen has edits to write, when its header shows Save (EDIT-02).
    public func canSaveVisibleEditor(workspaceId: String) -> Bool {
        guard let path = visibleEditorPath(workspaceId: workspaceId),
              let document = editors[workspaceId]?[path]?.document else { return false }
        return !document.isReadOnly && (document.buffer.isDirty || document.buffer.keepsMine)
    }

    /// File ▸ Save: `saveEditor` on the file on screen. Returns whether it was written.
    @discardableResult
    public func saveVisibleEditor(workspaceId: String) async -> Bool {
        guard canSaveVisibleEditor(workspaceId: workspaceId), let path = visibleEditorPath(workspaceId: workspaceId) else { return false }
        return await saveEditor(workspaceId: workspaceId, path: path)
    }

    // MARK: Unsaved edits (EDIT-02)

    /// Every file with unsaved edits, in one workspace or in all: what closing a tab, or quitting Rocky, asks about.
    /// Ordered by workspace title, then file.
    public func unsavedEditors(workspaceId: String? = nil) -> [UnsavedEditor] {
        var found: [UnsavedEditor] = []
        for (id, files) in editors where workspaceId == nil || id == workspaceId {
            guard let workspace = workspace(id: id) else { continue }
            let workspaceTitle = title(for: workspace).text
            for (path, state) in files where state.document?.buffer.isDirty == true {
                let file = Self.worktreeRelativePath(of: path, worktree: workspace.path) ?? (path as NSString).abbreviatingWithTildeInPath
                found.append(UnsavedEditor(workspaceId: id, path: path, file: file, workspaceTitle: workspaceTitle))
            }
        }
        return found.sorted { ($0.workspaceTitle, $0.file, $0.workspaceId) < ($1.workspaceTitle, $1.file, $1.workspaceId) }
    }

    /// Save All: each file written as ⌘S writes it, one after the other. Returns the files still unsaved: a save that
    /// a change on disk stopped (the tab shows the conflict, EDIT-03) or one that failed (`errorMessage`).
    public func saveEditors(_ unsaved: [UnsavedEditor]) async -> [UnsavedEditor] {
        var left: [UnsavedEditor] = []
        for editor in unsaved {
            await saveEditor(workspaceId: editor.workspaceId, path: editor.path)
            if isEditorDirty(workspaceId: editor.workspaceId, path: editor.path) { left.append(editor) }
        }
        return left
    }

    /// The file's workspace and tab on screen, for a Save All that could not save it: its conflict banner is there.
    public func showUnsavedEditor(_ editor: UnsavedEditor) {
        guard let workspace = workspace(id: editor.workspaceId) else { return }
        selectedWorkspaceId = workspace.id
        if let relative = Self.worktreeRelativePath(of: editor.path, worktree: workspace.path),
           diffTabs[workspace.id]?.contains(relative) == true {
            showDiff(workspaceId: workspace.id, path: relative)
        } else {
            showFile(workspaceId: workspace.id, path: editor.path)
        }
    }

    /// EDIT-03's Reload: the unsaved edits go, for the file's version on disk.
    public func reloadEditor(workspaceId: String, path: String) {
        guard var document = editors[workspaceId]?[path]?.document, document.buffer.disk != nil else { return }
        document.buffer.reload()
        editors[workspaceId]?[path] = .document(document)
    }

    /// EDIT-03's Keep Mine: the edits stay, and the next save overwrites the file's new version.
    public func keepMine(workspaceId: String, path: String) {
        guard var document = editors[workspaceId]?[path]?.document, document.buffer.conflict else { return }
        document.buffer.keepMine()
        editors[workspaceId]?[path] = .document(document)
    }

    /// Closes EDIT-03's agent-working banner in the file's tab, until the tab closes.
    public func hideAgentBanner(workspaceId: String, path: String) {
        guard var document = editors[workspaceId]?[path]?.document, !document.hidesAgentBanner else { return }
        document.hidesAgentBanner = true
        editors[workspaceId]?[path] = .document(document)
    }

    /// The agent whose turn runs in one of the workspace's conversations, for EDIT-03's "Claude Code is working in this
    /// workspace and may change this file."; nil while none runs.
    public func workingAgent(workspaceId: String) -> AgentKind? {
        chats.first { chatWorkspaceIds[$0.key] == workspaceId && $0.value.state == .running }?.value.agent
    }

    /// EDIT-04: the version of a worktree file its change bars compare with: the file at the workspace's base, under its
    /// old name for a rename, or none for a file the base lacks. nil until the changes are read.
    public func editorBaseKey(workspaceId: String, relativePath: String) -> EditorBase.Key? {
        guard let changes = changes[workspaceId] else { return nil }
        let file = changes.file(at: relativePath)
        if file?.status == .added { return EditorBase.Key(commit: changes.base, path: nil) }
        return EditorBase.Key(commit: changes.base, path: file?.oldPath ?? relativePath)
    }

    /// Reads the base `editorBaseKey` names for a diff tab's file, once per key: `git cat-file blob` off the main
    /// actor, and nothing for a file the base lacks.
    public func loadEditorBase(workspaceId: String, relativePath: String) async {
        guard let workspace = workspace(id: workspaceId),
              let key = editorBaseKey(workspaceId: workspaceId, relativePath: relativePath),
              editorBases[workspaceId]?[relativePath]?.key != key else { return }
        guard let source = key.path else {
            editorBases[workspaceId, default: [:]][relativePath] = EditorBase(key: key, text: "")
            return
        }
        let service = GitChangesService(environment: environment(for: workspace))
        let worktree = URL(fileURLWithPath: workspace.path)
        let text = await Task.blocking { () -> String? in
            guard let data = service.blob(worktree: worktree, commit: key.commit, path: source),
                  !data.prefix(TextFile.sniffLength).contains(0) else { return nil }
            return TextFormat.decode(data)?.text
        }.value
        // The tab closed, or the base moved, while git ran.
        guard diffTabs[workspaceId]?.contains(relativePath) == true,
              editorBaseKey(workspaceId: workspaceId, relativePath: relativePath) == key else { return }
        editorBases[workspaceId, default: [:]][relativePath] = EditorBase(key: key, text: text)
    }

    /// The loaded base of a diff tab's change bars, when it is the one `editorBaseKey` names now; nil hides the bars.
    public func editorBaseText(workspaceId: String, relativePath: String) -> String? {
        guard let base = editorBases[workspaceId]?[relativePath],
              base.key == editorBaseKey(workspaceId: workspaceId, relativePath: relativePath) else { return nil }
        return base.text
    }

    /// One file `checkEditors` looks at, and the newest version of it the editor knew when the check started.
    private struct EditorCheck: Sendable {
        let path: String
        let stamp: FileStamp
    }

    /// EDIT-03 after a change on disk: each open file of the workspace whose modification date moved is read again, in
    /// one job off the main actor. A clean buffer takes the new text and shows "Reloaded"; one with unsaved edits keeps
    /// them and shows the conflict. A file that came back is read, and a clean one that went shows as missing.
    private func checkEditors(workspaceId: String) {
        var checks: [EditorCheck] = []
        for (path, state) in editors[workspaceId] ?? [:] {
            switch state {
            case .document(let document): checks.append(EditorCheck(path: path, stamp: document.buffer.latestStamp))
            case .missing: checks.append(EditorCheck(path: path, stamp: .missing))
            case .loading, .unavailable: break
            }
        }
        guard !checks.isEmpty else { return }
        let pending = checks
        Task {
            let found = await Task.blocking { () -> [(check: EditorCheck, snapshot: TextFile.Snapshot)] in
                pending.compactMap { check -> (check: EditorCheck, snapshot: TextFile.Snapshot)? in
                    let url = URL(fileURLWithPath: check.path)
                    // A stat each; the file is read only when its date is not the one the editor knows.
                    guard TextFile.modificationDate(of: url) != check.stamp.modificationDate else { return nil }
                    return (check: check, snapshot: TextFile.snapshot(of: url))
                }
            }.value
            for (check, snapshot) in found {
                applyDiskChange(snapshot, checked: check.stamp, workspaceId: workspaceId, path: check.path)
            }
        }
    }

    private func applyDiskChange(_ snapshot: TextFile.Snapshot, checked: FileStamp, workspaceId: String, path: String) {
        switch editors[workspaceId]?[path] {
        case .missing?:
            guard checked == .missing, snapshot.exists else { return }
            editors[workspaceId]?[path] = EditorState(snapshot)
        case .document(var document)?:
            // Saved or reloaded while the file was read: the next event checks again.
            guard document.buffer.latestStamp == checked, snapshot.stamp != checked else { return }
            guard let text = snapshot.text else {
                // Gone, or no longer text Rocky edits: a clean tab shows the file as it is now; unsaved edits stay, in
                // conflict with an empty file.
                if document.buffer.isDirty {
                    _ = document.buffer.diskChanged(to: "", stamp: snapshot.stamp)
                    editors[workspaceId]?[path] = .document(document)
                } else {
                    editors[workspaceId]?[path] = EditorState(snapshot)
                }
                return
            }
            if document.buffer.diskChanged(to: text, stamp: snapshot.stamp) == .reloaded {
                // A fresh document, so a file whose line endings or size changed is written back the new way.
                var reloaded = EditorDocument(snapshot: snapshot, text: text)
                let now = Date()
                reloaded.reloadedAt = now
                reloaded.hidesAgentBanner = document.hidesAgentBanner
                document = reloaded
                endReloaded(at: now, workspaceId: workspaceId, path: path)
            }
            editors[workspaceId]?[path] = .document(document)
        case .loading?, .unavailable?, nil:
            return
        }
    }

    /// EDIT-03's "Reloaded" shows for 2 s: one sleep per reload, never a timer.
    private func endReloaded(at reloadedAt: Date, workspaceId: String, path: String) {
        Task {
            try? await Task.sleep(for: Self.reloadedDuration)
            guard var document = editors[workspaceId]?[path]?.document, document.reloadedAt == reloadedAt else { return }
            document.reloadedAt = nil
            editors[workspaceId]?[path] = .document(document)
        }
    }

    static let reloadedDuration = Duration.seconds(2)

    /// Drops a file's editor once no tab of the workspace shows it: no file tab at `path`, and no diff tab whose file it
    /// is.
    private func dropEditorIfUnused(workspaceId: String, path: String) {
        guard editors[workspaceId]?[path] != nil, openFiles[workspaceId]?.contains(path) != true else { return }
        if let workspace = workspace(id: workspaceId),
           let relative = Self.worktreeRelativePath(of: path, worktree: workspace.path),
           diffTabs[workspaceId]?.contains(relative) == true { return }
        editors[workspaceId]?[path] = nil
    }

    // MARK: Line comments (CMT-01, CMT-02, CMT-05)

    /// The comment box of the diff tab of `path` (worktree-relative), while it is open.
    public func commentDraft(workspaceId: String, path: String) -> CommentDraft? {
        commentDrafts[workspaceId]?[path]
    }

    /// CMT-01's selection ended: the tab's box opens on `lines` of `side`, or moves there with its text and its
    /// conversation, as the mock keeps them for another range of the same file. Only for an open diff tab. Opening a
    /// box keeps a preview tab (FIL-05), so a click in the tree never takes a comment being written away with it.
    @discardableResult
    public func openCommentDraft(workspaceId: String, path: String, side: CommentLine.Side, lines: ClosedRange<Int>) -> CommentDraft? {
        guard diffTabs[workspaceId]?.contains(path) == true else { return nil }
        if previewTabs[workspaceId] == path { previewTabs[workspaceId] = nil }
        if let draft = commentDrafts[workspaceId]?[path] {
            draft.move(side: side, lines: lines)
            return draft
        }
        let draft = CommentDraft(side: side, lines: lines)
        commentDrafts[workspaceId, default: [:]][path] = draft
        return draft
    }

    /// CMT-02's Cancel and Esc, and Send once the comment has gone: the box goes.
    public func dropCommentDraft(workspaceId: String, path: String) {
        commentDrafts[workspaceId]?[path] = nil
    }

    /// The conversation a box sends to (CMT-02's "Sending to"): the one picked in its menu while its tab is still
    /// open, else the one the workspace shows, else its newest open one.
    public func commentConversation(for draft: CommentDraft, workspaceId: String) -> ChatSessionRecord? {
        let open = conversations[workspaceId] ?? []
        for id in [draft.conversationId, selectedConversationIds[workspaceId]].compactMap({ $0 }) {
            if let record = open.first(where: { $0.id == id }) { return record }
        }
        return open.last
    }

    /// CMT-05's Send: `comment` goes to the conversation at once, or into its queue while its turn runs; the toast says
    /// which. A conversation whose tab was never shown gets its chat now, and an agent not started, or stopped, starts
    /// first, as Send now starts a stopped one. The selected conversation and the tabs stay as they are, so the diff
    /// stays on screen. Returns once the comment is on its way or in the queue, not when the turn ends.
    public func sendLineComment(workspaceId: String, conversationId: String, comment: LineComment) async -> LineCommentOutcome {
        guard let workspace = workspace(id: workspaceId),
              (conversations[workspaceId] ?? []).contains(where: { $0.id == conversationId }) else { return .unavailable }
        if chats[conversationId] == nil {
            guard let record = try? store.session(id: conversationId), let agent = AgentKind(rawValue: record.agent) else {
                return .unavailable
            }
            do {
                try await makeChat(workspace: workspace, record: record, agent: agent)
            } catch {
                errorMessage = "Could not open the \(agent.displayName) conversation: \(error)"
                return .unavailable
            }
        }
        // Closed, or its workspace removed, while its chat was made.
        guard let chat = chats[conversationId] else { return .unavailable }
        if chat.state != .running, chat.state != .ready { await chat.start() }
        switch chat.state {
        case .running:
            chat.enqueue(comment)
            return .queued
        case .ready:
            // The turn runs on its own: `send` returns when the agent has answered. A turn that begins before this task
            // runs queues the comment instead.
            Task { await chat.send(comment) }
            return .sent
        case .idle, .starting, .stopped:
            return .unavailable
        }
    }

    /// CMT-05's Resend: a comment the message box sends with a chip that ↑ or a queued comment's Edit brought back. The
    /// agent's block is built again from the chip's lines as they are now: the new side from the worktree file, the
    /// removed side from the base with `git cat-file`, as the diff and EDIT-04 read it, both off the main actor. When
    /// any line of the range cannot be read (the file is gone, the range runs past its end, a binary file, a path
    /// outside the worktree on the removed side), the block goes without code, never with part of it (designer's
    /// update, 2026-09-25). `files`, attached next to the chip, go as links after the block, each one named in it.
    public func lineComment(for range: LineRangeAttachment, comment: String, files: [URL] = [], workspaceId: String) async -> LineComment {
        let workspace = workspace(id: workspaceId)
        let relative = workspace.flatMap { worktreeRelativePath(of: range.path, in: $0) }
        let lines = range.start...range.end
        let code: [String]?
        switch range.side {
        case .new:
            let url = URL(fileURLWithPath: range.path)
            code = await Task.blocking { DiffLayout.readLines(of: url).flatMap { Self.lines(lines, of: $0) } }.value
        case .old:
            code = await baseLines(lines, relativePath: relative, workspace: workspace)
        }
        let path = relative ?? range.path
        let prompt = ReviewPrompt.single(
            path: path,
            side: range.side,
            start: range.start,
            end: range.end,
            code: code,
            language: ReviewPrompt.fenceLanguage(forPath: path),
            comment: ReviewPrompt.comment(comment, naming: files.map(\.path))
        )
        return LineComment(text: comment, range: range, prompt: prompt, files: files)
    }

    /// The removed side's `lines` from the base: the commit and a rename's old path the diff uses while the changes are
    /// read (`editorBaseKey`), else the base found now, at the chip's path. nil for a file the base lacks.
    private func baseLines(_ lines: ClosedRange<Int>, relativePath: String?, workspace: Workspace?) async -> [String]? {
        guard let workspace, let relativePath else { return nil }
        let known = editorBaseKey(workspaceId: workspace.id, relativePath: relativePath)
        if let known, known.path == nil { return nil }
        let service = GitChangesService(environment: environment(for: workspace))
        let worktree = URL(fileURLWithPath: workspace.path)
        let baseRef = workspace.baseRef
        return await Task.blocking { () -> [String]? in
            guard let commit = known?.commit ?? (try? service.base(worktree: worktree, baseRef: baseRef)),
                  let data = service.blob(worktree: worktree, commit: commit, path: known?.path ?? relativePath),
                  !GitChangesService.isBinary(data) else { return nil }
            // Split as the patch splits the removed rows, so the code reads as the diff showed it.
            return Self.lines(lines, of: DiffParser.lines(of: String(decoding: data, as: UTF8.self)))
        }.value
    }

    /// Every line of `range` in a file's `lines`, or nil when the file ends before the range does.
    nonisolated static func lines(_ range: ClosedRange<Int>, of lines: [String]) -> [String]? {
        guard range.lowerBound >= 1, range.upperBound <= lines.count else { return nil }
        return Array(lines[(range.lowerBound - 1)..<range.upperBound])
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
            syncWatchers()
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
            completedAt: record.completedAt,
            diffStat: record.additions.flatMap { additions in record.deletions.map { DiffStat(additions: additions, deletions: $0) } }
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
            completedAt: item.completedAt,
            additions: item.diffStat?.additions,
            deletions: item.diffStat?.deletions
        )
    }
}
