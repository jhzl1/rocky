import Foundation
import Testing
@testable import RockyKit

/// A sleep the test ends by hand, one wait at a time. A cancelled wait throws, as `Task.sleep` does.
final class ManualSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var order: [UUID] = []
    private var asked: [Duration] = []

    /// Every wait asked for, cancelled ones included.
    var durations: [Duration] { lock.withLock { asked } }
    var waiting: Int { lock.withLock { pending.count } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    asked.append(duration)
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        pending[id] = continuation
                        order.append(id)
                    }
                }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                order.removeAll { $0 == id }
                return pending.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Ends the oldest wait.
    func fire() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !order.isEmpty else { return nil }
            return pending.removeValue(forKey: order.removeFirst())
        }
        continuation?.resume()
    }
}

/// The monitor's loader: records each call and answers with what the test set. The local status comes only when
/// asked, as `AppModel`'s loader runs git only then.
@MainActor
final class FakePullRequestLoader {
    struct Call: Equatable {
        let workspaceId: String
        let includeLocal: Bool
        let comments: Bool
    }

    private(set) var calls: [Call] = []
    var pullRequest: PullRequestInfo? = FakePullRequestLoader.openPullRequest()
    var local = LocalGitStatus(branch: "rocky/tokyo", upstream: "origin/rocky/tokyo")
    var comments: [PendingComment] = []
    var error: (any Error)?

    nonisolated static func openPullRequest(number: Int = 7, title: String = "Add /health") -> PullRequestInfo {
        PullRequestInfo(
            id: "PR_\(number)",
            number: number,
            url: URL(string: "https://github.com/jhzl1/rocky/pull/\(number)")!,
            title: title,
            body: "Returns 200.",
            baseRefName: "development",
            headRefName: "rocky/tokyo",
            mergeable: "MERGEABLE",
            mergeStateStatus: "CLEAN",
            checks: [PullRequestCheck(name: "unit", state: .passed)]
        )
    }

    var snapshot: PullRequestSnapshot {
        PullRequestSnapshot(repository: RepositorySettings(id: "R_1"), pullRequest: pullRequest, baseAheadBy: 1, baseBehindBy: 0)
    }

    func load(_ workspaceId: String, _ includeLocal: Bool, _ wantsComments: Bool) async throws -> (PullRequestSnapshot, LocalGitStatus?, [PendingComment]?) {
        calls.append(Call(workspaceId: workspaceId, includeLocal: includeLocal, comments: wantsComments))
        if let error { throw error }
        return (snapshot, includeLocal ? local : nil, wantsComments ? comments : nil)
    }
}

@MainActor
struct PullRequestMonitorTests {
    private func makeMonitor(store: RockyStore? = nil) throws -> (PullRequestMonitor, FakePullRequestLoader, ManualSleep) {
        let loader = FakePullRequestLoader()
        let sleeper = ManualSleep()
        let monitor = PullRequestMonitor(
            store: try store ?? RockyStore.inMemory(),
            load: { workspaceId, includeLocal, comments in try await loader.load(workspaceId, includeLocal, comments) },
            sleep: { try await sleeper.sleep($0) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        return (monitor, loader, sleeper)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    /// A store with one repository and one workspace, whose pull request columns `savePullRequest` writes.
    private func storeWithAWorkspace() throws -> (RockyStore, Workspace) {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "rocky", path: "/tmp/rocky-\(UUID().uuidString)")
        try store.add(repo)
        let workspace = Workspace(repoId: repo.id, name: "tokyo", path: "/tmp/rocky-worktrees/tokyo", branch: "rocky/tokyo")
        try store.add(workspace)
        return (store, workspace)
    }

    @Test func pollsOnlyTheSelectedWorkspace() async throws {
        let (monitor, loader, sleeper) = try makeMonitor()
        monitor.select("a")
        try await waitUntil { loader.calls.count == 1 && sleeper.waiting == 1 }
        sleeper.fire()
        try await waitUntil { loader.calls.count == 2 && sleeper.waiting == 1 }
        #expect(loader.calls.map(\.workspaceId) == ["a", "a"])
        // No backoff: every quiet tick waits 30 s.
        #expect(sleeper.durations == [.seconds(30), .seconds(30)])

        // Another selection cancels a's wait and starts b's.
        monitor.select("b")
        try await waitUntil { loader.calls.count == 3 && sleeper.waiting == 1 }
        sleeper.fire()
        try await waitUntil { loader.calls.count == 4 }
        #expect(loader.calls.map(\.workspaceId) == ["a", "a", "b", "b"])
        #expect(Array(sleeper.durations.prefix(3)) == [.seconds(30), .seconds(30), .seconds(30)])
        monitor.select(nil)
    }

    /// User decision, 2026-09-24: with another app in front and Rocky still in view, polling goes on.
    @Test func pollingGoesOnWhileTheWindowCanBeSeenButIsNotKey() async throws {
        let (monitor, loader, sleeper) = try makeMonitor()
        monitor.select("a")
        try await waitUntil { loader.calls.count == 1 && sleeper.waiting == 1 }

        monitor.windowKeyChanged(false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(sleeper.waiting == 1)
        #expect(loader.calls.count == 1)
        sleeper.fire()
        try await waitUntil { loader.calls.count == 2 && sleeper.waiting == 1 }
        #expect(loader.calls.last == .init(workspaceId: "a", includeLocal: false, comments: false))
        #expect(sleeper.durations == [.seconds(30), .seconds(30)])

        // Back to Rocky: a refresh at once, with the local status, and a new wait.
        monitor.windowKeyChanged(true)
        try await waitUntil { loader.calls.count == 3 && sleeper.durations.count == 3 && sleeper.waiting == 1 }
        #expect(loader.calls.last == .init(workspaceId: "a", includeLocal: true, comments: false))
        monitor.select(nil)
    }

    @Test func pollingStopsWhileTheWindowCannotBeSeen() async throws {
        let (monitor, loader, sleeper) = try makeMonitor()
        monitor.select("a")
        try await waitUntil { loader.calls.count == 1 && sleeper.waiting == 1 }

        monitor.windowVisibilityChanged(false)
        try await waitUntil { sleeper.waiting == 0 }
        // Nothing runs out of view: no tick, no refresh on a new selection.
        monitor.select("b")
        try await Task.sleep(for: .milliseconds(50))
        #expect(loader.calls.count == 1)
        #expect(sleeper.waiting == 0)

        // In view again: a refresh at once, with the local status, and polling from 30 s.
        monitor.windowVisibilityChanged(true)
        try await waitUntil { loader.calls.count == 2 && sleeper.waiting == 1 }
        #expect(loader.calls.last == .init(workspaceId: "b", includeLocal: true, comments: false))
        #expect(sleeper.durations.last == .seconds(30))
        monitor.select(nil)
    }

    /// A window restored from the Dock turns visible and key together: one refresh, not two.
    @Test func comingBackIntoViewAndToTheFrontRefreshesOnce() async throws {
        let (monitor, loader, sleeper) = try makeMonitor()
        monitor.select("a")
        try await waitUntil { loader.calls.count == 1 && sleeper.waiting == 1 }
        monitor.windowKeyChanged(false)
        monitor.windowVisibilityChanged(false)
        try await waitUntil { sleeper.waiting == 0 }

        monitor.windowVisibilityChanged(true)
        monitor.windowKeyChanged(true)
        try await waitUntil { loader.calls.count == 2 && sleeper.waiting == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(loader.calls.count == 2)
        #expect(sleeper.waiting == 1)
        monitor.select(nil)
    }

    @Test func turnEndRefreshesAtOnce() async throws {
        let (monitor, loader, sleeper) = try makeMonitor()
        monitor.select("a")
        try await waitUntil { loader.calls.count == 1 && sleeper.waiting == 1 }

        await monitor.refresh(workspaceId: "a", reason: .turnEnded)
        #expect(loader.calls.count == 2)
        #expect(loader.calls[1] == .init(workspaceId: "a", includeLocal: true, comments: false))
        // The wait starts over: the next tick is 30 s after the turn's refresh.
        try await waitUntil { sleeper.waiting == 1 && sleeper.durations.count == 2 }
        #expect(sleeper.durations.last == .seconds(30))

        // A turn that ends in another workspace refreshes that one and leaves a's schedule alone.
        await monitor.refresh(workspaceId: "b", reason: .turnEnded)
        #expect(loader.calls.last == .init(workspaceId: "b", includeLocal: true, comments: false))
        #expect(sleeper.waiting == 1)
        #expect(sleeper.durations.count == 2)
        monitor.select(nil)
    }

    /// Review Focus 1: only event triggers read the local status; the schedule's ticks run no git.
    @Test func scheduleTicksDoNotRunGit() async throws {
        let (monitor, loader, sleeper) = try makeMonitor()
        monitor.select("a")
        try await waitUntil { loader.calls.count == 1 && sleeper.waiting == 1 }
        loader.local.uncommitted = 4
        for expected in 2...4 {
            sleeper.fire()
            try await waitUntil { loader.calls.count == expected && sleeper.waiting == 1 }
        }
        #expect(loader.calls.first?.includeLocal == true)
        #expect(loader.calls.dropFirst().allSatisfy { !$0.includeLocal })
        // Ticks keep the last event's status.
        #expect(monitor.panels["a"]?.local?.uncommitted == 0)

        await monitor.refresh(workspaceId: "a", reason: .button)
        #expect(loader.calls.last?.includeLocal == true)
        #expect(monitor.panels["a"]?.local?.uncommitted == 4)
        monitor.select(nil)
    }

    /// PRB-01: the title and body are read-only and GitHub's, so the next refresh shows a title renamed on GitHub.
    @Test func refreshShowsTheTitleRenamedOnGitHub() async throws {
        let (monitor, loader, _) = try makeMonitor()
        await monitor.refresh(workspaceId: "a", reason: .button)
        #expect(monitor.panels["a"]?.snapshot?.pullRequest?.title == "Add /health")

        loader.pullRequest = FakePullRequestLoader.openPullRequest(title: "Renamed on GitHub")
        await monitor.refresh(workspaceId: "a", reason: .button)
        #expect(monitor.panels["a"]?.snapshot?.pullRequest?.title == "Renamed on GitHub")
    }

    @Test func offlineKeepsTheLastState() async throws {
        let (monitor, loader, _) = try makeMonitor()
        await monitor.refresh(workspaceId: "a", reason: .button)
        let loaded = try #require(monitor.panels["a"])
        #expect(loaded.header() == HeaderPresentation(group: .inSync, label: "Ready to merge", action: .merge))

        loader.error = GitHubError.offline
        await monitor.refresh(workspaceId: "a", reason: .button)
        let offline = try #require(monitor.panels["a"])
        #expect(offline.error == .offline)
        #expect(offline.snapshot == loaded.snapshot)
        #expect(offline.updatedAt == loaded.updatedAt)
        #expect(offline.header() == loaded.header())
        #expect(!offline.isLoading)

        // Back online, the error goes.
        loader.error = nil
        await monitor.refresh(workspaceId: "a", reason: .button)
        #expect(monitor.panels["a"]?.error == nil)
    }

    /// ERR-01: which label for which failure.
    @Test func failuresShowERR01Labels() async throws {
        let cases: [(any Error, PanelError, String)] = [
            (GitHubAccountError.notLoggedIn("jhzl1"), .accessRequired, "GitHub access required"),
            (GitHubAccountError.ghNotFound, .accessRequired, "GitHub access required"),
            (GitHubError.unauthorized, .accessRequired, "GitHub access required"),
            (GitHubError.offline, .offline, "No internet connection"),
            (GitHubError.notFound, .unavailable, "PR info unavailable"),
            (PullRequestLoadError.noGitHubRemote, .unavailable, "PR info unavailable"),
            (GitHubError.http(502), .couldNotLoad("GitHub answered with HTTP 502."), "Couldn’t load PR info"),
            (GitHubError.graphQL(["Something went wrong."]), .couldNotLoad("Something went wrong."), "Couldn’t load PR info"),
        ]
        for (error, expected, label) in cases {
            #expect(PanelError(error) == expected)
            #expect(expected.label == label)
        }
        #expect(PanelError.couldNotLoad("GitHub answered with HTTP 502.").detail == "GitHub answered with HTTP 502.")
        #expect(PanelError.accessRequired.detail == nil)

        // Without a snapshot, any failure is the header's label; the first load says it is loading.
        #expect(PullRequestPanelState().header() == HeaderPresentation(group: .loading, label: "Loading PR info…", spins: true))
        #expect(PullRequestPanelState(error: .offline).header() == HeaderPresentation(group: .loading, label: "No internet connection"))

        // With a snapshot, only offline keeps the last state.
        let (monitor, loader, _) = try makeMonitor()
        await monitor.refresh(workspaceId: "a", reason: .button)
        loader.error = GitHubError.notFound
        await monitor.refresh(workspaceId: "a", reason: .button)
        #expect(monitor.panels["a"]?.header() == HeaderPresentation(group: .loading, label: "PR info unavailable"))
    }

    /// No GitHub remote or no access: polling stops until the user retries.
    @Test func pollingStopsWhenOnlyTheUserCanHelp() async throws {
        let (monitor, loader, sleeper) = try makeMonitor()
        loader.error = GitHubError.unauthorized
        monitor.select("a")
        try await waitUntil { loader.calls.count == 1 && monitor.panels["a"]?.error == .accessRequired }
        try await Task.sleep(for: .milliseconds(50))
        #expect(sleeper.waiting == 0)

        // Offline keeps polling: the connection may come back.
        loader.error = GitHubError.offline
        await monitor.refresh(workspaceId: "a", reason: .button)
        try await waitUntil { sleeper.waiting == 1 }
        monitor.select(nil)
    }

    @Test func stateSurvivesRelaunch() async throws {
        let (store, workspace) = try storeWithAWorkspace()
        let (monitor, _, _) = try makeMonitor(store: store)
        monitor.seed([workspace])
        await monitor.refresh(workspaceId: workspace.id, reason: .button)
        let saved = try #require(monitor.panels[workspace.id]?.stored)
        #expect(saved.number == 7)
        #expect(saved.state == "OPEN")
        #expect(saved.headerState == HeaderState.readyToMerge.rawValue)
        #expect(saved.checks == [PullRequestCheck(name: "unit", state: .passed)])

        // Relaunch: a new monitor shows the stored state before its first refresh.
        let (relaunched, _, _) = try makeMonitor(store: store)
        relaunched.seed(try store.workspaces(repoId: workspace.repoId))
        let seeded = try #require(relaunched.panels[workspace.id])
        #expect(seeded.stored == saved)
        #expect(seeded.snapshot == nil)
        #expect(seeded.headerState == .readyToMerge)
        #expect(try store.workspaces(repoId: workspace.repoId).first?.name == "tokyo")

        // A removed workspace's panel goes at the next seed.
        relaunched.seed([])
        #expect(relaunched.panels.isEmpty)
    }

    @Test func mergeIsReportedOnce() async throws {
        let (monitor, loader, _) = try makeMonitor()
        var merged: [String] = []
        monitor.onMerged = { merged.append($0) }

        await monitor.refresh(workspaceId: "a", reason: .button)
        #expect(merged.isEmpty)
        loader.pullRequest?.isMerged = true
        await monitor.refresh(workspaceId: "a", reason: .button)
        #expect(merged == ["a"])
        await monitor.refresh(workspaceId: "a", reason: .button)
        #expect(merged == ["a"])

        // Stored as merged before this launch: seen merged again, not reported again.
        var old = Workspace(repoId: "R", name: "kyoto", path: "/tmp/kyoto", branch: "rocky/kyoto")
        old.prNumber = 7
        old.prUrl = "https://github.com/jhzl1/rocky/pull/7"
        old.prState = "MERGED"
        old.prHeaderState = HeaderState.merged.rawValue
        old.prUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        monitor.seed([old])
        await monitor.refresh(workspaceId: old.id, reason: .button)
        #expect(merged == ["a"])

        // Stored as open, seen merged at the first refresh of a launch: reported.
        var open = Workspace(repoId: "R", name: "oslo", path: "/tmp/oslo", branch: "rocky/oslo")
        open.prNumber = 7
        open.prUrl = "https://github.com/jhzl1/rocky/pull/7"
        open.prState = "OPEN"
        open.prHeaderState = HeaderState.readyToMerge.rawValue
        open.prUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        monitor.seed([old, open])
        await monitor.refresh(workspaceId: open.id, reason: .button)
        #expect(merged == ["a", open.id])
    }

    @Test func commentsAreReadOnlyWhileVisibleWithoutTheHiddenOnes() async throws {
        let (monitor, loader, _) = try makeMonitor()
        loader.comments = [
            PendingComment(id: "IC_1", kind: .conversation, author: "ana", body: "Add a test."),
            PendingComment(id: "IC_2", kind: .conversation, author: "ana", body: "Never mind."),
        ]
        var workspace = Workspace(repoId: "R", name: "tokyo", path: "/tmp/tokyo", branch: "rocky/tokyo")
        workspace.prNumber = 7
        workspace.prUrl = "https://github.com/jhzl1/rocky/pull/7"
        workspace.prState = "OPEN"
        workspace.prHeaderState = HeaderState.readyToMerge.rawValue
        workspace.prUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        workspace.prHiddenCommentIds = #"["IC_2"]"#
        monitor.seed([workspace])

        await monitor.refresh(workspaceId: workspace.id, reason: .button)
        #expect(loader.calls.last?.comments == false)
        #expect(monitor.panels[workspace.id]?.comments.isEmpty == true)

        monitor.setCommentsVisible(true, workspaceId: workspace.id)
        await monitor.refresh(workspaceId: workspace.id, reason: .button)
        #expect(loader.calls.last?.comments == true)
        #expect(monitor.panels[workspace.id]?.comments.map(\.id) == ["IC_1"])
        #expect(monitor.panels[workspace.id]?.stored?.hiddenCommentIds == ["IC_2"])

        monitor.setCommentsVisible(false, workspaceId: workspace.id)
        await monitor.refresh(workspaceId: workspace.id, reason: .button)
        #expect(loader.calls.last?.comments == false)
    }

    @Test func runningChecksKeepTheScheduleAt15Seconds() {
        var running = FakePullRequestLoader.openPullRequest()
        running.checks = [PullRequestCheck(name: "unit", state: .running)]
        #expect(PullRequestMonitor.isMoving(PullRequestSnapshot(repository: RepositorySettings(id: "R"), pullRequest: running)))
        var deploying = FakePullRequestLoader.openPullRequest()
        deploying.deployments = [PullRequestDeployment(environment: "Preview", state: "IN_PROGRESS")]
        #expect(PullRequestMonitor.isMoving(PullRequestSnapshot(repository: RepositorySettings(id: "R"), pullRequest: deploying)))
        #expect(!PullRequestMonitor.isMoving(PullRequestSnapshot(repository: RepositorySettings(id: "R"), pullRequest: FakePullRequestLoader.openPullRequest())))
        #expect(!PullRequestMonitor.isMoving(PullRequestSnapshot(repository: RepositorySettings(id: "R"), pullRequest: nil)))
    }
}
