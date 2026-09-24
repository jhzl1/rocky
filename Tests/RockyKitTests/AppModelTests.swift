import Foundation
import Testing
@testable import RockyKit

final class LaunchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var environments: [[String: String]] = []

    func record(_ environment: [String: String]) {
        lock.withLock { environments.append(environment) }
    }

    var last: [String: String]? {
        lock.withLock { environments.last }
    }
}

@MainActor
struct AppModelTests {
    private func makeModel(
        store: RockyStore? = nil,
        capture: @escaping @Sendable () throws -> [String: String] = { GitFixture.environment },
        launches: LaunchBox = LaunchBox(),
        defaults: UserDefaults? = nil
    ) throws -> AppModel {
        let root = try Fixtures.temporaryDirectory("app")
        let paths = RockyPaths(database: root.appendingPathComponent("rocky.sqlite"), adapterPrefix: root.appendingPathComponent("agents"), logs: root)
        return AppModel(
            store: try store ?? RockyStore.inMemory(),
            paths: paths,
            captureEnvironment: capture,
            makeLaunch: { _, cwd, environment, _ in
                launches.record(environment)
                let fake = Fixtures.fakeACPLaunch()
                return AgentLaunch(executable: fake.executable, arguments: fake.arguments, environment: fake.environment, cwd: cwd, stderrLog: fake.stderrLog)
            },
            installAdapter: { _, _, _, _ in },
            latestVersion: { _ in "0.0.0" },
            defaults: defaults ?? UserDefaults(suiteName: "rocky-tests-\(UUID().uuidString)")!
        )
    }

    private func answerNextPermission(_ chat: ChatSessionModel) async throws {
        for _ in 0..<500 where chat.pendingPermission == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.answerPermission(optionId: "allow")
    }

    @Test func addRepoAcceptsOnlyRepositoryRootsOnce() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let parent = try Fixtures.temporaryDirectory("repos")
        let repo = try GitFixture.localRepo(in: parent)

        await model.addRepo(at: parent)
        #expect(model.repos.isEmpty)
        #expect(model.errorMessage?.contains("not the root of a git repository") == true)

        await model.addRepo(at: repo)
        #expect(model.repos.map(\.name) == ["app"])

        await model.addRepo(at: repo)
        #expect(model.errorMessage == "app is already in Rocky.")
        #expect(model.repos.count == 1)
    }

    @Test func createsSelectsAndRemovesAWorkspace() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)

        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        #expect(model.selectedWorkspaceId == workspace.id)
        #expect(workspace.branch == "rocky/\(workspace.name)")
        #expect(workspace.path.hasPrefix(WorktreeService.worktreesRoot(for: repo).path))
        #expect(FileManager.default.fileExists(atPath: workspace.path))

        await model.removeWorkspace(id: workspace.id)
        #expect(model.workspaces[repoId]?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        #expect(model.selectedWorkspaceId == nil)
    }

    @Test func chatUsesTheRepoClaudeInstancePersistsAndResumes() async throws {
        let store = try RockyStore.inMemory()
        let launches = LaunchBox()
        let model = try makeModel(store: store, launches: launches)
        await model.bootstrap()
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.setClaudeConfigDir(repoId: repoId, "/Users/me/.claude-celes")
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)

        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))
        #expect(launches.last?["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-celes")
        #expect(chat.state == .ready)
        async let sending: Void = chat.send("hi")
        try await answerNextPermission(chat)
        await sending
        await model.stopAllAgents()
        #expect(chat.state == .stopped("Stopped"))

        let reopened = try makeModel(store: store, launches: launches)
        await reopened.bootstrap()
        let resumed = try #require(await reopened.openChat(workspace: workspace, agent: .claude))
        #expect(resumed.sessionId == "fake-1")
        #expect(resumed.items.map(\.text) == ["hi", "Hello", "Run printenv"])
        #expect(resumed.items.last?.status == "completed")
        #expect(resumed.items.first?.completedAt != nil)
        await reopened.stopAllAgents()
    }

    @Test func changingTheClaudeInstanceStopsTheRunningClaudeChat() async throws {
        let launches = LaunchBox()
        let model = try makeModel(launches: launches)
        await model.bootstrap()
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))
        #expect(launches.last?["CLAUDE_CONFIG_DIR"] == nil)

        await model.setClaudeConfigDir(repoId: repoId, "/Users/me/.claude-rentek")
        #expect(chat.state == .stopped("Stopped"))
        #expect(model.existingChat(workspaceId: workspace.id) == nil)

        let restarted = try #require(await model.openChat(workspace: workspace, agent: .claude))
        #expect(restarted !== chat)
        #expect(launches.last?["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-rentek")
        await model.stopAllAgents()
    }

    /// A workspace with one Claude conversation that already has a turn ("hi").
    private func workspaceWithAConversation(store: RockyStore) async throws -> (AppModel, Workspace, ChatSessionModel) {
        let model = try makeModel(store: store)
        await model.bootstrap()
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))
        async let sending: Void = chat.send("hi")
        try await answerNextPermission(chat)
        await sending
        return (model, workspace, chat)
    }

    /// ROW-04: a turn that ends in a workspace you are not looking at marks it unread; selecting it clears it.
    @Test func turnEndingInAnotherWorkspaceMarksItUnread() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))
        model.selectedWorkspaceId = nil

        async let sending: Void = chat.send("hi")
        try await answerNextPermission(chat)
        await sending
        #expect(model.unreadWorkspaceIds == [workspace.id])
        #expect(model.status(workspaceId: workspace.id) == .unread)

        model.selectedWorkspaceId = workspace.id
        #expect(model.unreadWorkspaceIds.isEmpty)
        #expect(model.status(workspaceId: workspace.id) == .idle)
        await model.stopAllAgents()
    }

    /// The last session opens again: the workspace that was on screen, showing the conversation it showed.
    @Test func reopensTheLastWorkspaceAndConversation() async throws {
        let store = try RockyStore.inMemory()
        let defaults = try #require(UserDefaults(suiteName: "rocky-tests-\(UUID().uuidString)"))
        let model = try makeModel(store: store, defaults: defaults)
        await model.bootstrap()
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        await model.showConversations(workspace: workspace)
        let first = try #require(model.selectedConversationIds[workspace.id])
        _ = await model.newConversation(workspace: workspace, agent: .claude)
        await model.showConversation(workspace: workspace, conversationId: first)
        await model.stopAllAgents()

        let reopened = try makeModel(store: store, defaults: defaults)
        await reopened.bootstrap()
        #expect(reopened.selectedWorkspaceId == workspace.id)
        await reopened.showConversations(workspace: workspace)
        #expect(reopened.selectedConversationIds[workspace.id] == first)
        await reopened.stopAllAgents()
    }

    @Test func turnEndingInTheSelectedWorkspaceMarksNothing() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, _) = try await workspaceWithAConversation(store: store)
        #expect(model.selectedWorkspaceId == workspace.id)
        #expect(model.unreadWorkspaceIds.isEmpty)
        await model.stopAllAgents()
    }

    /// ROW-04: with Rocky in the background, even the selected workspace is not being watched.
    @Test func turnEndingWhileRockyIsInTheBackgroundMarksTheSelectedWorkspaceUnread() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, chat) = try await workspaceWithAConversation(store: store)
        model.isWindowActive = false
        async let sending: Void = chat.send("again")
        try await answerNextPermission(chat)
        await sending
        #expect(model.unreadWorkspaceIds == [workspace.id])
        #expect(model.attentionCount == 1)

        model.isWindowActive = true
        #expect(model.unreadWorkspaceIds.isEmpty)
        #expect(model.attentionCount == 0)
        await model.stopAllAgents()
    }

    /// The alert sound plays only for what the user is not watching (user decision, 2026-09-23).
    @Test func alertsOnlyForAWorkspaceTheUserIsNotWatching() async throws {
        let store = try RockyStore.inMemory()
        let (model, _, chat) = try await workspaceWithAConversation(store: store)
        var alerts: [ChatAttention] = []
        model.onAlert = { alerts.append($0) }

        async let watched: Void = chat.send("watched")
        try await answerNextPermission(chat)
        await watched
        #expect(alerts.isEmpty)

        model.selectedWorkspaceId = nil
        async let unwatched: Void = chat.send("unwatched")
        try await answerNextPermission(chat)
        await unwatched
        #expect(alerts == [.needsYou, .finished])
        await model.stopAllAgents()
    }

    /// ROW-02: the task title of the oldest open titled conversation, else the workspace name, dimmer.
    @Test func titleFallsBackToTheWorkspaceName() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        #expect(model.title(for: workspace) == (workspace.name, true))

        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))
        async let sending: Void = chat.send("Fix invoice rounding")
        try await answerNextPermission(chat)
        await sending
        #expect(model.title(for: workspace) == ("Fix invoice rounding", false))
        await model.stopAllAgents()
    }

    @Test func reopeningShowsTheLastConversationTitledByItsFirstMessage() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, _) = try await workspaceWithAConversation(store: store)
        await model.stopAllAgents()

        let reopened = try makeModel(store: store)
        await reopened.bootstrap()
        await reopened.showConversations(workspace: workspace)
        #expect(reopened.conversations[workspace.id]?.map(\.title) == ["hi"])
        let chat = try #require(reopened.existingChat(workspaceId: workspace.id))
        #expect(chat.agent == .claude)
        #expect(chat.items.map(\.text) == ["hi", "Hello", "Run printenv"])
        await reopened.stopAllAgents()
    }

    @Test func aFileOpensInATabAndAConversationTabCoversItAgain() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, chat) = try await workspaceWithAConversation(store: store)
        let conversationId = try #require(model.selectedConversationIds[workspace.id])

        model.openFile(workspaceId: workspace.id, path: "/repo/a.png")
        model.openFile(workspaceId: workspace.id, path: "/repo/b.md")
        model.openFile(workspaceId: workspace.id, path: "/repo/a.png")
        #expect(model.openFiles[workspace.id] == ["/repo/a.png", "/repo/b.md"])
        #expect(model.selectedFiles[workspace.id] == "/repo/a.png")

        await model.showConversation(workspace: workspace, conversationId: conversationId)
        #expect(model.selectedFiles[workspace.id] == nil)
        #expect(model.existingChat(workspaceId: workspace.id) === chat)

        model.showFile(workspaceId: workspace.id, path: "/repo/b.md")
        model.closeFile(workspaceId: workspace.id, path: "/repo/b.md")
        #expect(model.openFiles[workspace.id] == ["/repo/a.png"])
        #expect(model.selectedFiles[workspace.id] == nil)
        await model.stopAllAgents()
    }

    @Test func newConversationOpensATabAndLeavesTheOtherRunning() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, first) = try await workspaceWithAConversation(store: store)

        let fresh = try #require(await model.newConversation(workspace: workspace, agent: .opencode))
        #expect(fresh.items.isEmpty)
        #expect(model.existingChat(workspaceId: workspace.id) === fresh)
        #expect(first.state == .ready)
        let tabs = try #require(model.conversations[workspace.id])
        #expect(tabs.map(\.agent) == ["claude", "opencode"])

        await model.showConversation(workspace: workspace, conversationId: tabs[0].id)
        #expect(model.existingChat(workspaceId: workspace.id) === first)
        await model.stopAllAgents()
    }

    @Test func closingATabStopsItsAgentAndKeepsTheConversation() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, first) = try await workspaceWithAConversation(store: store)
        let firstId = try #require(model.selectedConversationIds[workspace.id])
        await model.newConversation(workspace: workspace, agent: .claude)

        await model.closeConversation(workspace: workspace, conversationId: firstId)
        #expect(first.state == .stopped("Stopped"))
        #expect(model.conversations[workspace.id]?.map(\.id).contains(firstId) == false)
        #expect(try store.session(id: firstId)?.closedAt != nil)
        #expect(try store.messages(sessionId: firstId).map(\.text) == ["hi", "Hello", "Run printenv"])
        await model.stopAllAgents()
    }

    @Test func repoWithoutClaudeInstanceNeverInheritsOne() async throws {
        let launches = LaunchBox()
        let model = try makeModel(capture: {
            GitFixture.environment.merging(["CLAUDE_CONFIG_DIR": "/Users/me/.claude-celes"]) { _, new in new }
        }, launches: launches)
        await model.bootstrap()
        let repo = try GitFixture.localRepo(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)

        _ = await model.openChat(workspace: workspace, agent: .opencode)
        #expect(launches.last?["CLAUDE_CONFIG_DIR"] == nil)
        await model.stopAllAgents()
    }

    @Test func environmentCaptureFailureFallsBackAndReports() async throws {
        struct Boom: Error {}
        let model = try makeModel(capture: { throw Boom() })
        await model.bootstrap()
        #expect(model.loginEnvironment["PATH"] != nil)
        #expect(model.errorMessage?.hasPrefix("Could not read your login shell environment") == true)
    }
}
