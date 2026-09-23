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
        launches: LaunchBox = LaunchBox()
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
            installAdapter: { _, _ in }
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
