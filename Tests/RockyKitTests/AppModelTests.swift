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

/// A fake `git remote get-url origin`: each clone's GitHub repository by folder name, and the lookups made.
final class FakeRemotes: @unchecked Sendable {
    private let lock = NSLock()
    private let repositories: [String: GitHubRepository]
    private var looked: [String] = []

    init(_ repositories: [String: GitHubRepository] = [:]) {
        self.repositories = repositories
    }

    var lookups: [String] {
        lock.withLock { looked }
    }

    func lookUp(_ clone: URL, _ environment: [String: String]) -> GitHubRepository? {
        lock.withLock { looked.append(clone.lastPathComponent) }
        return repositories[clone.lastPathComponent]
    }
}

/// A flag one thread sets and the test reads.
final class SharedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}

/// A GitHub stub that suites running in parallel can share, unlike `StubURLProtocol`'s one global handler: each test
/// registers a route under a fresh token (a `FakeGH` login's), and a request goes to the route of the token in its
/// Authorization header, which every request Rocky sends to api.github.com carries. A request without a known token
/// fails as offline.
final class RoutedGitHubProtocol: URLProtocol {
    final class Route: @unchecked Sendable {
        /// The token whose requests this route answers: a relaunched model's `FakeGH` gives it again.
        let token: String
        private let lock = NSLock()
        private let reply: @Sendable (StubURLProtocol.Sent) -> StubURLProtocol.Reply
        private var sent: [StubURLProtocol.Sent] = []

        init(token: String, reply: @escaping @Sendable (StubURLProtocol.Sent) -> StubURLProtocol.Reply) {
            self.token = token
            self.reply = reply
        }

        /// Every request answered, in order.
        var requests: [StubURLProtocol.Sent] {
            lock.withLock { sent }
        }

        func answer(_ request: StubURLProtocol.Sent) -> StubURLProtocol.Reply {
            lock.withLock { sent.append(request) }
            return reply(request)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]

    /// A new token and the route that answers its requests.
    static func route(_ reply: @escaping @Sendable (StubURLProtocol.Sent) -> StubURLProtocol.Reply) -> (token: String, route: Route) {
        let token = "gho_test" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let route = Route(token: token, reply: reply)
        lock.withLock { routes[token] = route }
        return (token, route)
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutedGitHubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
        guard let token, let route = Self.lock.withLock({ Self.routes[token] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let reply = route.answer(StubURLProtocol.Sent(request: request, body: body))
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// GitHub's answers for the pull request tests of `AppModelTests`.
enum GitHubStubs {
    /// `PR-01`'s answer: the branch's pull request #4525 of jhzl1/app against `main` (open unless `state` says
    /// MERGED), with these `statusCheckRollup` nodes.
    static func snapshot(
        state: String = "OPEN",
        isDraft: Bool = false,
        checks: [String] = []
    ) -> Data {
        Data("""
            {"data":{"repository":{"id":"R_1","squashMergeAllowed":true,"rebaseMergeAllowed":true,"mergeCommitAllowed":true,
            "viewerDefaultMergeMethod":"SQUASH","defaultBranchRef":{"name":"main"},
            "pullRequests":{"nodes":[{"id":"PR_1","number":4525,"url":"https://github.com/jhzl1/app/pull/4525",
            "title":"Retry uploads","body":"With backoff.","isDraft":\(isDraft),"state":"\(state)","mergedAt":null,"baseRefName":"main",
            "headRefName":"rocky/tokyo","headRefOid":"","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED",
            "reviewDecision":"REVIEW_REQUIRED","canBeRebased":true,"reviewRequests":{"totalCount":0},"autoMergeRequest":null,
            "mergeQueueEntry":null,"commits":{"nodes":[{"commit":{
            "statusCheckRollup":{"contexts":{"nodes":[\(checks.joined(separator: ","))]}},
            "deployments":{"nodes":[]}}}]}}]},
            "ref":{"compare":{"aheadBy":1,"behindBy":0}}}}}
            """.utf8)
    }

    /// A GitHub Actions check run: job `job` of workflow run `run`. `started` false is a job that never started.
    static func checkRun(_ name: String, conclusion: String, job: Int, run: Int, started: Bool = true) -> String {
        let startedAt = started ? #""2026-09-23T10:00:00Z""# : "null"
        return #"{"__typename":"CheckRun","name":"\#(name)","status":"COMPLETED","conclusion":"\#(conclusion)","startedAt":\#(startedAt),"completedAt":"2026-09-23T10:07:00Z","detailsUrl":"https://github.com/jhzl1/app/actions/runs/\#(run)/job/\#(job)","databaseId":\#(job),"checkSuite":{"workflowRun":{"databaseId":\#(run)}}}"#
    }

    /// Another CI system's status.
    static func statusContext(_ name: String, state: String, url: String) -> String {
        #"{"__typename":"StatusContext","context":"\#(name)","state":"\#(state)","targetUrl":"\#(url)"}"#
    }
}

@MainActor
struct AppModelTests {
    /// Tests never run the real `gh`: by default it has no account and no repository is on GitHub.
    private func makeModel(
        store: RockyStore? = nil,
        capture: @escaping @Sendable () throws -> [String: String] = { GitFixture.environment },
        launches: LaunchBox = LaunchBox(),
        defaults: UserDefaults? = nil,
        gh: FakeGH = FakeGH(status: #"{"hosts":{}}"#),
        remotes: FakeRemotes = FakeRemotes(),
        githubSession: URLSession = OfflineURLProtocol.session()
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
            defaults: defaults ?? UserDefaults(suiteName: "rocky-tests-\(UUID().uuidString)")!,
            runGH: { arguments, environment in try gh.run(arguments, environment: environment) },
            lookUpGitHubRepository: { clone, environment in remotes.lookUp(clone, environment) },
            githubSession: githubSession
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
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
        let repo = try await GitFixture.localRepoOffMain(in: parent)

        await model.addRepo(at: parent)
        #expect(model.repos.isEmpty)
        #expect(model.errorMessage?.contains("not the root of a git repository") == true)

        await model.addRepo(at: repo)
        #expect(model.repos.map(\.name) == ["app"])

        await model.addRepo(at: repo)
        #expect(model.errorMessage == "app is already in Rocky.")
        #expect(model.repos.count == 1)
    }

    @Test func repositoriesGetDifferentColors() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let parent = try Fixtures.temporaryDirectory("repos")
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: parent, name: "one"))
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: parent, name: "two"))
        let colors = model.repos.compactMap(\.colorIndex)
        #expect(colors.count == 2)
        #expect(Set(colors).count == 2)
    }

    @Test func repositoriesFromBeforeColorsGetOneEachOnLaunch() async throws {
        let store = try RockyStore.inMemory()
        try store.add(Repo(name: "one", path: "/tmp/rocky-colors-one"))
        try store.add(Repo(name: "two", path: "/tmp/rocky-colors-two"))
        let model = try makeModel(store: store)
        await model.bootstrap()
        let colors = model.repos.compactMap(\.colorIndex)
        #expect(colors.count == 2)
        #expect(Set(colors).count == 2)
        #expect(try store.repos().allSatisfy { $0.colorIndex != nil })
    }

    @Test func createsSelectsAndRemovesAWorkspace() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
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
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
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
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))
        #expect(launches.last?["CLAUDE_CONFIG_DIR"] == nil)

        await model.setClaudeConfigDir(repoId: repoId, "/Users/me/.claude-rentek")
        #expect(chat.state == .stopped("Stopped"))
        // The conversation on screen reopens at once, with the new instance.
        let reopened = try #require(model.existingChat(workspaceId: workspace.id))
        #expect(reopened !== chat)
        #expect(launches.last?["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-rentek")
        await model.stopAllAgents()
    }

    @Test func changingTheClaudeInstanceLeavesAWorkspaceOffScreenToReopenWhenSelected() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        _ = try #require(await model.openChat(workspace: workspace, agent: .claude))
        model.selectedWorkspaceId = nil

        await model.setClaudeConfigDir(repoId: repoId, "/Users/me/.claude-rentek")
        #expect(model.existingChat(workspaceId: workspace.id) == nil)
        await model.stopAllAgents()
    }

    /// A workspace with one Claude conversation that already has a turn ("hi").
    private func workspaceWithAConversation(store: RockyStore) async throws -> (AppModel, Workspace, ChatSessionModel) {
        let model = try makeModel(store: store)
        await model.bootstrap()
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
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
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
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
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
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
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
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

    private func waitForCommands(_ chat: ChatSessionModel) async throws {
        for _ in 0..<500 where !chat.commandsReceived {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(chat.commandsReceived)
    }

    /// A workspace with an empty repository, and the model it lives in.
    private func emptyWorkspace(store: RockyStore) async throws -> (AppModel, Workspace) {
        let model = try makeModel(store: store)
        await model.bootstrap()
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        return (model, try #require(model.workspaces[repoId]?.first))
    }

    private static let announced = ["compact", "review", "mcp:linear:triage"]
    /// What a Claude Code conversation's popup offers with the fake agent's list: CMD-08 adds the terminal commands.
    private static let offered = announced + TerminalOnlyCommand.names

    /// KIT-01, CMD-05: the last list of the repository and agent, not confirmed, then the conversation's own.
    @Test func newConversationShowsTheLastListUntilItsOwnArrives() async throws {
        let (model, workspace) = try await emptyWorkspace(store: try RockyStore.inMemory())
        let first = try #require(await model.newConversation(workspace: workspace, agent: .claude))
        #expect(model.commands(for: first).commands.isEmpty)
        #expect(!model.commands(for: first).confirmed)
        try await waitForCommands(first)
        #expect(model.commands(for: first).commands.map(\.name) == Self.offered)
        #expect(model.commands(for: first).confirmed)
        // The first conversation's list changes, so the cache and the second conversation's own list differ.
        await first.send("change commands")

        let second = try #require(await model.newConversation(workspace: workspace, agent: .claude))
        #expect(model.commands(for: second).commands.map(\.name) == ["init"] + TerminalOnlyCommand.names)
        #expect(!model.commands(for: second).confirmed)
        try await waitForCommands(second)
        #expect(model.commands(for: second).commands.map(\.name) == Self.offered)
        #expect(model.commands(for: second).confirmed)
        await model.stopAllAgents()
    }

    @Test func listsAreKeptPerAgent() async throws {
        let (model, workspace) = try await emptyWorkspace(store: try RockyStore.inMemory())
        let claude = try #require(await model.newConversation(workspace: workspace, agent: .claude))
        try await waitForCommands(claude)
        await claude.send("change commands")

        // Claude's list is not OpenCode's, which gets no terminal commands (CMD-08).
        let opencode = try #require(await model.newConversation(workspace: workspace, agent: .opencode))
        #expect(model.commands(for: opencode).commands.isEmpty)
        try await waitForCommands(opencode)
        #expect(model.commands(for: opencode).commands.map(\.name) == Self.announced)

        let anotherClaude = try #require(await model.newConversation(workspace: workspace, agent: .claude))
        #expect(model.commands(for: anotherClaude).commands.map(\.name) == ["init"] + TerminalOnlyCommand.names)
        #expect(!model.commands(for: anotherClaude).confirmed)
        await model.stopAllAgents()
    }

    /// Review Focus 5 (TITLE-01): "/compact" leaves the tab untitled, also when Rocky reopens the conversation before
    /// its agent has said which commands it has; the first normal message names it.
    @Test func firstNonCommandMessageNamesTheConversation() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace) = try await emptyWorkspace(store: store)
        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))
        try await waitForCommands(chat)
        async let command: Void = chat.send("/compact")
        try await answerNextPermission(chat)
        await command
        #expect(model.conversations[workspace.id]?.map(\.title) == [nil])
        #expect(model.title(for: workspace) == (workspace.name, true))
        await model.stopAllAgents()

        let reopened = try makeModel(store: store)
        await reopened.bootstrap()
        await reopened.showConversations(workspace: workspace)
        #expect(reopened.conversations[workspace.id]?.map(\.title) == [nil])
        let resumed = try #require(reopened.existingChat(workspaceId: workspace.id))
        async let normal: Void = resumed.send("Fix invoice rounding")
        try await answerNextPermission(resumed)
        await normal
        #expect(reopened.conversations[workspace.id]?.map(\.title) == ["Fix invoice rounding"])
        #expect(reopened.title(for: workspace) == ("Fix invoice rounding", false))
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
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)

        _ = await model.openChat(workspace: workspace, agent: .opencode)
        #expect(launches.last?["CLAUDE_CONFIG_DIR"] == nil)
        await model.stopAllAgents()
    }

    // MARK: GitHub account (ACC-01, ENV-01)

    /// ACC-01: the setting, else the login equal to the remote's owner, else gh's active account; nothing without a
    /// GitHub remote. The remote and gh's account list are read once per launch.
    @Test func githubLoginDefaultsToTheOwnerElseTheActiveAccount() async throws {
        let gh = FakeGH()
        let remotes = FakeRemotes([
            "alpha": GitHubRepository(owner: "ocampos-biai", name: "alpha"),
            "beta": GitHubRepository(owner: "celes-dev", name: "beta"),
        ])
        let model = try makeModel(gh: gh, remotes: remotes)
        await model.bootstrap()
        let parent = try Fixtures.temporaryDirectory("repos")
        for name in ["alpha", "beta", "gamma"] {
            await model.addRepo(at: try await GitFixture.localRepoOffMain(in: parent, name: name))
        }
        let alpha = try #require(model.repos.first { $0.name == "alpha" })
        let beta = try #require(model.repos.first { $0.name == "beta" })
        let gamma = try #require(model.repos.first { $0.name == "gamma" })

        #expect(await model.githubLogin(for: alpha) == "ocampos-biai")
        #expect(await model.githubLogin(for: beta) == "jhzl1")
        #expect(await model.githubLogin(for: gamma) == nil)
        #expect(await model.githubRepository(for: alpha) == GitHubRepository(owner: "ocampos-biai", name: "alpha"))

        model.setGitHubLogin(repoId: beta.id, "ocampos-biai")
        #expect(model.repo(id: beta.id)?.githubLogin == "ocampos-biai")
        #expect(await model.githubLogin(for: beta) == "ocampos-biai")
        #expect(await model.defaultGitHubLogin(for: beta) == "jhzl1")

        // "Automatic" stores nil and goes back to the default.
        model.setGitHubLogin(repoId: beta.id, nil)
        #expect(try model.store.repos().first { $0.id == beta.id }?.githubLogin == nil)
        #expect(await model.githubLogin(for: beta) == "jhzl1")

        #expect(gh.calls.filter { $0.starts(with: ["auth", "status"]) }.count == 1)
        #expect(remotes.lookups.sorted() == ["alpha", "beta", "gamma"])
    }

    /// ACC-01 for an organization's repository (user report, 2026-09-23): celes-app is no login, and the active jhzl1
    /// gets a 404, so the default is ocampos-biai, the account that can read it. Each account is asked once per launch,
    /// the active one first.
    @Test func organizationRepositoryDefaultsToTheAccountThatCanReadIt() async throws {
        let (personal, personalRoute) = RoutedGitHubProtocol.route { _ in .init(status: 404) }
        let (work, workRoute) = RoutedGitHubProtocol.route { _ in .init(status: 200) }
        let gh = FakeGH(tokens: ["jhzl1": personal, "ocampos-biai": work])
        let remotes = FakeRemotes(["celes-platform": GitHubRepository(owner: "celes-app", name: "celes-platform")])
        let model = try makeModel(gh: gh, remotes: remotes, githubSession: RoutedGitHubProtocol.session())
        await model.bootstrap()
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"), name: "celes-platform"))
        let repo = try #require(model.repos.first)

        #expect(await model.defaultGitHubLogin(for: repo) == "ocampos-biai")
        #expect(await model.githubLogin(for: repo) == "ocampos-biai")

        #expect(personalRoute.requests.map { $0.request.url?.path } == ["/repos/celes-app/celes-platform"])
        #expect(workRoute.requests.map { $0.request.url?.path } == ["/repos/celes-app/celes-platform"])
        let tokenLogins = gh.calls.filter { $0.starts(with: ["auth", "token"]) }.compactMap { call in
            call.firstIndex(of: "--user").map { call[$0 + 1] }
        }
        #expect(tokenLogins == ["jhzl1", "ocampos-biai"])
    }

    /// ENV-01: an account change applies to new processes; the running agent keeps its token.
    @Test func accountChangeDoesNotStopRunningAgents() async throws {
        let gh = FakeGH(tokens: ["jhzl1": "gho_personal", "ocampos-biai": "gho_work"])
        let launches = LaunchBox()
        let model = try makeModel(launches: launches, gh: gh, remotes: FakeRemotes(["app": GitHubRepository(owner: "jhzl1", name: "app")]))
        await model.bootstrap()
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos")))
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))
        #expect(launches.last?["GH_TOKEN"] == "gho_personal")

        model.setGitHubLogin(repoId: repoId, "ocampos-biai")
        #expect(chat.state == .ready)
        #expect(model.existingChat(workspaceId: workspace.id) === chat)

        let second = try #require(await model.newConversation(workspace: workspace, agent: .opencode))
        #expect(launches.last?["GH_TOKEN"] == "gho_work")
        #expect(second !== chat)
        #expect(chat.state == .ready)
        await model.stopAllAgents()
    }

    // MARK: Pull request actions (GST-02, GST-03, CHK-02, AGT-00…AGT-03)

    /// A model whose repository "app" is jhzl1/app on GitHub under the account jhzl1, with `token`: a route's, so its
    /// requests reach that route. A second one on the same store is Rocky relaunched.
    private func githubModel(token: String, store: RockyStore? = nil, defaults: UserDefaults? = nil) throws -> AppModel {
        try makeModel(
            store: store,
            defaults: defaults,
            gh: FakeGH(tokens: ["jhzl1": token]),
            remotes: FakeRemotes(["app": GitHubRepository(owner: "jhzl1", name: "app")]),
            githubSession: RoutedGitHubProtocol.session()
        )
    }

    /// A workspace of the repository "app", which is jhzl1/app on GitHub under the account jhzl1, whose token routes
    /// GitHub's requests to `reply`. Returns once the selection's refresh has a snapshot.
    private func githubWorkspace(
        store: RockyStore? = nil,
        _ reply: @escaping @Sendable (StubURLProtocol.Sent) -> StubURLProtocol.Reply
    ) async throws -> (AppModel, Workspace, RoutedGitHubProtocol.Route) {
        let (token, route) = RoutedGitHubProtocol.route(reply)
        let model = try githubModel(token: token, store: store)
        await model.bootstrap()
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos")))
        let repoId = try #require(model.repos.first?.id)
        // Creating the workspace selects it, and selecting it refreshes its pull request (PR-07).
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        try await waitUntil { model.pullRequests.panels[workspace.id]?.snapshot != nil }
        return (model, workspace, route)
    }

    /// CHK-02: one POST per distinct workflow run of the failed check runs; a status context is left alone. Then the
    /// pull request refreshes (PR-07).
    @Test func rerunPostsOncePerWorkflowRun() async throws {
        let snapshot = GitHubStubs.snapshot(checks: [
            GitHubStubs.checkRun("unit", conclusion: "FAILURE", job: 11, run: 901),
            GitHubStubs.checkRun("e2e", conclusion: "FAILURE", job: 12, run: 901),
            GitHubStubs.checkRun("build", conclusion: "SUCCESS", job: 13, run: 902),
            GitHubStubs.checkRun("docs", conclusion: "TIMED_OUT", job: 14, run: 903),
            GitHubStubs.statusContext("ci/circleci", state: "FAILURE", url: "https://circleci.com/gh/jhzl1/app/12"),
        ])
        let (model, workspace, route) = try await githubWorkspace { sent in
            if sent.request.url?.path == "/graphql" { return .init(body: snapshot) }
            if sent.request.url?.path.hasSuffix("/rerun-failed-jobs") == true { return .init(status: 201) }
            return .init(status: 404)
        }

        await model.rerunFailedChecks(workspaceId: workspace.id)

        let sent = route.requests
        let reruns = sent.filter { $0.request.url?.path.hasSuffix("/rerun-failed-jobs") == true }
        #expect(reruns.map { $0.request.url?.path } == [
            "/repos/jhzl1/app/actions/runs/901/rerun-failed-jobs",
            "/repos/jhzl1/app/actions/runs/903/rerun-failed-jobs",
        ])
        #expect(reruns.allSatisfy { $0.request.httpMethod == "POST" })
        let lastRerun = try #require(sent.lastIndex { $0.request.url?.path.hasSuffix("/rerun-failed-jobs") == true })
        #expect(sent[(lastRerun + 1)...].contains { $0.request.url?.path == "/graphql" })
        #expect(!model.isRunning(.rerun, workspaceId: workspace.id))
    }

    /// AGT-00: the prompt, as typed, goes to the selected conversation, which the workspace shows instead of its file
    /// tab. The base comes from the workspace (no pull request yet).
    @Test func agentActionGoesToTheSelectedConversationAndShowsIt() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, chat) = try await workspaceWithAConversation(store: store)
        model.openFile(workspaceId: workspace.id, path: "/repo/a.png")
        #expect(model.selectedFiles[workspace.id] == "/repo/a.png")

        async let sending: Void = model.createPullRequest(workspaceId: workspace.id, draft: false)
        try await answerNextPermission(chat)
        await sending

        #expect(model.selectedFiles[workspace.id] == nil)
        #expect(model.existingChat(workspaceId: workspace.id) === chat)
        #expect(chat.items.last(where: { $0.kind == .user })?.text == "Create a pull request for this branch. First commit any uncommitted changes and push with `git push -u origin HEAD`. Then run `gh pr create --base main` with a title under 80 characters and a description of at most five sentences. If the repository has a pull request template, fill it in.")
        await model.stopAllAgents()
    }

    /// AGT-00 (user decision): while the turn runs the actions are unavailable and send nothing, not even to the queue;
    /// with the agent stopped they say to restart it.
    @Test func agentActionsAreUnavailableWhileTheTurnRuns() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, chat) = try await workspaceWithAConversation(store: store)
        #expect(model.agentActionAvailability(workspaceId: workspace.id) == .available)

        async let turn: Void = chat.send("a long task")
        try await waitUntil { chat.pendingPermission != nil }
        #expect(model.agentActionAvailability(workspaceId: workspace.id) == .working)
        #expect(AgentActionAvailability.working.reason == "The agent is working")
        await model.commitAndPush(workspaceId: workspace.id)
        #expect(!chat.items.contains { $0.text == "Commit and push all changes." })
        #expect(chat.queue.isEmpty)
        chat.answerPermission(optionId: "allow")
        await turn
        #expect(model.agentActionAvailability(workspaceId: workspace.id) == .available)

        await chat.stop()
        #expect(model.agentActionAvailability(workspaceId: workspace.id) == .stopped)
        #expect(AgentActionAvailability.stopped.reason == "Restart the agent first")
        await model.commitAndPush(workspaceId: workspace.id)
        #expect(!chat.items.contains { $0.text == "Commit and push all changes." })
        await model.stopAllAgents()
    }

    /// AGT-03: the old logs go; a job's log is saved and attached; a job that never started gives its annotations and
    /// another CI system its URL, one line each after the request.
    @Test func fixErrorsAttachesLogsAndListsOtherChecks() async throws {
        let snapshot = GitHubStubs.snapshot(checks: [
            GitHubStubs.checkRun("e2e / chromium", conclusion: "FAILURE", job: 7002, run: 901),
            GitHubStubs.checkRun("deploy-docs", conclusion: "FAILURE", job: 7004, run: 902, started: false),
            GitHubStubs.statusContext("ci/circleci", state: "FAILURE", url: "https://circleci.com/gh/jhzl1/app/12"),
            GitHubStubs.checkRun("build", conclusion: "SUCCESS", job: 7001, run: 901),
        ])
        let log = Data("step 1\nstep 2\nError: timeout\n".utf8)
        let annotations = Data(#"[{"message":"The job was not started because your account is locked due to a billing issue."}]"#.utf8)
        let (model, workspace, route) = try await githubWorkspace { sent in
            switch sent.request.url?.path {
            case "/graphql": return .init(body: snapshot)
            case "/repos/jhzl1/app/actions/jobs/7002/logs": return .init(body: log)
            case "/repos/jhzl1/app/check-runs/7004/annotations": return .init(body: annotations)
            default: return .init(status: 404)
            }
        }
        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))
        let folder = CILogs.folder(for: workspace.id, in: model.paths.ciLogs)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appendingPathComponent("unit.log"))

        async let fixing: Void = model.fixFailingChecks(workspaceId: workspace.id)
        try await answerNextPermission(chat)
        await fixing

        let prompt = try #require(chat.items.last(where: { $0.kind == .user }))
        #expect(prompt.text == """
            Fix the failing CI actions. I've attached the failure logs.

            deploy-docs: The job was not started because your account is locked due to a billing issue.
            ci/circleci: https://circleci.com/gh/jhzl1/app/12
            """)
        let saved = folder.appendingPathComponent("e2e-chromium.log")
        #expect(prompt.attachments == [saved.path])
        #expect(try Data(contentsOf: saved) == log)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("unit.log").path))
        #expect(!route.requests.contains { $0.request.url?.path == "/repos/jhzl1/app/actions/jobs/7004/logs" })
        await model.stopAllAgents()
    }

    /// AGT-01's "Create PR manually": GitHub's compare page of the base with the branch.
    @Test func compareURLNamesTheBaseAndTheBranch() async throws {
        let model = try makeModel(gh: FakeGH(), remotes: FakeRemotes(["app": GitHubRepository(owner: "jhzl1", name: "app")]))
        await model.bootstrap()
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos")))
        let repo = try #require(model.repos.first)
        await model.createWorkspace(repoId: repo.id)
        let workspace = try #require(model.workspaces[repo.id]?.first)
        _ = await model.githubRepository(for: repo)

        #expect(model.compareURL(workspaceId: workspace.id) == URL(string: "https://github.com/jhzl1/app/compare/main...\(workspace.branch)?expand=1"))
    }

    @Test func removingAWorkspaceDeletesItsCILogs() async throws {
        let model = try makeModel()
        await model.bootstrap()
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos")))
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        let folder = try CILogs.freshFolder(for: workspace.id, in: model.paths.ciLogs)
        try Data("log".utf8).write(to: folder.appendingPathComponent("unit.log"))

        await model.removeWorkspace(id: workspace.id)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// A workspace of a clone of a local origin whose `trunk` gained a commit after the worktree was made, so the
    /// branch is behind its base by one. Returns the other clone that pushed it.
    private func workspaceBehindItsBase() async throws -> (AppModel, Workspace, URL) {
        let model = try makeModel()
        await model.bootstrap()
        let parent = try Fixtures.temporaryDirectory("repos")
        await model.addRepo(at: try await GitFixture.clonedRepoOffMain(in: parent))
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        try #require(workspace.baseRef == "origin/trunk")
        let other = parent.appendingPathComponent("other", isDirectory: true)
        try await GitFixture.gitOffMain(["clone", "-q", parent.appendingPathComponent("origin.git").path, other.path], in: parent)
        try Data("news\n".utf8).write(to: other.appendingPathComponent("NEWS.md"))
        try await GitFixture.gitOffMain(["add", "NEWS.md"], in: other)
        try await GitFixture.gitOffMain(["commit", "-q", "-m", "news"], in: other)
        try await GitFixture.gitOffMain(["push", "-q", "origin", "HEAD:trunk"], in: other)
        return (model, workspace, other)
    }

    /// GST-02: a branch with no commits of its own fast-forwards to origin/<base>, with no merge commit, and says so.
    @Test func pullFromBaseFastForwardsWhenOnlyBehind() async throws {
        let (model, workspace, other) = try await workspaceBehindItsBase()
        var toasts: [String] = []
        model.onToast = { toasts.append($0) }

        await model.pullFromBase(workspaceId: workspace.id)

        let worktree = URL(fileURLWithPath: workspace.path)
        let worktreeHead = try await GitFixture.gitOffMain(["rev-parse", "HEAD"], in: worktree)
        let otherHead = try await GitFixture.gitOffMain(["rev-parse", "HEAD"], in: other)
        #expect(worktreeHead == otherHead)
        #expect(try await GitFixture.gitOffMain(["rev-list", "--merges", "--count", "HEAD"], in: worktree) == "0")
        #expect(toasts == ["Pulled latest changes. You're up to date!"])
        #expect(!model.isRunning(.pullFromBase, workspaceId: workspace.id))
    }

    /// GST-02: a diverged branch goes to the agent, here to rebase (`pull.rebase`); Rocky itself leaves it as it was.
    @Test func pullFromBaseSendsTheAgentWhenDiverged() async throws {
        let (model, workspace, _) = try await workspaceBehindItsBase()
        let worktree = URL(fileURLWithPath: workspace.path)
        try Data("mine\n".utf8).write(to: worktree.appendingPathComponent("MINE.md"))
        try await GitFixture.gitOffMain(["add", "MINE.md"], in: worktree)
        try await GitFixture.gitOffMain(["commit", "-q", "-m", "mine"], in: worktree)
        try await GitFixture.gitOffMain(["config", "pull.rebase", "true"], in: worktree)
        let head = try await GitFixture.gitOffMain(["rev-parse", "HEAD"], in: worktree)
        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))

        async let pulling: Void = model.pullFromBase(workspaceId: workspace.id)
        try await answerNextPermission(chat)
        await pulling

        #expect(chat.items.last(where: { $0.kind == .user })?.text == "Rebase this branch onto origin/trunk. Then push --force-with-lease.")
        #expect(try await GitFixture.gitOffMain(["rev-parse", "HEAD"], in: worktree) == head)
        await model.stopAllAgents()
    }

    /// GST-02's first step: uncommitted changes go to the agent before anything else.
    @Test func pullFromBaseWithUncommittedChangesAsksTheAgentToCommitFirst() async throws {
        let (model, workspace, _) = try await workspaceBehindItsBase()
        try Data("draft\n".utf8).write(to: URL(fileURLWithPath: workspace.path).appendingPathComponent("DRAFT.md"))
        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))

        async let pulling: Void = model.pullFromBase(workspaceId: workspace.id)
        try await answerNextPermission(chat)
        await pulling

        #expect(chat.items.last(where: { $0.kind == .user })?.text == "Commit your changes, then bring in origin/trunk and push.")
        await model.stopAllAgents()
    }

    // MARK: Comments (REV-01, AGT-05)

    /// GitHub's answers with `Fixtures/github-comments.json` for REV-01's query, and PR-01's otherwise.
    private static func answeringComments() -> @Sendable (StubURLProtocol.Sent) -> StubURLProtocol.Reply {
        let comments = Fixtures.json("github-comments")
        return { sent in
            if sent.graphQL?.query.contains("reviewThreads") == true { return .init(body: comments) }
            return .init(body: GitHubStubs.snapshot())
        }
    }

    /// AGT-05: "Add all to chat" sends every pending comment in REV-01's order (threads with their replies, the
    /// conversation, then review bodies) as one prompt, and marks each added; a row's "Add to chat" sends only it.
    @Test func addAllSendsEveryPendingCommentInOrder() async throws {
        let (model, workspace, _) = try await githubWorkspace(Self.answeringComments())
        model.pullRequests.setCommentsVisible(true, workspaceId: workspace.id)
        try await waitUntil { model.pullRequests.panels[workspace.id]?.comments.count == 4 }
        let chat = try #require(await model.openChat(workspace: workspace, agent: .claude))

        async let sendingAll: Void = model.sendComments(workspaceId: workspace.id, ids: nil)
        try await answerNextPermission(chat)
        await sendingAll

        #expect(chat.items.last(where: { $0.kind == .user })?.text == """
            Review comments on pull request #4525:

            1. ana on src/ocr/retry.ts, line 42
            > Use exponential backoff instead of a fixed delay.
            > jhzl: Would a jitter help too?
            > ana: Yes, add full jitter.

            2. ghost on README.md
            > Mention the retry policy.

            3. ana (conversation)
            > Please add a test for the timeout path.

            4. ana (review)
            > Split the retry policy out of the OCR client.

            Address each comment and say what you changed for each number.
            """)
        #expect(model.pullRequests.panels[workspace.id]?.addedCommentIds == ["PRRT_retry", "PRRT_file", "IC_timeout", "PRR_split"])

        async let sendingOne: Void = model.sendComments(workspaceId: workspace.id, ids: ["IC_timeout"])
        try await answerNextPermission(chat)
        await sendingOne

        #expect(chat.items.last(where: { $0.kind == .user })?.text == """
            Review comments on pull request #4525:

            1. ana (conversation)
            > Please add a test for the timeout path.

            Address each comment and say what you changed for each number.
            """)
        await model.stopAllAgents()
    }

    /// REV-01: Hide takes the comment out of the list and stores its id with the pull request's state (PR-07), so a
    /// relaunched Rocky reading the same comments leaves it out.
    @Test func hiddenCommentStaysHiddenAfterRelaunch() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, route) = try await githubWorkspace(store: store, Self.answeringComments())
        model.pullRequests.setCommentsVisible(true, workspaceId: workspace.id)
        try await waitUntil { model.pullRequests.panels[workspace.id]?.comments.count == 4 }

        model.hideComment(workspaceId: workspace.id, id: "IC_timeout")

        #expect(model.pullRequests.panels[workspace.id]?.comments.map(\.id) == ["PRRT_retry", "PRRT_file", "PRR_split"])
        #expect(try store.workspaces(repoId: workspace.repoId).first?.storedPullRequest?.hiddenCommentIds == ["IC_timeout"])

        let relaunched = try githubModel(token: route.token, store: store)
        await relaunched.bootstrap()
        relaunched.pullRequests.setCommentsVisible(true, workspaceId: workspace.id)
        relaunched.selectedWorkspaceId = workspace.id
        try await waitUntil { relaunched.pullRequests.panels[workspace.id]?.comments.isEmpty == false }
        #expect(relaunched.pullRequests.panels[workspace.id]?.comments.map(\.id) == ["PRRT_retry", "PRRT_file", "PRR_split"])
    }

    // MARK: Merge, ready for review and archive (PR-05, PR-06, PR-08, SET-01)

    /// PR-05: the viewer's default until the menu picks another method, which the merge uses and which lasts until
    /// Rocky quits (never stored). The first click only asks for the confirmation; picking a method cancels it.
    @Test func mergeUsesThePickedMethodUntilQuit() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, route) = try await githubWorkspace(store: store) { sent in
            if sent.graphQL?.query.contains("mergePullRequest") == true {
                return .init(body: Data(#"{"data":{"mergePullRequest":{"pullRequest":{"id":"PR_1"}}}}"#.utf8))
            }
            return .init(body: GitHubStubs.snapshot())
        }
        let merges = { route.requests.compactMap(\.graphQL).filter { $0.query.contains("mergePullRequest") } }
        #expect(model.mergeMethods(workspaceId: workspace.id) == [.squash, .rebase, .merge])
        #expect(model.mergeMethod(workspaceId: workspace.id) == .squash)

        model.setMergeMethod(workspaceId: workspace.id, .rebase)
        #expect(model.mergeMethod(workspaceId: workspace.id) == .rebase)

        await model.confirmOrMerge(workspaceId: workspace.id)
        #expect(model.isConfirmingMerge(workspaceId: workspace.id))
        #expect(merges().isEmpty)
        await model.confirmOrMerge(workspaceId: workspace.id)

        #expect(merges().count == 1)
        #expect(merges().first?.variables == ["id": "PR_1", "method": "REBASE"])
        let graphQL = route.requests.compactMap(\.graphQL)
        let merge = try #require(graphQL.firstIndex { $0.query.contains("mergePullRequest") })
        #expect(graphQL[(merge + 1)...].contains { $0.query.contains("pullRequests(headRefName") })
        #expect(!model.isConfirmingMerge(workspaceId: workspace.id))
        #expect(!model.isRunning(.merge, workspaceId: workspace.id))
        #expect(model.mergeErrors[workspace.id] == nil)
        #expect(model.mergeMethod(workspaceId: workspace.id) == .rebase)

        await model.confirmOrMerge(workspaceId: workspace.id)
        model.setMergeMethod(workspaceId: workspace.id, .merge)
        #expect(!model.isConfirmingMerge(workspaceId: workspace.id))
        #expect(model.mergeMethod(workspaceId: workspace.id) == .merge)
        #expect(merges().count == 1)

        let relaunched = try githubModel(token: route.token, store: store)
        await relaunched.bootstrap()
        await relaunched.pullRequests.refresh(workspaceId: workspace.id, reason: .button)
        #expect(relaunched.mergeMethod(workspaceId: workspace.id) == .squash)
    }

    /// PR-08: GitHub's mutation with the pull request's id, no confirmation, then a refresh that shows it out of draft.
    @Test func readyForReviewMarksThePullRequestThenRefreshes() async throws {
        let ready = SharedFlag()
        let (model, workspace, route) = try await githubWorkspace { sent in
            if sent.graphQL?.query.contains("markPullRequestReadyForReview") == true {
                ready.set()
                return .init(body: Data(#"{"data":{"markPullRequestReadyForReview":{"pullRequest":{"id":"PR_1"}}}}"#.utf8))
            }
            return .init(body: GitHubStubs.snapshot(isDraft: !ready.isSet))
        }
        #expect(model.pullRequests.panels[workspace.id]?.snapshot?.pullRequest?.isDraft == true)

        await model.markReadyForReview(workspaceId: workspace.id)

        let graphQL = route.requests.compactMap(\.graphQL)
        let mutation = try #require(graphQL.firstIndex { $0.query.contains("markPullRequestReadyForReview") })
        #expect(graphQL[mutation].variables == ["id": "PR_1"])
        #expect(model.pullRequests.panels[workspace.id]?.snapshot?.pullRequest?.isDraft == false)
        #expect(!model.isRunning(.readyForReview, workspaceId: workspace.id))
    }

    /// SET-01: off by default and kept in UserDefaults; off, a merge leaves the workspace where it is.
    @Test func archiveOnMergeIsOffByDefault() async throws {
        let defaults = try #require(UserDefaults(suiteName: "rocky-tests-\(UUID().uuidString)"))
        let first = try makeModel(defaults: defaults)
        #expect(!first.archiveOnMerge)
        first.archiveOnMerge = true
        #expect(defaults.bool(forKey: "archiveOnMerge"))
        #expect(try makeModel(defaults: defaults).archiveOnMerge)

        let merged = SharedFlag()
        let (model, workspace, _) = try await githubWorkspace { _ in
            .init(body: GitHubStubs.snapshot(state: merged.isSet ? "MERGED" : "OPEN"))
        }
        #expect(!model.archiveOnMerge)
        merged.set()
        await model.pullRequests.refresh(workspaceId: workspace.id, reason: .button)

        #expect(model.pullRequestHeader(workspaceId: workspace.id).label == "Merged")
        #expect(model.workspace(id: workspace.id) != nil)
        #expect(FileManager.default.fileExists(atPath: workspace.path))
    }

    /// SET-01: on, the merge Rocky sees runs PR-06's archive once and says "Archived <name>"; a second refresh of the
    /// merged pull request archives nothing more.
    @Test func archiveOnMergeRemovesTheWorkspaceOnce() async throws {
        let merged = SharedFlag()
        let (model, workspace, _) = try await githubWorkspace { _ in
            .init(body: GitHubStubs.snapshot(state: merged.isSet ? "MERGED" : "OPEN"))
        }
        var toasts: [String] = []
        model.onToast = { toasts.append($0) }
        model.archiveOnMerge = true

        merged.set()
        await model.pullRequests.refresh(workspaceId: workspace.id, reason: .button)
        await model.pullRequests.refresh(workspaceId: workspace.id, reason: .button)

        try await waitUntil { toasts.contains("Archived \(workspace.name)") }
        #expect(model.workspace(id: workspace.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        #expect(toasts.filter { $0.hasPrefix("Archived") } == ["Archived \(workspace.name)"])
        #expect(!model.isRunning(.archive, workspaceId: workspace.id))
    }

    /// SET-01 never archives a worktree with uncommitted changes, and says so.
    @Test func archiveOnMergeSkipsAWorktreeWithChanges() async throws {
        let merged = SharedFlag()
        let (model, workspace, _) = try await githubWorkspace { _ in
            .init(body: GitHubStubs.snapshot(state: merged.isSet ? "MERGED" : "OPEN"))
        }
        var toasts: [String] = []
        model.onToast = { toasts.append($0) }
        model.archiveOnMerge = true
        try Data("draft\n".utf8).write(to: URL(fileURLWithPath: workspace.path).appendingPathComponent("DRAFT.md"))

        merged.set()
        await model.pullRequests.refresh(workspaceId: workspace.id, reason: .button)

        try await waitUntil { !toasts.isEmpty }
        #expect(toasts == ["\(workspace.name) merged but has uncommitted changes; not archived"])
        #expect(model.workspace(id: workspace.id) != nil)
        #expect(FileManager.default.fileExists(atPath: workspace.path))
    }

    /// PR-06: the question counts what is uncommitted, and its Archive puts the changes, untracked files included, in
    /// a stash of the repository before git removes the worktree; the branch stays.
    @Test func archiveAnywayStashesTheChangesFirst() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let repo = try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos"))
        await model.addRepo(at: repo)
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        try Data("draft\n".utf8).write(to: URL(fileURLWithPath: workspace.path).appendingPathComponent("DRAFT.md"))

        #expect(await model.uncommittedChangeCount(workspaceId: workspace.id) == 1)
        #expect(AppModel.archiveQuestion(workspaceName: "tokyo", uncommitted: 1) == "tokyo has 1 uncommitted change. Archive anyway?")
        #expect(AppModel.archiveQuestion(workspaceName: "tokyo", uncommitted: 3) == "tokyo has 3 uncommitted changes. Archive anyway?")

        await model.archiveMergedWorkspace(workspaceId: workspace.id, stashingChanges: true)

        #expect(model.workspace(id: workspace.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        #expect(try await GitFixture.gitOffMain(["stash", "list", "--format=%s"], in: repo).contains("Rocky archived \(workspace.name)"))
        #expect(try await GitFixture.gitOffMain(["show", "--name-only", "--format=", "stash@{0}^3"], in: repo).contains("DRAFT.md"))
        #expect(try await GitFixture.gitOffMain(["rev-parse", "--verify", "--quiet", "refs/heads/\(workspace.branch)"], in: repo).isEmpty == false)
    }

    // MARK: Sidebar (ROW-07)

    /// ROW-07: from the stored state, so after a relaunch too: merged, and an open one with a failed check.
    @Test func mergedWorkspaceShowsMergedStatus() async throws {
        let store = try RockyStore.inMemory()
        let model = try makeModel(store: store)
        await model.bootstrap()
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos")))
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        await model.createWorkspace(repoId: repoId)
        let workspaces = try #require(model.workspaces[repoId])
        try #require(workspaces.count == 2)
        #expect(model.status(workspaceId: workspaces[0].id) == .idle)
        let url = URL(string: "https://github.com/jhzl1/app/pull/4520")!
        try store.savePullRequest(
            StoredPullRequest(number: 4520, url: url, state: "MERGED", headerState: HeaderState.merged.rawValue, checks: [], updatedAt: Date()),
            workspaceId: workspaces[0].id
        )
        try store.savePullRequest(
            StoredPullRequest(
                number: 4521, url: url, state: "OPEN", headerState: HeaderState.checksFailing.rawValue,
                checks: [PullRequestCheck(name: "unit", state: .failed)], updatedAt: Date()
            ),
            workspaceId: workspaces[1].id
        )

        let relaunched = try makeModel(store: store)
        await relaunched.bootstrap()
        #expect(relaunched.status(workspaceId: workspaces[0].id) == .merged)
        #expect(relaunched.status(workspaceId: workspaces[1].id) == .pullRequest(tone: .failed))
    }

    @Test func environmentCaptureFailureFallsBackAndReports() async throws {
        struct Boom: Error {}
        let model = try makeModel(capture: { throw Boom() })
        await model.bootstrap()
        #expect(model.loginEnvironment["PATH"] != nil)
        #expect(model.errorMessage?.hasPrefix("Could not read your login shell environment") == true)
    }
}
