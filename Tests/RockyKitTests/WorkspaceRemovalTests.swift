import Foundation
import Testing
@testable import RockyKit

/// WSC-07, KIT-19: a removed workspace goes off screen at once, nothing reads it while git removes it, its branch follows
/// the user's rule, and a refusal brings it back. Temporary repositories only.
@MainActor
struct WorkspaceRemovalTests {
    private func makeModel(watchers: FakeWatchers = FakeWatchers()) throws -> AppModel {
        let root = try Fixtures.temporaryDirectory("app")
        let paths = RockyPaths(database: root.appendingPathComponent("rocky.sqlite"), adapterPrefix: root.appendingPathComponent("agents"), logs: root)
        return AppModel(
            store: try RockyStore.inMemory(),
            paths: paths,
            captureEnvironment: { GitFixture.environment },
            makeLaunch: { kind, cwd, _, _ in
                let fake = Fixtures.fakeACPLaunch(agent: kind)
                return AgentLaunch(executable: fake.executable, arguments: fake.arguments, environment: fake.environment, cwd: cwd, stderrLog: fake.stderrLog)
            },
            installAdapter: { _, _, _, _ in },
            latestVersion: { _ in "0.0.0" },
            defaults: UserDefaults(suiteName: "rocky-tests-\(UUID().uuidString)")!,
            terminalShell: { _ in ("/bin/zsh", ["-f"]) },
            processStopGracePeriod: .milliseconds(500),
            runGH: { arguments, environment in try FakeGH(status: #"{"hosts":{}}"#).run(arguments, environment: environment) },
            lookUpGitHubRepository: { _, _ in nil },
            githubSession: OfflineURLProtocol.session(),
            watchWorkspace: { worktree, onChange in watchers.watch(worktree, onChange) }
        )
    }

    /// A model with one repository, and that repository's id.
    private func modelWithRepo(watchers: FakeWatchers = FakeWatchers()) async throws -> (AppModel, String) {
        let model = try makeModel(watchers: watchers)
        await model.bootstrap()
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        return (model, try #require(model.repos.first?.id))
    }

    /// A new workspace of the repository, once git has made it.
    private func newWorkspace(_ model: AppModel, repoId: String) async throws -> Workspace {
        await model.createWorkspace(repoId: repoId)
        return try #require(model.selectedWorkspace)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func hasBranch(_ branch: String, in repo: URL) async throws -> Bool {
        try await !GitFixture.gitOffMain(["branch", "--list", branch], in: repo).isEmpty
    }

    /// A Run script that ignores SIGTERM, running once `marker` exists: stopping it takes the model's whole grace
    /// period (500 ms here), which holds the removal off screen, before its git, for that long.
    private func startStubbornRun(_ model: AppModel, workspace: Workspace) async throws {
        let marker = try Fixtures.temporaryDirectory("marker").appendingPathComponent("trapped")
        model.setScripts(repoId: workspace.repoId, setup: "", run: "trap '' TERM; touch '\(marker.path)'; sleep 30", archive: "", runMode: .concurrent)
        await model.startRun(workspaceId: workspace.id)
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
    }

    /// The branch rule through the model: the empty `rocky/<name>` goes with its workspace, one with a commit of its own
    /// stays, and so does every branch the repository had.
    @Test func removingDeletesTheEmptyBranchAndKeepsOneWithItsOwnCommit() async throws {
        let (model, repoId) = try await modelWithRepo()
        let repo = URL(fileURLWithPath: try #require(model.repo(id: repoId)).path)

        let empty = try await newWorkspace(model, repoId: repoId)
        await model.removeWorkspace(id: empty.id)
        #expect(model.workspace(id: empty.id) == nil)
        #expect(try await !hasBranch(empty.branch, in: repo))

        let worked = try await newWorkspace(model, repoId: repoId)
        let worktree = URL(fileURLWithPath: worked.path)
        try await Task.blocking { try Data("mine\n".utf8).write(to: worktree.appendingPathComponent("mine.txt")) }.value
        try await GitFixture.gitOffMain(["add", "mine.txt"], in: worktree)
        try await GitFixture.gitOffMain(["commit", "-q", "-m", "mine"], in: worktree)
        await model.removeWorkspace(id: worked.id)
        #expect(model.workspace(id: worked.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: worked.path))
        #expect(try await hasBranch(worked.branch, in: repo))
        #expect(try await hasBranch("main", in: repo))
        #expect(model.removals.isEmpty)
    }

    /// The selection moves to the workspace below in the sidebar, else the one above, else none.
    @Test func theSelectionMovesToTheNextWorkspaceThenThePreviousThenNone() async throws {
        let (model, repoId) = try await modelWithRepo()
        let first = try await newWorkspace(model, repoId: repoId)
        let second = try await newWorkspace(model, repoId: repoId)
        let third = try await newWorkspace(model, repoId: repoId)
        model.visibleWorkspaceIds = [first.id, second.id, third.id]

        model.selectedWorkspaceId = second.id
        await model.removeWorkspace(id: second.id)
        #expect(model.selectedWorkspaceId == third.id)
        await model.removeWorkspace(id: third.id)
        #expect(model.selectedWorkspaceId == first.id)
        await model.removeWorkspace(id: first.id)
        #expect(model.selectedWorkspaceId == nil)
        #expect(model.workspaces[repoId]?.isEmpty == true)
    }

    /// Off screen at once, before any git: the row spins with "Removing lima…" and the selection has moved. Nothing
    /// reads the worktree while git removes it: the stream has stopped, and a read that would fail there, as in the
    /// half-deleted folder, shows nothing, not even with the workspace selected again. git's refusal (here, the
    /// folder's `.git` is gone) brings it back, with `removalFailure`, and reads start again.
    @Test func aReadThatFailsForAWorkspaceGoingAwayShowsNothing() async throws {
        let watchers = FakeWatchers()
        let (model, repoId) = try await modelWithRepo(watchers: watchers)
        let other = try await newWorkspace(model, repoId: repoId)
        let workspace = try await newWorkspace(model, repoId: repoId)
        try await waitUntil { watchers.watch(of: workspace.path) != nil && model.diffStats[workspace.id] != nil }
        let stream = try #require(watchers.watch(of: workspace.path))
        try await startStubbornRun(model, workspace: workspace)

        let removal = Task { await model.removeWorkspace(id: workspace.id) }
        try await waitUntil { model.removingWorkspaceIds.contains(workspace.id) }
        #expect(model.status(workspaceId: workspace.id) == .removing("Removing \(workspace.name)…"))
        #expect(model.selectedWorkspaceId == other.id)
        #expect(stream.isStopped)
        #expect(model.existingChat(workspaceId: workspace.id) == nil)

        let dotGit = URL(fileURLWithPath: workspace.path).appendingPathComponent(".git")
        try await Task.blocking { try FileManager.default.removeItem(at: dotGit) }.value
        model.selectedWorkspaceId = workspace.id
        model.visibleRightPanelTab = .changes
        watchers.fire(workspace.path)
        await model.refreshChanges(workspaceId: workspace.id)
        #expect(model.changesFailures[workspace.id] == nil)
        #expect(model.errorMessage == nil)

        await removal.value
        #expect(model.removals.isEmpty)
        #expect(model.workspace(id: workspace.id) != nil)
        let failure = try #require(model.removalFailure)
        #expect(failure.workspaceId == workspace.id)
        #expect(failure.workspaceName == workspace.name)
        #expect(failure.message.contains("fatal:"))
        #expect(model.errorMessage == nil)
        // Back, it is read again, and now git's failure shows where it belongs (ERR-02).
        #expect(watchers.watch(of: workspace.path).map { $0 !== stream && !$0.isStopped } == true)
        await model.refreshChanges(workspaceId: workspace.id)
        #expect(model.changesFailures[workspace.id]?.message.contains("fatal:") == true)
    }

    /// A refused removal (an uncommitted file) puts the workspace back as a normal one, not selected, with git's
    /// message, its folder and its branch.
    @Test func aRefusedRemovalPutsTheWorkspaceBack() async throws {
        let (model, repoId) = try await modelWithRepo()
        let other = try await newWorkspace(model, repoId: repoId)
        let workspace = try await newWorkspace(model, repoId: repoId)
        let repo = URL(fileURLWithPath: try #require(model.repo(id: repoId)).path)
        let worktree = URL(fileURLWithPath: workspace.path)
        try await Task.blocking { try Data("wip\n".utf8).write(to: worktree.appendingPathComponent("wip.txt")) }.value

        await model.removeWorkspace(id: workspace.id)
        #expect(model.workspace(id: workspace.id) != nil)
        #expect(try model.store.workspaces(repoId: repoId).contains { $0.id == workspace.id })
        #expect(model.selectedWorkspaceId == other.id)
        #expect(model.removals.isEmpty)
        #expect(model.status(workspaceId: workspace.id) == .idle)
        #expect(model.removalFailure?.message.contains("contains modified or untracked files") == true)
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("wip.txt").path))
        #expect(try await hasBranch(workspace.branch, in: repo))

        // Once the file is gone, the same Remove works.
        try await Task.blocking { try FileManager.default.removeItem(at: worktree.appendingPathComponent("wip.txt")) }.value
        await model.removeWorkspace(id: workspace.id)
        #expect(model.workspace(id: workspace.id) == nil)
    }

    /// The archive script runs with the workspace on screen: still selected, its Archive tab revealed, the row spinning
    /// with "Running lima's archive script", and the conversation's chat kept, stopped, for its transcript.
    @Test func theArchiveScriptRunsWithTheWorkspaceOnScreen() async throws {
        let (model, repoId) = try await modelWithRepo()
        let workspace = try await newWorkspace(model, repoId: repoId)
        await model.showConversations(workspace: workspace)
        let chat = try #require(model.existingChat(workspaceId: workspace.id))
        try await waitUntil { chat.state == .ready }
        let release = try Fixtures.temporaryDirectory("archive").appendingPathComponent("go")
        model.setScripts(
            repoId: repoId, setup: "", run: "",
            archive: "while [ ! -e '\(release.path)' ]; do sleep 0.05; done", runMode: .concurrent
        )

        let removal = Task { await model.removeWorkspace(id: workspace.id) }
        try await waitUntil { model.existingProcesses(for: workspace.id)?.archive?.state.isRunning == true }
        let archive = try #require(model.existingProcesses(for: workspace.id)?.archive)
        #expect(model.removals[workspace.id] == .archiving)
        #expect(model.status(workspaceId: workspace.id) == .removing("Running \(workspace.name)'s archive script"))
        #expect(model.removalHint(workspaceId: workspace.id) == "Running \(workspace.name)'s archive script")
        #expect(model.selectedWorkspaceId == workspace.id)
        #expect(model.terminalRevealRequests[workspace.id]?.sessionId == archive.id)
        #expect(model.existingChat(workspaceId: workspace.id) === chat)
        #expect(chat.state == .stopped("Stopped"))
        // A second Remove, or the merged pull request's Archive, while it runs does nothing.
        await model.removeWorkspace(id: workspace.id)
        #expect(model.removals[workspace.id] == .archiving)

        try await Task.blocking { try Data().write(to: release) }.value
        await removal.value
        #expect(model.workspace(id: workspace.id) == nil)
        #expect(model.selectedWorkspaceId == nil)
        #expect(model.removals.isEmpty)
        #expect(model.existingChat(workspaceId: workspace.id) == nil)
    }

    /// A quit during a removal waits for it, so no half-removed worktree stays in the store.
    @Test func aQuitWaitsForARemovalUnderWay() async throws {
        let (model, repoId) = try await modelWithRepo()
        let workspace = try await newWorkspace(model, repoId: repoId)
        try await startStubbornRun(model, workspace: workspace)

        let removal = Task { await model.removeWorkspace(id: workspace.id) }
        try await waitUntil { model.removingWorkspaceIds.contains(workspace.id) }
        await model.stopAllProcesses()
        #expect(try model.store.workspaces(repoId: repoId).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        #expect(model.workspace(id: workspace.id) == nil)
        await removal.value
    }
}
