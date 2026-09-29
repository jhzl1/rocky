import Foundation
import Testing
@testable import RockyKit

/// WSC-01…WSC-06, KIT-18: a workspace on screen before git has made its worktree, one at a time in any repository, its
/// post-checkout hook run by Setup, and what a failed or removed creation leaves. Temporary repositories only; a slow
/// fetch is a fake ssh that sleeps.
@MainActor
struct WorkspaceCreationTests {
    private func makeModel(launches: LaunchBox = LaunchBox()) throws -> AppModel {
        let root = try Fixtures.temporaryDirectory("app")
        let paths = RockyPaths(database: root.appendingPathComponent("rocky.sqlite"), adapterPrefix: root.appendingPathComponent("agents"), logs: root)
        return AppModel(
            store: try RockyStore.inMemory(),
            paths: paths,
            // No ssh command of this machine's: the fetch goes through the repository's own.
            captureEnvironment: { GitFixture.environment.filter { $0.key != "GIT_SSH_COMMAND" } },
            makeLaunch: { kind, cwd, environment, _ in
                launches.record(environment)
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
            githubSession: OfflineURLProtocol.session()
        )
    }

    private func addRepo(_ model: AppModel, _ repo: URL) async throws -> String {
        await model.addRepo(at: repo)
        return try #require(model.repos.first { $0.path == repo.path }?.id)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func answerNextPermission(_ chat: ChatSessionModel) async throws {
        try await waitUntil { chat.pendingPermission != nil }
        chat.answerPermission(optionId: "allow")
    }

    /// A clone whose origin answers through a fake ssh that waits `seconds`, then fails, as a host without access
    /// would: the fetch takes that long and fails.
    private func slowOrigin(seconds: Double) async throws -> URL {
        let parent = try Fixtures.temporaryDirectory("git")
        let repo = try await GitFixture.clonedRepoOffMain(in: parent)
        let ssh = parent.appendingPathComponent("slow-ssh")
        try Data("#!/bin/sh\nsleep \(seconds)\nexit 255\n".utf8).write(to: ssh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        try await GitFixture.gitOffMain(["remote", "set-url", "origin", "ssh://git@example.invalid/jhzl1/app.git"], in: repo)
        try await GitFixture.gitOffMain(["config", "core.sshCommand", ssh.path], in: repo)
        return repo
    }

    /// A repository whose committed `.husky/post-checkout` (through `core.hooksPath`) runs `body`.
    private func repoWithHook(_ body: String, name: String = "app") async throws -> URL {
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"), name: name)
        let husky = repo.appendingPathComponent(".husky", isDirectory: true)
        try FileManager.default.createDirectory(at: husky, withIntermediateDirectories: true)
        try WorktreeServiceTests.writeHook(body, to: husky.appendingPathComponent("post-checkout"))
        try await GitFixture.gitOffMain(["add", ".husky"], in: repo)
        try await GitFixture.gitOffMain(["commit", "-q", "-m", "hooks"], in: repo)
        try await GitFixture.gitOffMain(["config", "core.hooksPath", ".husky"], in: repo)
        return repo
    }

    private func hasBranch(_ branch: String, in repo: URL) async throws -> Bool {
        try await !GitFixture.gitOffMain(["branch", "--list", branch], in: repo).isEmpty
    }

    /// WSC-01, WSC-03, WSC-04: the row, its view and its conversation come at once, in memory, before git has made
    /// anything; a message sent meanwhile waits, shown, and goes once the agent is ready. Once the worktree exists the
    /// workspace is saved with its port, its base and its conversation, and a failed fetch is a toast.
    @Test func aWorkspaceShowsAtOnceAndIsSavedOnceItsWorktreeExists() async throws {
        let model = try makeModel()
        await model.bootstrap()
        var toasts: [String] = []
        model.onToast = { toasts.append($0) }
        let repoId = try await addRepo(model, try await slowOrigin(seconds: 1))

        let creating = Task { await model.createWorkspace(repoId: repoId) }
        try await waitUntil { model.selectedWorkspace != nil }
        let workspace = try #require(model.selectedWorkspace)
        #expect(model.creations[workspace.id] == .creating)
        #expect(model.preparingWorkspaceId == workspace.id)
        #expect(model.preparingRepoId == repoId)
        #expect(workspace.branch == "rocky/\(workspace.name)")
        #expect(model.status(workspaceId: workspace.id) == .creating("Creating \(workspace.name): fetching origin and checking out \(workspace.branch)"))
        #expect(model.newWorkspaceWait == "Wait for \(workspace.name) to be created")
        #expect(model.creatingHint(workspaceId: workspace.id) == "Creating \(workspace.name)…")
        #expect(model.pullRequestHeader(workspaceId: workspace.id).label == "No pull request")
        // No action on it while it is created (user decision, 2026-09-28): Create PR and the other agent actions wait.
        #expect(model.agentActionAvailability(workspaceId: workspace.id) == .creating("Creating \(workspace.name)…"))
        #expect(model.agentActionAvailability(workspaceId: workspace.id).reason == "Creating \(workspace.name)…")
        #expect(try model.store.workspaces(repoId: repoId).isEmpty)
        #expect(model.conversations[workspace.id]?.map(\.agent) == ["claude"])
        let conversationId = try #require(model.selectedConversationIds[workspace.id])
        #expect(try model.store.session(id: conversationId) == nil)
        // AGM-02 meanwhile: the conversation, in memory only, switches its agent there.
        let first = try #require(model.existingChat(workspaceId: workspace.id))
        #expect(await model.pickModel(conversationId: conversationId, agent: .opencode, model: nil) == .switchedInPlace)
        #expect(first.state == .stopped("Stopped"))
        #expect(model.conversations[workspace.id]?.map(\.agent) == ["opencode"])
        let chat = try #require(model.existingChat(workspaceId: workspace.id))
        #expect(chat.agent == .opencode)
        #expect(chat.isWaitingForWorkspace)
        chat.enqueue("hi")
        await model.showConversations(workspace: workspace)
        #expect(await model.newConversation(workspace: workspace) == nil)
        #expect(await model.openTerminal(workspaceId: workspace.id) == nil)

        await creating.value
        #expect(model.creations[workspace.id] == nil)
        #expect(model.agentActionAvailability(workspaceId: workspace.id) != .creating("Creating \(workspace.name)…"))
        let saved = try #require(try model.store.workspaces(repoId: repoId).first)
        #expect(saved.id == workspace.id)
        #expect(saved.port == 41000)
        #expect(saved.baseRef == "origin/trunk")
        #expect(try model.store.session(id: conversationId)?.workspaceId == workspace.id)
        #expect(try model.store.session(id: conversationId)?.agent == "opencode")
        #expect(toasts == ["git fetch failed; \(workspace.name) was created from the last fetched origin/trunk."])
        // No hook and no Setup script: the next workspace can be made at once.
        #expect(model.preparingWorkspaceId == nil)

        try await answerNextPermission(chat)
        try await waitUntil { chat.state == .ready && chat.queue.isEmpty }
        #expect(chat.items.filter { $0.kind == .user }.map(\.text) == ["hi"])
        await model.stopAllProcesses()
    }

    /// WSC-01 (user decision, 2026-09-28): while any workspace is being created or set up, in any repository, another
    /// cannot be made: a double click makes one row, and a second repository waits until the first one's Setup ends,
    /// or is stopped.
    @Test func oneWorkspaceIsMadeAtATimeInAnyRepository() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let releases = try Fixtures.temporaryDirectory("releases")
        let waiting = try await repoWithHook(#"while [ ! -e '\#(releases.path)'/"$(basename "$PWD")" ]; do sleep 0.05; done"#, name: "waiting")
        let plain = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"), name: "plain")
        let waitingId = try await addRepo(model, waiting)
        let plainId = try await addRepo(model, plain)

        // A double click: the second call comes before the first one's first await is over.
        let first = Task { await model.createWorkspace(repoId: waitingId) }
        let second = Task { await model.createWorkspace(repoId: waitingId) }
        await first.value
        await second.value
        let made = try #require(model.workspaces[waitingId])
        try #require(made.count == 1)
        let workspace = made[0]
        let setup = try #require(model.existingProcesses(for: workspace.id)?.setup)
        #expect(setup.state.isRunning)
        #expect(model.preparingWorkspaceId == workspace.id)
        #expect(model.newWorkspaceWait == "Wait for \(workspace.name) to finish setting up")
        #expect(model.status(workspaceId: workspace.id) == .settingUp("Setting up \(workspace.name): the post-checkout hook"))

        await model.createWorkspace(repoId: plainId)
        #expect(model.workspaces[plainId]?.isEmpty == true)

        // The hook ends: the guard goes with it.
        try Data().write(to: releases.appendingPathComponent(workspace.name))
        #expect(await setup.waitForExit() == .exited(0))
        try await waitUntil { model.preparingWorkspaceId == nil }
        #expect(model.status(workspaceId: workspace.id) == .idle)
        await model.createWorkspace(repoId: plainId)
        #expect(model.workspaces[plainId]?.count == 1)
        #expect(model.preparingWorkspaceId == nil)

        // A Setup that hangs is stopped from its tab, which lets the next one through.
        await model.createWorkspace(repoId: waitingId)
        let hanging = try #require(model.workspaces[waitingId]?.first { $0.id != workspace.id })
        #expect(model.preparingWorkspaceId == hanging.id)
        await model.createWorkspace(repoId: plainId)
        #expect(model.workspaces[plainId]?.count == 1)
        await model.closeSetup(workspaceId: hanging.id)
        #expect(model.existingProcesses(for: hanging.id)?.setup == nil)
        #expect(model.preparingWorkspaceId == nil)
        await model.createWorkspace(repoId: plainId)
        #expect(model.workspaces[plainId]?.count == 2)
        await model.stopAllProcesses()
    }

    /// WSC-05: Setup runs the repository's post-checkout hook, with git's arguments for a new worktree and in it, then
    /// the Setup script, in one tab, each step opening with its line.
    @Test func theSetupTabRunsTheHookThenTheScript() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let repo = try await repoWithHook(#"echo "$@" > hook-args.txt"#)
        let repoId = try await addRepo(model, repo)
        model.setScripts(repoId: repoId, setup: "test -f hook-args.txt && touch after-hook", run: "", archive: "", runMode: .concurrent)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        let setup = try #require(model.existingProcesses(for: workspace.id)?.setup)

        #expect(await setup.waitForExit() == .exited(0))
        let head = try await GitFixture.gitOffMain(["rev-parse", "HEAD"], in: URL(fileURLWithPath: workspace.path))
        let arguments = try String(contentsOfFile: workspace.path + "/hook-args.txt", encoding: .utf8)
        #expect(arguments == "\(SetupSteps.nullCommit) \(head) 1\n")
        #expect(FileManager.default.fileExists(atPath: workspace.path + "/after-hook"))
        let output = TaskOutputWatcher.stripANSI(setup.outputText)
        let hookLine = try #require(output.range(of: "▸ post-checkout hook · .husky/post-checkout"))
        let endLine = try #require(output.range(of: "post-checkout exited with code 0"))
        let scriptLine = try #require(output.range(of: "▸ Setup · test -f hook-args.txt && touch after-hook"))
        #expect(hookLine.upperBound <= endLine.lowerBound && endLine.upperBound <= scriptLine.lowerBound)
        try await waitUntil { model.preparingWorkspaceId == nil && model.setupSteps[workspace.id] == nil }
        // The terminal reveal of Decision 12 selects and unfolds the Setup tab.
        #expect(model.terminalRevealRequests[workspace.id]?.sessionId == setup.id)
    }

    /// WSC-05: a failing hook stops the Setup script, the row shows ROW-03's Setup failure, and the guard goes.
    @Test func aFailingHookStopsTheScript() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let repoId = try await addRepo(model, try await repoWithHook("exit 4"))
        model.setScripts(repoId: repoId, setup: "touch after-hook", run: "", archive: "", runMode: .concurrent)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        let setup = try #require(model.existingProcesses(for: workspace.id)?.setup)

        #expect(await setup.waitForExit() == .exited(4))
        #expect(!FileManager.default.fileExists(atPath: workspace.path + "/after-hook"))
        #expect(model.status(workspaceId: workspace.id) == .failed("Setup exited with 4. See the Setup tab."))
        try await waitUntil { model.preparingWorkspaceId == nil }
    }

    /// WSC-06: git's failure keeps the workspace in memory as failed, with git's message, and nothing stored; Retry
    /// cleans up what the attempt left and reuses the branch it made, and saves the same workspace.
    @Test func aFailedCreationShowsGitsMessageAndRetryReusesTheBranch() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
        let repoId = try await addRepo(model, repo)
        let root = WorktreeService.worktreesRoot(for: repo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        guard case .failed(let message)? = model.creations[workspace.id] else {
            Issue.record("The creation did not fail")
            return
        }
        #expect(message.contains("Permission denied"))
        #expect(model.status(workspaceId: workspace.id) == .creationFailed(WorkspaceStatus.creationFailedText(name: workspace.name, message: message)))
        #expect(model.preparingWorkspaceId == nil)
        #expect(model.selectedWorkspaceId == workspace.id)
        #expect(try model.store.workspaces(repoId: repoId).isEmpty)
        #expect(try await hasBranch(workspace.branch, in: repo))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        await model.retryCreation(workspaceId: workspace.id)
        #expect(model.creations[workspace.id] == nil)
        #expect(try model.store.workspaces(repoId: repoId).map(\.id) == [workspace.id])
        #expect(try await GitFixture.gitOffMain(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: workspace.path)) == workspace.branch)
        #expect(model.conversations[workspace.id]?.count == 1)
        await model.stopAllProcesses()
    }

    /// WSC-06's Remove of a failed creation, and WSC-02's while it is created: the row goes at once, git stops, and
    /// the half-made folder and the empty branch go. A quit meanwhile does the same (WSC-03).
    @Test func removeAndQuitCleanUpWhatACreationMade() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
        let repoId = try await addRepo(model, repo)
        let root = WorktreeService.worktreesRoot(for: repo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        await model.createWorkspace(repoId: repoId)
        let failed = try #require(model.workspaces[repoId]?.first)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        await model.removeFailedCreation(workspaceId: failed.id)
        #expect(model.workspaces[repoId]?.isEmpty == true)
        #expect(model.creations.isEmpty)
        #expect(model.selectedWorkspaceId == nil)
        #expect(!(try await hasBranch(failed.branch, in: repo)))

        // While git fetches: Remove stops it long before the fetch would have ended.
        let slow = try await slowOrigin(seconds: 20)
        let slowId = try await addRepo(model, slow)
        let started = Date()
        let creating = Task { await model.createWorkspace(repoId: slowId) }
        try await waitUntil { model.workspaces[slowId]?.isEmpty == false }
        let removed = try #require(model.workspaces[slowId]?.first)
        await model.removeFailedCreation(workspaceId: removed.id)
        await creating.value
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(model.workspaces[slowId]?.isEmpty == true)
        #expect(model.preparingWorkspaceId == nil)
        #expect(try model.store.workspaces(repoId: slowId).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        #expect(!(try await hasBranch(removed.branch, in: slow)))

        // A quit while one is created.
        let quitting = Task { await model.createWorkspace(repoId: slowId) }
        try await waitUntil { model.workspaces[slowId]?.isEmpty == false }
        let quit = try #require(model.workspaces[slowId]?.first)
        await model.stopAllProcesses()
        await quitting.value
        #expect(model.workspaces[slowId]?.isEmpty == true)
        #expect(try model.store.workspaces(repoId: slowId).isEmpty)
        #expect(!(try await hasBranch(quit.branch, in: slow)))
    }
}

