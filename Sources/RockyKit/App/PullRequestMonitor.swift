import Foundation
import Observation

/// Why the panel could not show the pull request (`ERR-01`), as the header's loading group names it.
public enum PanelError: Equatable, Sendable {
    /// No gh account or token for the repository, or GitHub refused the token.
    case accessRequired
    case offline
    /// origin is not a GitHub remote, or GitHub answered NOT_FOUND for the repository (Open question 5).
    case unavailable
    /// Anything else, with a detail for the line under the header.
    case couldNotLoad(String)

    /// Maps what a refresh threw. No case carries a token: gh's errors are redacted (`GitHubAccountError`), and
    /// GitHub's carry no request.
    public init(_ error: any Error) {
        switch error {
        case is GitHubAccountError:
            self = .accessRequired
        case let error as GitHubError:
            switch error {
            case .unauthorized: self = .accessRequired
            case .offline: self = .offline
            case .notFound: self = .unavailable
            case .rateLimited(let resetAt): self = .couldNotLoad(Self.rateLimitDetail(resetAt: resetAt))
            case .graphQL(let messages): self = .couldNotLoad(messages.joined(separator: " "))
            case .http(let status): self = .couldNotLoad("GitHub answered with HTTP \(status).")
            }
        case let error as PullRequestLoadError:
            switch error {
            case .noGitHubRemote: self = .unavailable
            }
        default:
            self = .couldNotLoad(error.localizedDescription)
        }
    }

    /// The header's label.
    public var label: String {
        switch self {
        case .accessRequired: "GitHub access required"
        case .offline: "No internet connection"
        case .unavailable: "PR info unavailable"
        case .couldNotLoad: "Couldn’t load PR info"
        }
    }

    /// The line under the header, next to Retry; access shows `gh auth login --hostname github.com` in the tab instead.
    public var detail: String? {
        switch self {
        case .couldNotLoad(let detail): detail
        case .accessRequired, .offline, .unavailable: nil
        }
    }

    private static func rateLimitDetail(resetAt: Date?) -> String {
        guard let resetAt else { return "GitHub's rate limit for this account is used up. Rocky tries again later." }
        return "GitHub's rate limit for this account is used up until \(resetAt.formatted(date: .omitted, time: .shortened))."
    }
}

/// What the monitor's loader throws besides GitHub's and gh's own errors.
public enum PullRequestLoadError: Error, Equatable, Sendable {
    /// origin is missing or not on github.com: "PR info unavailable".
    case noGitHubRemote
}

/// What started a refresh (`PR-07`). Every reason but a schedule tick also reads the local `git status` (GST-01).
public enum RefreshReason: Sendable {
    /// `windowVisible`: the window can be seen again (restored, shown, uncovered, back on this Space). `windowKey`:
    /// the user came back to Rocky from another app.
    case selected, windowVisible, windowKey, action, turnEnded, button, tick

    /// Git runs only on event triggers, never on the schedule's ticks (spec Section 1).
    public var readsLocalStatus: Bool { self != .tick }

    /// Coming back to the window needs only a refresh newer than the user's return, so one already running will do:
    /// a window restored from the Dock turns visible and key together and asks GitHub once.
    var joinsRunningRefresh: Bool { self == .windowVisible || self == .windowKey }
}

/// One workspace's panel: the last snapshot, the branch's local status, what is stored, and the pending comments.
public struct PullRequestPanelState: Equatable, Sendable {
    /// This launch's last successful refresh; nil until the first one.
    public var snapshot: PullRequestSnapshot?
    /// The last event trigger's `git status`; ticks leave it as it was.
    public var local: LocalGitStatus?
    /// The last state saved (`PR-07`), seeded from the store at launch.
    public var stored: StoredPullRequest?
    /// The repository's account (`ACC-01`), for the footer.
    public var login: String?
    public var isLoading: Bool
    /// The last refresh's failure; cleared by the next success. The snapshot stays (offline keeps the last state).
    public var error: PanelError?
    /// When the last successful refresh ended.
    public var updatedAt: Date?
    /// Pending comments without the hidden ones (`REV-01`), read only while they are visible.
    public var comments: [PendingComment]
    /// Comments sent to the chat in this launch (`AGT-05`), in memory only.
    public var addedCommentIds: Set<String>

    public init(
        snapshot: PullRequestSnapshot? = nil,
        local: LocalGitStatus? = nil,
        stored: StoredPullRequest? = nil,
        login: String? = nil,
        isLoading: Bool = false,
        error: PanelError? = nil,
        updatedAt: Date? = nil,
        comments: [PendingComment] = [],
        addedCommentIds: Set<String> = []
    ) {
        self.snapshot = snapshot
        self.local = local
        self.stored = stored
        self.login = login
        self.isLoading = isLoading
        self.error = error
        self.updatedAt = updatedAt
        self.comments = comments
        self.addedCommentIds = addedCommentIds
    }

    /// The state (what is stored): from the snapshot, else the stored one, else `loadingPR`.
    public var headerState: HeaderState {
        if let snapshot {
            return PullRequestHeader.state(pr: snapshot.pullRequest, local: local)
        }
        return stored.flatMap { HeaderState(rawValue: $0.headerState) } ?? .loadingPR
    }

    /// What the header shows (`HDR-02`, `ERR-01`). A failure shows its label in the loading group, except offline with
    /// a snapshot, which keeps the last state. Before this launch's first refresh of the workspace: "Loading PR info…",
    /// since a stored state lacks the counts and the local status its label needs.
    public func header() -> HeaderPresentation {
        if let error, error != .offline || snapshot == nil {
            return HeaderPresentation(group: .loading, label: error.label)
        }
        guard let snapshot else {
            return HeaderPresentation(group: .loading, label: "Loading PR info…", spins: true)
        }
        let state = PullRequestHeader.state(pr: snapshot.pullRequest, local: local)
        return PullRequestHeader.presentation(state, pr: snapshot.pullRequest, local: local)
    }
}

/// `PR-07`'s refresh loop. It polls only the selected workspace, only while the window can be seen, key or not (user
/// decision, 2026-09-24), every `PollSchedule.wait(running:)`, and refreshes at once on selection, on the window
/// coming back into view or to the front, after a Rocky action and when a turn ends. One refresh runs at a time per
/// workspace. The loader, the sleep and the clock are injected, so tests drive the schedule.
@MainActor
@Observable
public final class PullRequestMonitor {
    /// Loads a workspace: the snapshot, the local status when `includeLocal` (event triggers only, so a tick runs no
    /// git), and the pending comments when `comments` (only while they are visible).
    public typealias Load = @MainActor (_ workspaceId: String, _ includeLocal: Bool, _ comments: Bool) async throws
        -> (PullRequestSnapshot, LocalGitStatus?, [PendingComment]?)

    public private(set) var panels: [String: PullRequestPanelState] = [:]
    /// Called once when a monitored pull request turns merged (`SET-01`): the last state Rocky saw was open or draft.
    @ObservationIgnored public var onMerged: (@MainActor (String) -> Void)?

    @ObservationIgnored private let store: RockyStore
    @ObservationIgnored private let load: Load
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var selectedId: String?
    /// Whether any of the window can be seen; polling runs only then.
    @ObservationIgnored private var isVisible = true
    /// Whether the window is key, only to refresh when the user comes back to it.
    @ObservationIgnored private var isKey = true
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var inFlight: [String: InFlight] = [:]
    @ObservationIgnored private var commentsVisible: Set<String> = []

    private struct InFlight {
        let token: UUID
        let includesLocal: Bool
        let task: Task<Outcome, Never>
    }

    /// What a refresh saw, for the next wait.
    private struct Outcome {
        var running = false
        /// No GitHub remote or no access: polling cannot help until the user acts (Retry refreshes).
        var keepsPolling = true
    }

    public init(
        store: RockyStore,
        load: @escaping Load,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0, tolerance: $0 / 10) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.load = load
        self.sleep = sleep
        self.now = now
    }

    /// Shows each workspace's stored state until its first refresh, and forgets removed workspaces. Panels already
    /// loaded keep theirs.
    public func seed(_ workspaces: [Workspace]) {
        let ids = Set(workspaces.map(\.id))
        if panels.keys.contains(where: { !ids.contains($0) }) {
            panels = panels.filter { ids.contains($0.key) }
        }
        for workspace in workspaces where panels[workspace.id] == nil {
            panels[workspace.id] = PullRequestPanelState(stored: workspace.storedPullRequest)
        }
    }

    /// The selected workspace, or nil. Refreshes it at once and polls it; another workspace's wait is cancelled.
    public func select(_ workspaceId: String?) {
        guard workspaceId != selectedId else { return }
        selectedId = workspaceId
        stopPolling()
        guard let workspaceId, isVisible else { return }
        Task { await refresh(workspaceId: workspaceId, reason: .selected) }
    }

    /// Polling stops while no part of the window can be seen (minimized, hidden, fully covered, on another Space), and
    /// runs while it can, even with another app in front (user decision, 2026-09-24). Seen again, the selected
    /// workspace refreshes at once.
    public func windowVisibilityChanged(_ isVisible: Bool) {
        guard isVisible != self.isVisible else { return }
        self.isVisible = isVisible
        stopPolling()
        guard isVisible, let selectedId else { return }
        Task { await refresh(workspaceId: selectedId, reason: .windowVisible) }
    }

    /// Coming back to Rocky from another app refreshes the selected workspace at once and starts its wait over.
    /// Leaving it changes nothing: polling follows visibility.
    public func windowKeyChanged(_ isKey: Bool) {
        guard isKey != self.isKey else { return }
        self.isKey = isKey
        guard isKey, isVisible, let selectedId else { return }
        Task { await refresh(workspaceId: selectedId, reason: .windowKey) }
    }

    /// Refreshes now. An event refresh of the polled workspace starts its wait over; any workspace can be refreshed on
    /// an event (a turn that ended elsewhere updates its stored state).
    public func refresh(workspaceId: String, reason: RefreshReason) async {
        let outcome = await serializedLoad(workspaceId: workspaceId, reason: reason)
        guard reason != .tick, workspaceId == selectedId, isVisible else { return }
        startPolling(workspaceId: workspaceId, after: outcome)
    }

    /// Comments are read with the pull request only while the panel shows them (`REV-01`). Shown again, they are read
    /// at once rather than at the next tick.
    public func setCommentsVisible(_ visible: Bool, workspaceId: String) {
        guard visible else {
            commentsVisible.remove(workspaceId)
            return
        }
        guard commentsVisible.insert(workspaceId).inserted else { return }
        guard workspaceId == selectedId, isVisible, panels[workspaceId]?.snapshot?.pullRequest != nil else { return }
        Task { await refresh(workspaceId: workspaceId, reason: .button) }
    }

    /// `AGT-05`: comments sent to the chat show their check, in memory, until the branch has another pull request.
    public func markCommentsAdded(_ ids: [String], workspaceId: String) {
        update(workspaceId) { $0.addedCommentIds.formUnion(ids) }
    }

    /// `REV-01`'s Hide: the comment leaves the list, and its id is stored with the pull request's state (`PR-07`), so
    /// it stays hidden after a relaunch. A refresh keeps the hidden ids while the pull request is the same.
    public func hideComment(_ id: String, workspaceId: String) {
        update(workspaceId) { panel in
            panel.comments.removeAll { $0.id == id }
            guard var stored = panel.stored, !stored.hiddenCommentIds.contains(id) else { return }
            stored.hiddenCommentIds.append(id)
            panel.stored = stored
        }
        guard let stored = panels[workspaceId]?.stored else { return }
        try? store.savePullRequest(stored, workspaceId: workspaceId)
    }

    /// The repository's account, for the footer; the loader sets it before it asks GitHub.
    public func setLogin(_ login: String?, workspaceId: String) {
        guard panels[workspaceId]?.login != login else { return }
        update(workspaceId) { $0.login = login }
    }

    // MARK: Polling

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Ticks after `outcome`'s wait, then after each tick's, until cancelled (another selection, the window out of
    /// view, an event refresh starting over) or until polling cannot help.
    private func startPolling(workspaceId: String, after outcome: Outcome) {
        stopPolling()
        guard outcome.keepsPolling else { return }
        let firstWait = PollSchedule.wait(running: outcome.running)
        let sleep = self.sleep
        pollTask = Task { [weak self] in
            var wait = firstWait
            while true {
                do {
                    try await sleep(wait)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                let outcome = await self.serializedLoad(workspaceId: workspaceId, reason: .tick)
                guard !Task.isCancelled, outcome.keepsPolling else { return }
                wait = PollSchedule.wait(running: outcome.running)
            }
        }
    }

    // MARK: Loading

    /// One refresh at a time per workspace. A tick joins whatever runs, and so does the window coming back, to a
    /// running event refresh. Another event waits for a refresh that started before it, which may predate its cause (a
    /// push), then runs its own, unless another event started meanwhile.
    private func serializedLoad(workspaceId: String, reason: RefreshReason) async -> Outcome {
        let includeLocal = reason.readsLocalStatus
        var waited = false
        while let current = inFlight[workspaceId] {
            let joins = !includeLocal || ((waited || reason.joinsRunningRefresh) && current.includesLocal)
            if joins { return await current.task.value }
            _ = await current.task.value
            waited = true
        }
        let token = UUID()
        let task = Task {
            let outcome = await self.performLoad(workspaceId: workspaceId, includeLocal: includeLocal)
            // Cleared before anyone waiting on it resumes, so a waiter only ever sees a newer refresh here.
            if self.inFlight[workspaceId]?.token == token { self.inFlight[workspaceId] = nil }
            return outcome
        }
        inFlight[workspaceId] = InFlight(token: token, includesLocal: includeLocal, task: task)
        return await task.value
    }

    private func performLoad(workspaceId: String, includeLocal: Bool) async -> Outcome {
        let wantsComments = commentsVisible.contains(workspaceId)
        update(workspaceId) { $0.isLoading = true }
        do {
            let (snapshot, local, comments) = try await load(workspaceId, includeLocal, wantsComments)
            // Re-read: comments may have been hidden or added, or the account set, while GitHub answered.
            let before = panels[workspaceId] ?? PullRequestPanelState()
            var panel = before
            panel.snapshot = snapshot
            if let local { panel.local = local }
            let number = snapshot.pullRequest?.number
            if number != before.snapshot?.pullRequest?.number, before.snapshot != nil {
                // Another pull request (or none): the last one's comments are not this one's.
                panel.comments = []
                panel.addedCommentIds = []
            }
            let stored = Self.stored(snapshot: snapshot, local: panel.local, previous: before.stored, now: now())
            if let comments {
                let hidden = Set(stored?.hiddenCommentIds ?? [])
                panel.comments = comments.filter { !hidden.contains($0.id) }
            }
            panel.stored = stored
            panel.error = nil
            panel.isLoading = false
            panel.updatedAt = now()
            panels[workspaceId] = panel
            if !Self.sameIgnoringTime(stored, before.stored) {
                // Written only when something besides the time changed: a quiet tick does not touch the disk.
                try? store.savePullRequest(stored, workspaceId: workspaceId)
            }
            let wasOpen = ["OPEN", "DRAFT"].contains(Self.lastSeenState(before))
            if wasOpen, snapshot.pullRequest?.isMerged == true { onMerged?(workspaceId) }
            return Outcome(running: Self.isMoving(snapshot))
        } catch is CancellationError {
            update(workspaceId) { $0.isLoading = false }
            return Outcome(keepsPolling: false)
        } catch {
            let panelError = PanelError(error)
            update(workspaceId) {
                $0.isLoading = false
                $0.error = panelError
            }
            return Outcome(keepsPolling: panelError != .accessRequired && panelError != .unavailable)
        }
    }

    private func update(_ workspaceId: String, _ change: (inout PullRequestPanelState) -> Void) {
        var panel = panels[workspaceId] ?? PullRequestPanelState()
        change(&panel)
        panels[workspaceId] = panel
    }

    /// The row `PR-07` keeps: nil without a pull request. Hidden comments stay while it is the same pull request.
    static func stored(snapshot: PullRequestSnapshot, local: LocalGitStatus?, previous: StoredPullRequest?, now: Date) -> StoredPullRequest? {
        guard let pr = snapshot.pullRequest else { return nil }
        return StoredPullRequest(
            number: pr.number,
            url: pr.url,
            state: stateName(pr),
            headerState: PullRequestHeader.state(pr: pr, local: local).rawValue,
            checks: pr.checks,
            updatedAt: now,
            hiddenCommentIds: previous?.number == pr.number ? previous?.hiddenCommentIds ?? [] : []
        )
    }

    /// `StoredPullRequest.state`: "OPEN", "DRAFT" or "MERGED".
    static func stateName(_ pr: PullRequestInfo) -> String {
        pr.isMerged ? "MERGED" : pr.isDraft ? "DRAFT" : "OPEN"
    }

    /// The pull request state Rocky last saw: this launch's snapshot, else the stored one; nil for none.
    private static func lastSeenState(_ panel: PullRequestPanelState) -> String? {
        if let snapshot = panel.snapshot { return snapshot.pullRequest.map(stateName) }
        return panel.stored?.state
    }

    private static func sameIgnoringTime(_ a: StoredPullRequest?, _ b: StoredPullRequest?) -> Bool {
        guard var a, let b else { return a == nil && b == nil }
        a.updatedAt = b.updatedAt
        return a == b
    }

    /// Checks or deployments running keep the schedule at 15 s (`PR-07`), and so does GitHub still computing
    /// mergeability, which the header shows as moving ("Checking mergeability…").
    static func isMoving(_ snapshot: PullRequestSnapshot) -> Bool {
        guard let pr = snapshot.pullRequest, !pr.isMerged else { return false }
        let checksRun = pr.checks.contains { $0.state == .running || $0.state == .pending }
        let deploying = pr.latestDeployments.contains { ["IN_PROGRESS", "QUEUED", "PENDING", "WAITING"].contains($0.state) }
        return checksRun || deploying || pr.mergeStateStatus == "UNKNOWN"
    }
}
