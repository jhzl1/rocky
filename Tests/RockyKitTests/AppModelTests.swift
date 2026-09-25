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

/// Stands in for FSEvents in `AppModel` tests (GIT-01): keeps each workspace's stream, so a test fires its events and
/// sees it stop.
final class FakeWatchers: @unchecked Sendable {
    final class Watch: WorkspaceWatch, @unchecked Sendable {
        let worktree: URL
        let onChange: @Sendable (FolderEvents) -> Void
        private let lock = NSLock()
        private var stopped = false

        init(worktree: URL, onChange: @escaping @Sendable (FolderEvents) -> Void) {
            self.worktree = worktree
            self.onChange = onChange
        }

        func stop() {
            lock.withLock { stopped = true }
        }

        var isStopped: Bool {
            lock.withLock { stopped }
        }
    }

    private let lock = NSLock()
    private var watches: [Watch] = []

    func watch(_ worktree: URL, _ onChange: @escaping @Sendable (FolderEvents) -> Void) -> any WorkspaceWatch {
        let watch = Watch(worktree: worktree, onChange: onChange)
        lock.withLock { watches.append(watch) }
        return watch
    }

    /// The last stream started for the worktree at `path`.
    func watch(of path: String) -> Watch? {
        lock.withLock { watches.last { $0.worktree.path == path } }
    }

    /// One batch of events, as FSEvents would send it after its debounce.
    func fire(_ path: String, folders: Set<String> = []) {
        watch(of: path)?.onChange(FolderEvents(folders: folders.isEmpty ? [path] : folders))
    }
}

/// The All files tab's reads (FIL-07) through the real `WorktreeFiles`, counted: each `ls-files` run and each folder
/// listed, in order.
final class FakeWorktreeFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var lists = 0
    private var folders: [String] = []

    var listCount: Int {
        lock.withLock { lists }
    }

    var listedFolders: [String] {
        lock.withLock { folders }
    }

    func reset() {
        lock.withLock {
            lists = 0
            folders = []
        }
    }

    func reader(_ environment: [String: String]) -> any WorktreeFileReading {
        Reader(owner: self, files: WorktreeFiles(environment: environment))
    }

    private func recordList() {
        lock.withLock { lists += 1 }
    }

    private func recordListing(_ folder: String) {
        lock.withLock { folders.append(folder) }
    }

    private struct Reader: WorktreeFileReading {
        let owner: FakeWorktreeFiles
        let files: WorktreeFiles

        func list(worktree: URL, reusing previous: FileList?) throws -> FileList {
            owner.recordList()
            return try files.list(worktree: worktree, reusing: previous)
        }

        func listing(worktree: URL, folder: String) throws -> [FileEntry] {
            owner.recordListing(folder)
            return try files.listing(worktree: worktree, folder: folder)
        }
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
        githubSession: URLSession = OfflineURLProtocol.session(),
        watchers: FakeWatchers = FakeWatchers(),
        worktreeFiles: FakeWorktreeFiles = FakeWorktreeFiles()
    ) throws -> AppModel {
        let root = try Fixtures.temporaryDirectory("app")
        let paths = RockyPaths(database: root.appendingPathComponent("rocky.sqlite"), adapterPrefix: root.appendingPathComponent("agents"), logs: root)
        return AppModel(
            store: try store ?? RockyStore.inMemory(),
            paths: paths,
            captureEnvironment: capture,
            makeLaunch: { kind, cwd, environment, _ in
                launches.record(environment)
                let fake = Fixtures.fakeACPLaunch(agent: kind)
                return AgentLaunch(executable: fake.executable, arguments: fake.arguments, environment: fake.environment, cwd: cwd, stderrLog: fake.stderrLog)
            },
            installAdapter: { _, _, _, _ in },
            latestVersion: { _ in "0.0.0" },
            defaults: defaults ?? UserDefaults(suiteName: "rocky-tests-\(UUID().uuidString)")!,
            runGH: { arguments, environment in try gh.run(arguments, environment: environment) },
            lookUpGitHubRepository: { clone, environment in remotes.lookUp(clone, environment) },
            githubSession: githubSession,
            watchWorkspace: { worktree, onChange in watchers.watch(worktree, onChange) },
            worktreeFiles: { worktreeFiles.reader($0) }
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

    /// CNV-01, CNV-02: "+" makes a conversation with the agent where the repository's last message went, Claude Code
    /// before any; a workspace's first conversation follows the same rule, and a conversation opened with another agent
    /// changes nothing until a message is sent in it.
    @Test func theDefaultAgentFollowsTheLastUserMessageInTheRepository() async throws {
        let (model, workspace) = try await emptyWorkspace(store: try RockyStore.inMemory())
        let first = try #require(await model.newConversation(workspace: workspace))
        #expect(first.agent == .claude)

        let opencode = try #require(await model.newConversation(workspace: workspace, agent: .opencode))
        async let sending: Void = opencode.send("hi")
        try await answerNextPermission(opencode)
        await sending
        let next = try #require(await model.newConversation(workspace: workspace))
        #expect(next.agent == .opencode)
        #expect(model.conversations[workspace.id]?.map(\.agent) == ["claude", "opencode", "opencode"])
        #expect(model.selectedConversationIds[workspace.id] == model.conversations[workspace.id]?.last?.id)

        // A Claude Code conversation picked from the bridge, with no message sent, leaves the default alone.
        _ = try #require(await model.newConversation(workspace: workspace, agent: .claude))
        #expect(try #require(await model.newConversation(workspace: workspace)).agent == .opencode)

        // Another workspace of the repository opens its first conversation with the same agent.
        await model.createWorkspace(repoId: workspace.repoId)
        let second = try #require(model.workspaces[workspace.repoId]?.first { $0.id != workspace.id })
        await model.showConversations(workspace: second)
        #expect(model.conversations[second.id]?.map(\.agent) == ["opencode"])
        #expect(model.existingChat(workspaceId: second.id)?.agent == .opencode)
        await model.stopAllAgents()
    }

    // MARK: Agents and models (AGM-01…AGM-07, KIT-11, KIT-12)

    /// AGM-04, KIT-12: the models a session reports reach the catalog and its file, each agent's apart, and a list
    /// announced later replaces the one before.
    @Test func aSessionsModelsReachTheCatalog() async throws {
        let (model, workspace) = try await emptyWorkspace(store: try RockyStore.inMemory())
        #expect(model.knownModels(agent: .claude, workspaceId: workspace.id) == nil)

        let claude = try #require(await model.openChat(workspace: workspace, agent: .claude))
        #expect(model.knownModels(agent: .claude, workspaceId: workspace.id)?.map(\.value) == ["default", "opus"])
        #expect(model.knownModels(agent: .opencode, workspaceId: workspace.id) == nil)
        _ = try #require(await model.openChat(workspace: workspace, agent: .opencode))
        #expect(model.knownModels(agent: .opencode, workspaceId: workspace.id)?.map(\.name) == ["Claude Sonnet 5", "GPT-5.5", "Qwen3 Coder"])

        await claude.send("add a model")
        #expect(model.knownModels(agent: .claude, workspaceId: workspace.id)?.map(\.value) == ["default", "opus", "haiku"])
        let reread = AgentModelCatalog(file: model.paths.agentModels)
        #expect(reread.models(agent: .claude, claudeInstance: nil)?.map(\.value) == ["default", "opus", "haiku"])
        #expect(reread.models(agent: .opencode, claudeInstance: nil)?.count == 3)
        await model.stopAllAgents()
    }

    /// AGM-04 without a button (user decision, 2026-09-25): an agent with no list reports one by itself, in no
    /// conversation, and a second call while it runs starts nothing more.
    @Test func anAgentWithNoListLoadsItsModelsByItself() async throws {
        let (model, workspace) = try await emptyWorkspace(store: try RockyStore.inMemory())
        let conversations = model.conversations[workspace.id] ?? []
        #expect(model.knownModels(agent: .opencode, workspaceId: workspace.id) == nil)

        model.loadModelsIfNeeded(agent: .opencode, workspaceId: workspace.id)
        model.loadModelsIfNeeded(agent: .opencode, workspaceId: workspace.id)
        try await waitUntil { model.knownModels(agent: .opencode, workspaceId: workspace.id) != nil }
        #expect(model.knownModels(agent: .opencode, workspaceId: workspace.id)?.map(\.name) == ["Claude Sonnet 5", "GPT-5.5", "Qwen3 Coder"])
        #expect(model.modelsFailure(agent: .opencode, workspaceId: workspace.id) == nil)
        #expect((model.conversations[workspace.id] ?? []) == conversations)
        await model.stopAllAgents()
    }

    /// AGM-04: a repository with its own Claude instance keeps that instance's list.
    @Test func claudesModelsAreKeptUnderTheRepositorysInstance() async throws {
        let (model, workspace) = try await emptyWorkspace(store: try RockyStore.inMemory())
        await model.setClaudeConfigDir(repoId: workspace.repoId, "/Users/me/.claude-celes")
        _ = try #require(await model.openChat(workspace: workspace, agent: .claude))
        #expect(model.knownModels(agent: .claude, workspaceId: workspace.id)?.map(\.value) == ["default", "opus"])
        #expect(model.modelCatalog.models(agent: .claude, claudeInstance: "/Users/me/.claude-celes")?.count == 2)
        #expect(model.modelCatalog.models(agent: .claude, claudeInstance: nil) == nil)
        await model.stopAllAgents()
    }

    private func waitUntilReady(_ chat: ChatSessionModel) async throws {
        try await waitUntil { chat.state == .ready }
    }

    /// KIT-11, AGM-02: a pick of another agent's model in an empty conversation switches it in place: the same record
    /// and tab, in its place and selected, its agent and its session id changed, and a chat in `chats` at every moment.
    /// The old agent stops, the new one gets the picked model once its session reports its options, and the draft,
    /// chip included, waits for the new message box.
    @Test func aPickInAnEmptyConversationSwitchesItInPlace() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace) = try await emptyWorkspace(store: store)
        let old = try #require(await model.newConversation(workspace: workspace, agent: .claude))
        let conversationId = try #require(model.selectedConversationIds[workspace.id])
        let other = try #require(await model.newConversation(workspace: workspace, agent: .claude))
        await model.showConversation(workspace: workspace, conversationId: conversationId)
        try await waitUntilReady(old)
        try await waitUntilReady(other)
        try await waitUntil { (try? store.session(id: conversationId))?.acpSessionId == "fake-1" }
        let tabs = try #require(model.conversations[workspace.id]?.map(\.id))

        let draft = MessageHistory.Entry(
            text: "Fix \(PromptAttachment.marker) too",
            files: ["/repo/notes.md"],
            lineRange: LineRangeAttachment(path: "/repo/a.swift", side: .new, start: 3, end: 5)
        )
        let finished = SharedFlag()
        let missing = SharedFlag()
        let watcher = Task { @MainActor in
            while !finished.isSet {
                if model.chat(conversationId: conversationId) == nil { missing.set() }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        let pick = await model.pickModel(conversationId: conversationId, agent: .opencode, model: "gpt-5.5", draft: draft)
        // Read before the new agent's start runs: the session id went with the old agent.
        let stored = try #require(try store.session(id: conversationId))
        finished.set()
        await watcher.value

        #expect(pick == .switchedInPlace)
        #expect(!missing.isSet)
        #expect(stored.agent == "opencode")
        #expect(stored.acpSessionId == nil)
        #expect(model.conversations[workspace.id]?.map(\.id) == tabs)
        #expect(model.conversations[workspace.id]?.map(\.agent) == ["opencode", "claude"])
        #expect(model.selectedConversationIds[workspace.id] == conversationId)
        #expect(old.state == .stopped("Stopped"))
        #expect(other.state == .ready)
        let fresh = try #require(model.chat(conversationId: conversationId))
        #expect(fresh !== old)
        #expect(fresh.agent == .opencode)
        #expect(model.existingChat(workspaceId: workspace.id) === fresh)

        #expect(model.pendingDrafts[conversationId] == draft)
        #expect(model.takePendingDraft(conversationId: conversationId) == draft)
        #expect(model.takePendingDraft(conversationId: conversationId) == nil)

        try await waitUntilReady(fresh)
        #expect(fresh.option(SessionConfigOption.model)?.current == "gpt-5.5")
        #expect(fresh.option(SessionConfigOption.effort)?.choices.map(\.value) == ["minimal", "low", "medium", "high", "default"])
        #expect(fresh.pendingModel == nil)
        await model.stopAllAgents()
    }

    /// AGM-02: an agent still starting is stopped by the switch and stays stopped, and a switch while the first one's
    /// agent starts switches again.
    @Test func aSwitchStopsAnAgentThatIsStillStarting() async throws {
        let (model, workspace) = try await emptyWorkspace(store: try RockyStore.inMemory())
        let starting = try #require(await model.newConversation(workspace: workspace, agent: .claude))
        let conversationId = try #require(model.selectedConversationIds[workspace.id])
        #expect(await model.pickModel(conversationId: conversationId, agent: .opencode, model: nil) == .switchedInPlace)
        let opencode = try #require(model.chat(conversationId: conversationId))
        #expect(await model.pickModel(conversationId: conversationId, agent: .claude, model: "opus") == .switchedInPlace)
        let claude = try #require(model.chat(conversationId: conversationId))

        try await waitUntilReady(claude)
        #expect(starting.state == .stopped("Stopped"))
        #expect(starting.failure == nil)
        #expect(opencode.state == .stopped("Stopped"))
        #expect(opencode.failure == nil)
        #expect(claude.option(SessionConfigOption.model)?.current == "opus")
        #expect(model.conversations[workspace.id]?.map(\.agent) == ["claude"])
        await model.stopAllAgents()
    }

    /// KIT-11, AGM-03: with a message sent, another agent's model opens a new conversation at the end, selected, with
    /// the picked model and the draft; the conversation left behind keeps its agent, its session and its chat.
    @Test func aPickWithMessagesOpensANewConversationAndLeavesTheOldOne() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, first) = try await workspaceWithAConversation(store: store)
        let firstId = try #require(model.selectedConversationIds[workspace.id])
        let draft = MessageHistory.Entry(text: "Now the tests", files: [], lineRange: LineRangeAttachment(path: "/repo/a.swift", side: .old, start: 2, end: 2))

        let pick = await model.pickModel(conversationId: firstId, agent: .opencode, model: "qwen3-coder", draft: draft)
        #expect(pick == .openedConversation)
        let tabs = try #require(model.conversations[workspace.id])
        #expect(tabs.map(\.agent) == ["claude", "opencode"])
        #expect(tabs.first?.id == firstId)
        let newId = try #require(tabs.last?.id)
        #expect(model.selectedConversationIds[workspace.id] == newId)
        #expect(model.takePendingDraft(conversationId: newId) == draft)
        #expect(model.takePendingDraft(conversationId: firstId) == nil)

        #expect(model.chat(conversationId: firstId) === first)
        #expect(first.state == .ready)
        #expect(first.agent == .claude)
        let stored = try #require(try store.session(id: firstId))
        #expect(stored.agent == "claude")
        #expect(stored.acpSessionId == "fake-1")

        let opened = try #require(model.chat(conversationId: newId))
        try await waitUntilReady(opened)
        #expect(opened.agent == .opencode)
        #expect(opened.option(SessionConfigOption.model)?.current == "qwen3-coder")
        #expect(opened.option(SessionConfigOption.effort) == nil)
        await model.stopAllAgents()
    }

    /// AGM-03, AGM-06: a queued message counts as a message, so the pick opens a new conversation and the queue stays.
    @Test func aQueuedMessageCountsAsAMessage() async throws {
        let (model, workspace) = try await emptyWorkspace(store: try RockyStore.inMemory())
        let chat = try #require(await model.newConversation(workspace: workspace, agent: .claude))
        let conversationId = try #require(model.selectedConversationIds[workspace.id])
        try await waitUntilReady(chat)
        chat.enqueue("after this turn")

        #expect(await model.pickModel(conversationId: conversationId, agent: .opencode, model: nil) == .openedConversation)
        #expect(model.conversations[workspace.id]?.map(\.agent) == ["claude", "opencode"])
        #expect(model.chat(conversationId: conversationId) === chat)
        #expect(chat.queue.map(\.text) == ["after this turn"])
        await model.stopAllAgents()
    }

    /// AGM-05, AGM-07: a model of the conversation's own agent changes it in place, and the effort shown is the one the
    /// agent answered, never the level before; picked while the agent starts, it waits for the session.
    @Test func aPickOfTheSameAgentSetsTheModel() async throws {
        let (model, workspace) = try await emptyWorkspace(store: try RockyStore.inMemory())
        let chat = try #require(await model.newConversation(workspace: workspace, agent: .claude))
        let conversationId = try #require(model.selectedConversationIds[workspace.id])
        #expect(chat.state != .ready)
        #expect(await model.pickModel(conversationId: conversationId, agent: .claude, model: "opus") == .setModel)
        #expect(chat.pendingModel?.value == "opus")
        try await waitUntilReady(chat)
        #expect(chat.option(SessionConfigOption.model)?.current == "opus")
        #expect(chat.option(SessionConfigOption.effort)?.current == "medium")

        await chat.setOption(SessionConfigOption.effort, to: "max")
        #expect(await model.pickModel(conversationId: conversationId, agent: .claude, model: "default") == .setModel)
        #expect(chat.option(SessionConfigOption.model)?.current == "default")
        #expect(chat.option(SessionConfigOption.effort)?.current == "high")
        #expect(model.chat(conversationId: conversationId) === chat)
        await model.stopAllAgents()
    }

    /// AGM-02: a picked model the new agent does not list keeps its default, and the toast says so.
    @Test func aPickedModelTheAgentDoesNotHaveKeepsItsDefault() async throws {
        let (model, workspace) = try await emptyWorkspace(store: try RockyStore.inMemory())
        var toasts: [String] = []
        model.onToast = { toasts.append($0) }
        _ = try #require(await model.newConversation(workspace: workspace, agent: .claude))
        let conversationId = try #require(model.selectedConversationIds[workspace.id])

        #expect(await model.pickModel(conversationId: conversationId, agent: .opencode, model: "gpt-9") == .switchedInPlace)
        let fresh = try #require(model.chat(conversationId: conversationId))
        try await waitUntilReady(fresh)
        #expect(fresh.option(SessionConfigOption.model)?.current == "claude-sonnet-5")
        #expect(toasts == ["gpt-9 isn't available in OpenCode; using Claude Sonnet 5"])
        await model.stopAllAgents()
    }

    /// KBD-04: each ⌃` press bumps its workspace's serial, and only its own, so the workspace's view acts on every press.
    @Test func terminalToggleRequestsCountPerWorkspace() throws {
        let model = try makeModel()
        #expect(model.terminalToggleRequests.isEmpty)
        model.requestTerminalToggle(workspaceId: "tokyo")
        model.requestTerminalToggle(workspaceId: "tokyo")
        model.requestTerminalToggle(workspaceId: "lima")
        #expect(model.terminalToggleRequests == ["tokyo": 2, "lima": 1])
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

    // MARK: Changes (GIT-01, GIT-03, CHG-01)

    /// A workspace of an empty repository whose stream is one of `watchers`, once its first stats are read.
    private func watchedWorkspace(watchers: FakeWatchers, files: FakeWorktreeFiles = FakeWorktreeFiles()) async throws -> (AppModel, Workspace) {
        let model = try makeModel(watchers: watchers, worktreeFiles: files)
        await model.bootstrap()
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos")))
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)
        try await waitUntil { watchers.watch(of: workspace.path) != nil && model.diffStats[workspace.id] != nil }
        return (model, workspace)
    }

    private func write(_ text: String, to path: String, in workspace: Workspace) async throws {
        let file = URL(fileURLWithPath: workspace.path).appendingPathComponent(path)
        try await Task.blocking { try Data(text.utf8).write(to: file) }.value
    }

    /// GIT-03: every workspace has a stream from the start; a change on disk refreshes its stats, and removing the
    /// workspace stops the stream and drops them.
    @Test func fileChangeRefreshesTheSidebarStats() async throws {
        let watchers = FakeWatchers()
        let (model, workspace) = try await watchedWorkspace(watchers: watchers)
        #expect(model.diffStats[workspace.id] == DiffStat())

        try await write("one\ntwo\n", to: "notes.md", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { model.diffStats[workspace.id] == DiffStat(additions: 2, deletions: 0, files: 1) }

        let watch = try #require(watchers.watch(of: workspace.path))
        #expect(!watch.isStopped)
        await model.removeWorkspace(id: workspace.id, stashingChanges: true)
        #expect(model.workspace(id: workspace.id) == nil)
        #expect(watch.isStopped)
        #expect(model.diffStats[workspace.id] == nil)
    }

    /// GIT-01: with the Changes tab hidden, a change reads the stats only. Showing the tab reads the full diff, each
    /// change after that reads it again, and selecting another workspace drops it.
    @Test func hiddenChangesTabDoesNotComputeTheFullDiff() async throws {
        let watchers = FakeWatchers()
        let (model, workspace) = try await watchedWorkspace(watchers: watchers)
        model.visibleRightPanelTab = .checks
        try await write("one\n", to: "a.md", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { model.diffStats[workspace.id]?.files == 1 }
        #expect(model.changes[workspace.id] == nil)

        model.visibleRightPanelTab = .changes
        try await waitUntil { model.changes[workspace.id]?.files.map(\.path) == ["a.md"] }

        try await write("two\n", to: "b.md", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { model.changes[workspace.id]?.files.map(\.path) == ["a.md", "b.md"] }
        #expect(model.diffStats[workspace.id] == DiffStat(additions: 2, deletions: 0, files: 2))

        model.selectedWorkspaceId = nil
        #expect(model.changes[workspace.id] == nil)
        #expect(model.visibleRightPanelTab == nil)
    }

    /// CHG-01: a workspace that never picked a tab shows Changes, and the pull request pill still picks Checks.
    @Test func aWorkspaceThatNeverPickedATabShowsChanges() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        #expect(model.rightPanelTab(workspaceId: workspace.id) == .changes)
        model.rightPanelTabs[workspace.id] = .checks
        #expect(model.rightPanelTab(workspaceId: workspace.id) == .checks)
    }

    /// REV-01: the pull request's comments are read while the Checks tab shows, not whenever the panel does.
    @Test func commentsAreReadOnlyWhileTheChecksTabShows() async throws {
        let (model, workspace, route) = try await githubWorkspace(Self.answeringComments())
        let commentReads = { route.requests.filter { $0.graphQL?.query.contains("reviewThreads") == true }.count }

        model.visibleRightPanelTab = .changes
        await model.pullRequests.refresh(workspaceId: workspace.id, reason: .button)
        #expect(commentReads() == 0)
        #expect(model.pullRequests.panels[workspace.id]?.comments.isEmpty == true)

        model.visibleRightPanelTab = .checks
        try await waitUntil { model.pullRequests.panels[workspace.id]?.comments.count == 4 }

        // The panel closed: the next refresh reads no comments.
        model.visibleRightPanelTab = nil
        let reads = commentReads()
        await model.pullRequests.refresh(workspaceId: workspace.id, reason: .button)
        #expect(commentReads() == reads)
    }

    /// GIT-05 through the model: the file's changes go, its diff tab closes, and the Changes tab reads the worktree
    /// again.
    @Test func discardClosesTheFilesTabAndRefreshesTheChanges() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        try await write("changed\n", to: "README.md", in: workspace)
        model.visibleRightPanelTab = .changes
        try await waitUntil { model.changes[workspace.id]?.files.map(\.path) == ["README.md"] }
        model.openDiff(workspaceId: workspace.id, path: "README.md")
        #expect(model.selectedChangedFile(workspaceId: workspace.id) == "README.md")

        await model.discardChanges(workspaceId: workspace.id, paths: ["README.md"])

        #expect(model.changes[workspace.id]?.files.isEmpty == true)
        #expect(model.selectedChangedFile(workspaceId: workspace.id) == nil)
        #expect(model.diffTabs[workspace.id]?.isEmpty == true)
        #expect(model.changesFailures[workspace.id] == nil)
        let readme = URL(fileURLWithPath: workspace.path).appendingPathComponent("README.md")
        #expect(try await Task.blocking { try String(contentsOf: readme, encoding: .utf8) }.value == "hello\n")
    }

    // MARK: Diff tabs (DIFF-01, DIFF-05)

    /// DIFF-01: one tab per file, after the file tabs, and at most one of a file tab and a diff tab on screen. A tab
    /// keeps the mode it was left in unless one is asked for; closing it brings the conversation back. The tabs go
    /// with the workspace.
    @Test func aDiffTabIsOnePerFileAndKeepsItsMode() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        model.openFile(workspaceId: workspace.id, path: "/elsewhere/a.png")
        model.openDiff(workspaceId: workspace.id, path: "README.md", mode: .edit)
        model.openDiff(workspaceId: workspace.id, path: "src/b.ts")
        model.openDiff(workspaceId: workspace.id, path: "README.md")
        #expect(model.diffTabs[workspace.id] == ["README.md", "src/b.ts"])
        #expect(model.selectedDiffTabs[workspace.id] == "README.md")
        #expect(model.selectedFiles[workspace.id] == nil)
        #expect(model.diffMode(workspaceId: workspace.id, path: "README.md") == .edit)
        #expect(model.diffMode(workspaceId: workspace.id, path: "src/b.ts") == .diff)

        model.showFile(workspaceId: workspace.id, path: "/elsewhere/a.png")
        #expect(model.selectedDiffTabs[workspace.id] == nil)
        model.showDiff(workspaceId: workspace.id, path: "src/b.ts")
        #expect(model.selectedFiles[workspace.id] == nil)
        #expect(model.selectedChangedFile(workspaceId: workspace.id) == "src/b.ts")

        model.openDiff(workspaceId: workspace.id, path: "README.md", mode: .diff)
        #expect(model.diffMode(workspaceId: workspace.id, path: "README.md") == .diff)
        model.closeDiff(workspaceId: workspace.id, path: "README.md")
        #expect(model.diffTabs[workspace.id] == ["src/b.ts"])
        #expect(model.selectedDiffTabs[workspace.id] == nil)
        #expect(model.selectedFiles[workspace.id] == nil)

        await model.removeWorkspace(id: workspace.id)
        #expect(model.workspace(id: workspace.id) == nil)
        #expect(model.diffTabs[workspace.id] == nil)
    }

    /// GIT-01 with DIFF-01: a diff tab on screen keeps the full diff computed with the panel on Checks, so it follows
    /// the agent; once it closes, a change reads the stats only again.
    @Test func aDiffTabOnScreenKeepsTheFullDiffComputed() async throws {
        let watchers = FakeWatchers()
        let (model, workspace) = try await watchedWorkspace(watchers: watchers)
        model.visibleRightPanelTab = .checks
        try await write("one\n", to: "a.md", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { model.diffStats[workspace.id]?.files == 1 }
        #expect(model.changes[workspace.id] == nil)

        model.openDiff(workspaceId: workspace.id, path: "a.md")
        try await waitUntil { model.changes[workspace.id]?.files.map(\.path) == ["a.md"] }

        try await write("two\n", to: "b.md", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { model.changes[workspace.id]?.files.map(\.path) == ["a.md", "b.md"] }

        model.closeDiff(workspaceId: workspace.id, path: "a.md")
        try await write("three\n", to: "c.md", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { model.diffStats[workspace.id]?.files == 3 }
        #expect(model.changes[workspace.id]?.files.count == 2)
    }

    /// CHG-03's ⌥⌘↓ / ⌥⌘↑ walk the Changes tab's list from the diff tab on screen, opening each file's diff tab.
    @Test func adjacentChangedFilesOpenInDiffTabs() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        try await write("one\n", to: "a.md", in: workspace)
        try await write("two\n", to: "b.md", in: workspace)
        model.visibleRightPanelTab = .changes
        try await waitUntil { model.changes[workspace.id]?.files.map(\.path) == ["a.md", "b.md"] }

        model.showAdjacentChangedFile(workspaceId: workspace.id, step: 1)
        #expect(model.selectedChangedFile(workspaceId: workspace.id) == "a.md")
        model.showAdjacentChangedFile(workspaceId: workspace.id, step: 1)
        #expect(model.selectedChangedFile(workspaceId: workspace.id) == "b.md")
        model.showAdjacentChangedFile(workspaceId: workspace.id, step: 1)
        #expect(model.selectedChangedFile(workspaceId: workspace.id) == "b.md")
        model.showAdjacentChangedFile(workspaceId: workspace.id, step: -1)
        #expect(model.selectedChangedFile(workspaceId: workspace.id) == "a.md")
        #expect(model.diffTabs[workspace.id] == ["a.md", "b.md"])
    }

    /// DIFF-05: a badge of a changed worktree file opens its diff tab on the diff and asks for its first hunk, each
    /// click again. While the changes are not read, a worktree file opens there too; once they are, an unchanged one
    /// opens its worktree tab in Edit (FIL-05), and a file outside the worktree a file tab.
    @Test func aBadgeOfAChangedFileOpensItsDiffTab() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        let readme = URL(fileURLWithPath: workspace.path).appendingPathComponent("README.md").path
        #expect(model.changes[workspace.id] == nil)
        model.openBadgeFile(workspaceId: workspace.id, path: readme)
        #expect(model.selectedDiffTabs[workspace.id] == "README.md")
        // The tab on screen reads the changes, which do not have the file: it stays, showing the file unchanged.
        try await waitUntil { model.changes[workspace.id] != nil }
        model.closeDiff(workspaceId: workspace.id, path: "README.md")

        try await write("draft\n", to: "notes.md", in: workspace)
        model.visibleRightPanelTab = .changes
        await model.refreshChanges(workspaceId: workspace.id)
        #expect(model.changes[workspace.id]?.files.map(\.path) == ["notes.md"])

        let notes = URL(fileURLWithPath: workspace.path).appendingPathComponent("notes.md").path
        model.openDiff(workspaceId: workspace.id, path: "notes.md", mode: .edit)
        let serial = model.diffScrollRequests[workspace.id]?.serial ?? 0
        model.openBadgeFile(workspaceId: workspace.id, path: notes)
        #expect(model.selectedDiffTabs[workspace.id] == "notes.md")
        #expect(model.diffMode(workspaceId: workspace.id, path: "notes.md") == .diff)
        #expect(model.diffScrollRequests[workspace.id] == DiffScrollRequest(path: "notes.md", serial: serial + 1))
        model.openBadgeFile(workspaceId: workspace.id, path: notes)
        #expect(model.diffScrollRequests[workspace.id] == DiffScrollRequest(path: "notes.md", serial: serial + 2))

        model.openBadgeFile(workspaceId: workspace.id, path: readme)
        #expect(model.selectedDiffTabs[workspace.id] == "README.md")
        #expect(model.diffMode(workspaceId: workspace.id, path: "README.md") == .edit)
        #expect((model.openFiles[workspace.id] ?? []).isEmpty)
        model.openBadgeFile(workspaceId: workspace.id, path: "/elsewhere/notes.md")
        #expect(model.selectedFiles[workspace.id] == "/elsewhere/notes.md")
        #expect(model.diffTabs[workspace.id] == ["notes.md", "README.md"])
    }

    // MARK: Line comments (CMT-02, CMT-05, CMT-06)

    /// A comment on README.md's first removed line, with the prompt `ReviewPrompt.single` builds for it.
    private static func lineComment(in workspace: Workspace) -> LineComment {
        let path = AppModel.editorPath(worktree: workspace.path, relativePath: "README.md")
        let prompt = ReviewPrompt.single(path: "README.md", side: .old, start: 1, end: 1, code: ["hello"], language: "md", comment: "Keep the greeting.")
        return LineComment(text: "Keep the greeting.", range: LineRangeAttachment(path: path, side: .old, start: 1, end: 1), prompt: prompt)
    }

    /// CMT-05: a comment goes to a conversation whose tab was never shown: its chat is made and started without
    /// selecting it, the diff stays on screen, and the transcript and the store keep the comment and its entry. A
    /// conversation that is not open takes nothing.
    @Test func aLineCommentGoesToAConversationNotShownWithoutSelectingIt() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, shown) = try await workspaceWithAConversation(store: store)
        let other = ChatSessionRecord(workspaceId: workspace.id, agent: AgentKind.claude.rawValue)
        try store.add(other)
        await model.showConversations(workspace: workspace)
        #expect(model.conversations[workspace.id]?.contains { $0.id == other.id } == true)
        #expect(model.chat(conversationId: other.id) == nil)
        model.openDiff(workspaceId: workspace.id, path: "README.md")
        let selected = model.selectedConversationIds[workspace.id]
        let comment = Self.lineComment(in: workspace)

        #expect(await model.sendLineComment(workspaceId: workspace.id, conversationId: "missing", comment: comment) == .unavailable)
        #expect(await model.sendLineComment(workspaceId: workspace.id, conversationId: other.id, comment: comment) == .sent)
        let chat = try #require(model.chat(conversationId: other.id))
        try await answerNextPermission(chat)
        try await waitUntil { chat.state == .ready && chat.items.contains { $0.kind == .user } }

        let sent = try #require(chat.items.first { $0.kind == .user })
        #expect(sent.text == comment.text)
        #expect(sent.lineRange == comment.range)
        #expect(try store.messages(sessionId: other.id).first?.attachments == [comment.range.entry])
        #expect(model.selectedConversationIds[workspace.id] == selected)
        #expect(model.existingChat(workspaceId: workspace.id) === shown)
        #expect(model.selectedDiffTabs[workspace.id] == "README.md")
        #expect(shown.items.allSatisfy { $0.lineRange == nil })
        await model.stopAllAgents()
    }

    /// CMT-05's Queue: while the conversation's turn runs the comment waits in its queue, then goes after the turn.
    @Test func aLineCommentQueuesWhileTheTurnRuns() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, chat) = try await workspaceWithAConversation(store: store)
        let conversationId = try #require(model.selectedConversationIds[workspace.id])
        let comment = Self.lineComment(in: workspace)
        async let turn: Void = chat.send("a long task")
        try await waitUntil { chat.pendingPermission != nil }

        #expect(await model.sendLineComment(workspaceId: workspace.id, conversationId: conversationId, comment: comment) == .queued)
        #expect(chat.queue.map(\.lineComment) == [comment])
        chat.answerPermission(optionId: "allow")
        await turn
        try await answerNextPermission(chat)
        try await waitUntil { chat.state == .ready && chat.queue.isEmpty && chat.items.last { $0.kind == .user }?.lineRange == comment.range }
        await model.stopAllAgents()
    }

    /// CMT-05: a stopped conversation starts again, and the comment goes to it.
    @Test func aLineCommentStartsAStoppedConversation() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, chat) = try await workspaceWithAConversation(store: store)
        let conversationId = try #require(model.selectedConversationIds[workspace.id])
        await chat.stop()
        #expect(chat.state == .stopped("Stopped"))
        let comment = Self.lineComment(in: workspace)

        #expect(await model.sendLineComment(workspaceId: workspace.id, conversationId: conversationId, comment: comment) == .sent)
        try await answerNextPermission(chat)
        try await waitUntil { chat.state == .ready && chat.items.last { $0.kind == .user }?.lineRange == comment.range }
        await model.stopAllAgents()
    }

    /// CMT-05 Resend: the block is built again from the chip's lines as they are now: the new side from the worktree
    /// file, the removed side from the base, whether the changes are read (their base) or not (the base found then).
    @Test func aResentCommentReadsTheNewSideFromTheWorktreeAndTheRemovedSideFromTheBase() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        try await write("hi there\nsecond\n", to: "README.md", in: workspace)
        let path = AppModel.editorPath(worktree: workspace.path, relativePath: "README.md")
        let language = ReviewPrompt.fenceLanguage(forPath: "README.md")
        let new = LineRangeAttachment(path: path, side: .new, start: 1, end: 2)
        let removed = LineRangeAttachment(path: path, side: .old, start: 1, end: 1)

        let fromWorktree = await model.lineComment(for: new, comment: "Why?", workspaceId: workspace.id)
        #expect(fromWorktree == LineComment(
            text: "Why?",
            range: new,
            prompt: ReviewPrompt.single(path: "README.md", side: .new, start: 1, end: 2, code: ["hi there", "second"], language: language, comment: "Why?")
        ))
        let removedPrompt = ReviewPrompt.single(path: "README.md", side: .old, start: 1, end: 1, code: ["hello"], language: language, comment: "Keep it?")
        #expect(model.changes[workspace.id] == nil)
        #expect(await model.lineComment(for: removed, comment: "Keep it?", workspaceId: workspace.id).prompt == removedPrompt)
        model.visibleRightPanelTab = .changes
        await model.refreshChanges(workspaceId: workspace.id)
        #expect(model.changes[workspace.id]?.files.map(\.path) == ["README.md"])
        #expect(await model.lineComment(for: removed, comment: "Keep it?", workspaceId: workspace.id).prompt == removedPrompt)

        // Files attached next to the chip travel with the comment and are named in its block.
        let shot = URL(fileURLWithPath: "/tmp/shot.png")
        let withFile = await model.lineComment(for: new, comment: "Like \(PromptAttachment.marker)?", files: [shot], workspaceId: workspace.id)
        #expect(withFile.files == [shot])
        #expect(withFile.text == "Like \(PromptAttachment.marker)?")
        #expect(withFile.prompt.hasSuffix("```\nLike shot.png?"))
    }

    /// CMT-05 Resend, all or nothing: a range past the end of the file, on either side, or a file that is gone, gives
    /// the block without code.
    @Test func aRangePastTheEndOfTheFileGivesTheBlockWithoutCode() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        try await write("hi there\nsecond\n", to: "README.md", in: workspace)
        let path = AppModel.editorPath(worktree: workspace.path, relativePath: "README.md")

        let pastTheEnd = LineRangeAttachment(path: path, side: .new, start: 2, end: 5)
        #expect(await model.lineComment(for: pastTheEnd, comment: "Why?", workspaceId: workspace.id).prompt
            == "Comment on README.md, lines 2–5:\nWhy?")
        let pastTheBase = LineRangeAttachment(path: path, side: .old, start: 1, end: 3)
        #expect(await model.lineComment(for: pastTheBase, comment: "Why?", workspaceId: workspace.id).prompt
            == "Comment on README.md, removed lines 1–3 (from the base):\nWhy?")
        let gone = LineRangeAttachment(path: AppModel.editorPath(worktree: workspace.path, relativePath: "gone.ts"), side: .new, start: 1, end: 1)
        #expect(await model.lineComment(for: gone, comment: "Why?", workspaceId: workspace.id).prompt == "Comment on gone.ts, line 1:\nWhy?")
        let neverInTheBase = LineRangeAttachment(path: gone.path, side: .old, start: 1, end: 1)
        #expect(await model.lineComment(for: neverInTheBase, comment: "Why?", workspaceId: workspace.id).prompt
            == "Comment on gone.ts, removed line 1 (from the base):\nWhy?")
    }

    /// CMT-05 Resend: a comment the message box sends again shows its chip and its text in the transcript, like the
    /// comment box's, and the agent gets the block read now.
    @Test func aResentCommentShowsItsChipAndItsText() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, chat) = try await workspaceWithAConversation(store: store)
        let range = Self.lineComment(in: workspace).range
        let comment = await model.lineComment(for: range, comment: "Keep the greeting.", workspaceId: workspace.id)
        #expect(comment == Self.lineComment(in: workspace))

        async let sending: Void = chat.send(comment)
        try await answerNextPermission(chat)
        await sending
        let sent = try #require(chat.items.last { $0.kind == .user })
        #expect(sent.text == "Keep the greeting.")
        #expect(sent.lineRange == range)
        let conversationId = try #require(model.selectedConversationIds[workspace.id])
        #expect(try store.messages(sessionId: conversationId).last { $0.kind == ChatItem.Kind.user.rawValue }?.attachments == [range.entry])
        await model.stopAllAgents()
    }

    /// CMT-06: a chip of a changed file opens its diff tab on the diff with its first line to scroll to, until the tab
    /// has scrolled there; one of a file no longer changed opens its worktree tab in Edit, and scrolls nothing.
    @Test func aChipOpensTheDiffAtItsLineOrTheUnchangedFilesTab() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        try await write("draft\n", to: "notes.md", in: workspace)
        model.visibleRightPanelTab = .changes
        await model.refreshChanges(workspaceId: workspace.id)
        #expect(model.changes[workspace.id]?.files.map(\.path) == ["notes.md"])

        let notes = LineRangeAttachment(path: AppModel.editorPath(worktree: workspace.path, relativePath: "notes.md"), side: .new, start: 1, end: 1)
        model.openLineRange(workspaceId: workspace.id, attachment: notes)
        #expect(model.selectedDiffTabs[workspace.id] == "notes.md")
        #expect(model.diffMode(workspaceId: workspace.id, path: "notes.md") == .diff)
        let request = try #require(model.diffScrollRequests[workspace.id])
        #expect(request.path == "notes.md")
        #expect(request.line == CommentLine(side: .new, number: 1))
        #expect(model.handledLineScrolls[workspace.id] == nil)
        model.lineScrollHandled(workspaceId: workspace.id, serial: request.serial - 1)
        #expect(model.handledLineScrolls[workspace.id] == nil)
        model.lineScrollHandled(workspaceId: workspace.id, serial: request.serial)
        #expect(model.handledLineScrolls[workspace.id] == request.serial)
        // The request keeps its line, so it never reads as a badge's first-hunk request.
        #expect(model.diffScrollRequests[workspace.id] == request)

        let readme = LineRangeAttachment(path: AppModel.editorPath(worktree: workspace.path, relativePath: "README.md"), side: .old, start: 1, end: 1)
        model.openLineRange(workspaceId: workspace.id, attachment: readme)
        #expect(model.selectedDiffTabs[workspace.id] == "README.md")
        #expect(model.diffMode(workspaceId: workspace.id, path: "README.md") == .edit)
        #expect(model.diffScrollRequests[workspace.id]?.path == "notes.md")
        #expect((model.openFiles[workspace.id] ?? []).isEmpty)
    }

    /// CMT-02: a diff tab's box stays in the model while the tab is open, across tab switches, keeps its text on
    /// another range of the file, sends to the picked conversation while it is open (else the one shown), keeps a
    /// preview tab, and goes with its tab.
    @Test func aCommentBoxStaysWithItsTabAndGoesWhenItCloses() async throws {
        let store = try RockyStore.inMemory()
        let (model, workspace, _) = try await workspaceWithAConversation(store: store)
        let first = try #require(model.selectedConversationIds[workspace.id])
        #expect(model.openCommentDraft(workspaceId: workspace.id, path: "README.md", side: .new, lines: 1...1) == nil)
        model.openFromTree(workspaceId: workspace.id, path: "README.md", keep: false)
        #expect(model.previewTabs[workspace.id] == "README.md")

        let draft = try #require(model.openCommentDraft(workspaceId: workspace.id, path: "README.md", side: .new, lines: 2...4))
        #expect(model.previewTabs[workspace.id] == nil)
        draft.text = "Rename this."
        #expect(model.commentConversation(for: draft, workspaceId: workspace.id)?.id == first)

        _ = try #require(await model.newConversation(workspace: workspace, agent: .claude))
        let second = try #require(model.selectedConversationIds[workspace.id])
        #expect(second != first)
        #expect(model.commentConversation(for: draft, workspaceId: workspace.id)?.id == second)
        draft.conversationId = first
        #expect(model.commentConversation(for: draft, workspaceId: workspace.id)?.id == first)

        model.showDiff(workspaceId: workspace.id, path: "README.md")
        #expect(model.commentDraft(workspaceId: workspace.id, path: "README.md") === draft)
        #expect(model.openCommentDraft(workspaceId: workspace.id, path: "README.md", side: .old, lines: 1...1) === draft)
        #expect(draft.side == .old)
        #expect(draft.lines == 1...1)
        #expect(draft.text == "Rename this.")

        await model.closeConversation(workspace: workspace, conversationId: first)
        #expect(model.commentConversation(for: draft, workspaceId: workspace.id)?.id == second)
        model.dropCommentDraft(workspaceId: workspace.id, path: "README.md")
        #expect(model.commentDraft(workspaceId: workspace.id, path: "README.md") == nil)
        model.openCommentDraft(workspaceId: workspace.id, path: "README.md", side: .new, lines: 1...1)
        model.closeDiff(workspaceId: workspace.id, path: "README.md")
        #expect(model.commentDraft(workspaceId: workspace.id, path: "README.md") == nil)
        await model.stopAllAgents()
    }

    // MARK: Editing (EDIT-01…EDIT-04)

    private func read(_ path: String, in workspace: Workspace) async throws -> String {
        let file = URL(fileURLWithPath: workspace.path).appendingPathComponent(path)
        return try await Task.blocking { try String(contentsOf: file, encoding: .utf8) }.value
    }

    /// A workspace whose README.md is open in its diff tab's editor, read.
    private func editingReadme(watchers: FakeWatchers = FakeWatchers()) async throws -> (AppModel, Workspace, String) {
        let (model, workspace) = try await watchedWorkspace(watchers: watchers)
        let readme = AppModel.editorPath(worktree: workspace.path, relativePath: "README.md")
        model.openDiff(workspaceId: workspace.id, path: "README.md", mode: .edit)
        await model.openEditor(workspaceId: workspace.id, path: readme)
        #expect(model.editor(workspaceId: workspace.id, path: readme)?.document?.buffer.text == "hello\n")
        return (model, workspace, readme)
    }

    /// EDIT-03 through the model: a change on disk reloads a clean editor, which says "Reloaded"; under unsaved edits
    /// the edits stay and the conflict shows, until Reload takes the file's version.
    @Test func aCleanEditorReloadsAndADirtyOneConflicts() async throws {
        let watchers = FakeWatchers()
        let (model, workspace, readme) = try await editingReadme(watchers: watchers)
        let document = { model.editor(workspaceId: workspace.id, path: readme)?.document }

        try await write("hello agent\n", to: "README.md", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { document()?.buffer.text == "hello agent\n" }
        #expect(document()?.reloadedAt != nil)
        #expect(!model.isEditorDirty(workspaceId: workspace.id, path: readme))

        model.setEditorText("hello mine\n", workspaceId: workspace.id, path: readme)
        #expect(model.isEditorDirty(workspaceId: workspace.id, path: readme))
        try await write("hello again\n", to: "README.md", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { document()?.buffer.conflict == true }
        #expect(document()?.buffer.text == "hello mine\n")
        #expect(document()?.buffer.disk?.text == "hello again\n")

        model.reloadEditor(workspaceId: workspace.id, path: readme)
        #expect(document()?.buffer.text == "hello again\n")
        #expect(document()?.buffer.conflict == false)
        #expect(!model.isEditorDirty(workspaceId: workspace.id, path: readme))
    }

    /// Review Focus 3: a save never overwrites a version of the file the editor has not seen, even before its event
    /// arrives. It writes nothing and shows the conflict; Keep Mine lets the next save through.
    @Test func aSaveNeverOverwritesAChangeItHasNotSeenUntilKeepMine() async throws {
        let (model, workspace, readme) = try await editingReadme()
        model.setEditorText("hello mine\n", workspaceId: workspace.id, path: readme)
        try await write("hello agent\n", to: "README.md", in: workspace)

        #expect(await model.saveEditor(workspaceId: workspace.id, path: readme) == false)
        #expect(try await read("README.md", in: workspace) == "hello agent\n")
        let conflicted = try #require(model.editor(workspaceId: workspace.id, path: readme)?.document)
        #expect(conflicted.buffer.conflict)
        #expect(conflicted.buffer.text == "hello mine\n")

        model.keepMine(workspaceId: workspace.id, path: readme)
        #expect(await model.saveEditor(workspaceId: workspace.id, path: readme))
        #expect(try await read("README.md", in: workspace) == "hello mine\n")
        #expect(!model.isEditorDirty(workspaceId: workspace.id, path: readme))
        #expect(model.editor(workspaceId: workspace.id, path: readme)?.document?.buffer.keepsMine == false)
    }

    /// EDIT-02 and EDIT-04: an unchanged file's change bars compare with the file at the base, and saving an edit writes
    /// the file and brings it into Changes, with the same base. A file the base lacks compares with nothing.
    @Test func savingAnUnchangedFileBringsItIntoChanges() async throws {
        let (model, workspace, readme) = try await editingReadme()
        try await waitUntil { model.changes[workspace.id] != nil }
        #expect(model.changes[workspace.id]?.file(at: "README.md") == nil)
        await model.loadEditorBase(workspaceId: workspace.id, relativePath: "README.md")
        #expect(model.editorBaseText(workspaceId: workspace.id, relativePath: "README.md") == "hello\n")

        model.setEditorText("hello\nworld\n", workspaceId: workspace.id, path: readme)
        #expect(await model.saveEditor(workspaceId: workspace.id, path: readme))
        #expect(!model.isEditorDirty(workspaceId: workspace.id, path: readme))
        #expect(try await read("README.md", in: workspace) == "hello\nworld\n")
        try await waitUntil { model.changes[workspace.id]?.file(at: "README.md")?.status == .modified }
        #expect(model.editorBaseText(workspaceId: workspace.id, relativePath: "README.md") == "hello\n")

        try await write("draft\n", to: "notes.md", in: workspace)
        await model.refreshChanges(workspaceId: workspace.id)
        model.openDiff(workspaceId: workspace.id, path: "notes.md", mode: .edit)
        await model.loadEditorBase(workspaceId: workspace.id, relativePath: "notes.md")
        #expect(model.editorBaseText(workspaceId: workspace.id, relativePath: "notes.md") == "")
    }

    /// One buffer per file: a file tab and a diff tab of the same file share it, and it goes with the last tab of the
    /// file, unsaved edits included (the tab asked first). The file on disk is untouched.
    @Test func anEditorGoesWithTheLastTabOfItsFile() async throws {
        let (model, workspace, readme) = try await editingReadme()
        model.openFile(workspaceId: workspace.id, path: readme)
        model.setEditorText("edited\n", workspaceId: workspace.id, path: readme)

        model.closeFile(workspaceId: workspace.id, path: readme)
        #expect(model.isEditorDirty(workspaceId: workspace.id, path: readme))
        model.closeDiff(workspaceId: workspace.id, path: "README.md")
        #expect(model.editor(workspaceId: workspace.id, path: readme) == nil)
        #expect(try await read("README.md", in: workspace) == "hello\n")
    }

    /// EDIT-03: a file that was missing when its tab opened is read once it appears; FIL-06's large text opens
    /// read-only and takes no typing.
    @Test func aMissingFileIsReadWhenItAppearsAndALargeOneIsReadOnly() async throws {
        let watchers = FakeWatchers()
        let (model, workspace) = try await watchedWorkspace(watchers: watchers)
        let later = AppModel.editorPath(worktree: workspace.path, relativePath: "later.md")
        model.openDiff(workspaceId: workspace.id, path: "later.md", mode: .edit)
        await model.openEditor(workspaceId: workspace.id, path: later)
        #expect(model.editor(workspaceId: workspace.id, path: later) == .missing)

        try await write("here now\n", to: "later.md", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { model.editor(workspaceId: workspace.id, path: later)?.document?.buffer.text == "here now\n" }

        let large = AppModel.editorPath(worktree: workspace.path, relativePath: "large.log")
        try await write(String(repeating: "a", count: TextFile.editableLimit + 1), to: "large.log", in: workspace)
        model.openDiff(workspaceId: workspace.id, path: "large.log", mode: .edit)
        await model.openEditor(workspaceId: workspace.id, path: large)
        #expect(model.editor(workspaceId: workspace.id, path: large)?.document?.isReadOnly == true)
        model.setEditorText("b", workspaceId: workspace.id, path: large)
        #expect(!model.isEditorDirty(workspaceId: workspace.id, path: large))
        #expect(await model.saveEditor(workspaceId: workspace.id, path: large) == false)
    }

    /// KBD-02's File ▸ Save: the file on screen, while it has unsaved edits. A tab without an editor on screen saves
    /// nothing, and the file keeps its edits for its own tab.
    @Test func saveWritesTheFileOnScreen() async throws {
        let (model, workspace, readme) = try await editingReadme()
        #expect(model.visibleEditorPath(workspaceId: workspace.id) == readme)
        #expect(!model.canSaveVisibleEditor(workspaceId: workspace.id))
        model.setEditorText("hello saved\n", workspaceId: workspace.id, path: readme)
        #expect(model.canSaveVisibleEditor(workspaceId: workspace.id))

        model.openFile(workspaceId: workspace.id, path: "/elsewhere/a.png")
        #expect(!model.canSaveVisibleEditor(workspaceId: workspace.id))
        #expect(await model.saveVisibleEditor(workspaceId: workspace.id) == false)
        #expect(try await read("README.md", in: workspace) == "hello\n")

        model.showDiff(workspaceId: workspace.id, path: "README.md")
        #expect(await model.saveVisibleEditor(workspaceId: workspace.id))
        #expect(try await read("README.md", in: workspace) == "hello saved\n")
        #expect(!model.canSaveVisibleEditor(workspaceId: workspace.id))
    }

    /// EDIT-02 on quit: every file with unsaved edits is listed; Save All writes them, and a file that changed on disk
    /// under its edits stays unsaved, with its conflict, for its tab to show.
    @Test func saveAllWritesEveryUnsavedFileAndKeepsTheOnesThatChangedOnDisk() async throws {
        let (model, workspace, readme) = try await editingReadme()
        let notes = AppModel.editorPath(worktree: workspace.path, relativePath: "notes.md")
        try await write("notes\n", to: "notes.md", in: workspace)
        model.openDiff(workspaceId: workspace.id, path: "notes.md", mode: .edit)
        await model.openEditor(workspaceId: workspace.id, path: notes)
        #expect(model.unsavedEditors().isEmpty)

        model.setEditorText("hello mine\n", workspaceId: workspace.id, path: readme)
        model.setEditorText("notes mine\n", workspaceId: workspace.id, path: notes)
        let unsaved = model.unsavedEditors()
        #expect(unsaved.map(\.file) == ["README.md", "notes.md"])
        #expect(unsaved.map(\.path) == [readme, notes])
        #expect(model.unsavedEditors(workspaceId: "another").isEmpty)

        // The agent wrote notes.md meanwhile: its save stops at the conflict and writes nothing.
        try await write("notes agent\n", to: "notes.md", in: workspace)
        let left = await model.saveEditors(unsaved)

        #expect(left.map(\.file) == ["notes.md"])
        #expect(try await read("README.md", in: workspace) == "hello mine\n")
        #expect(try await read("notes.md", in: workspace) == "notes agent\n")
        #expect(model.editor(workspaceId: workspace.id, path: notes)?.document?.buffer.conflict == true)
        #expect(model.unsavedEditors().map(\.file) == ["notes.md"])

        model.showDiff(workspaceId: workspace.id, path: "README.md")
        model.showUnsavedEditor(try #require(left.first))
        #expect(model.selectedWorkspaceId == workspace.id)
        #expect(model.selectedDiffTabs[workspace.id] == "notes.md")
    }

    // MARK: Commit (GIT-04, ERR-02)

    /// GIT-04 through the model: every change is committed with the subject trimmed and no empty body, the sheet's
    /// state goes, the toast says so, and the Changes tab has nothing uncommitted left.
    @Test func commitCommitsEveryChangeAndLeavesNoSheet() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        var toasts: [String] = []
        model.onToast = { toasts.append($0) }
        try await write("changed\n", to: "README.md", in: workspace)
        try await write("new\n", to: "new.txt", in: workspace)
        model.visibleRightPanelTab = .changes
        try await waitUntil { model.changes[workspace.id]?.uncommitted.count == 2 }

        #expect(await model.commitChanges(workspaceId: workspace.id, subject: "  Update the readme  ", description: " "))

        #expect(model.commits[workspace.id] == nil)
        #expect(toasts == ["Committed"])
        #expect(model.changes[workspace.id]?.uncommitted.isEmpty == true)
        #expect(model.changes[workspace.id]?.committed.map(\.path) == ["README.md", "new.txt"])
        let worktree = URL(fileURLWithPath: workspace.path)
        #expect(try await GitFixture.gitOffMain(["log", "-1", "--format=%B"], in: worktree) == "Update the readme")
    }

    /// ERR-02: a hook that refuses leaves the sheet's state: the message, the hook's output and git's exit status,
    /// until the sheet closes. Nothing is committed, and an empty subject never reaches git.
    @Test func aFailedCommitKeepsItsMessageAndOutputForTheSheet() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        let repo = try #require(model.repo(id: workspace.repoId))
        // A worktree's hooks are its repository's.
        let hook = URL(fileURLWithPath: repo.path).appendingPathComponent(".git/hooks/pre-commit")
        try await Task.blocking {
            try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho 'lint failed: README.md' >&2\nexit 1\n".utf8).write(to: hook)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        }.value
        try await write("changed\n", to: "README.md", in: workspace)

        #expect(await model.commitChanges(workspaceId: workspace.id, subject: "   ", description: "") == false)
        #expect(model.commits[workspace.id] == nil)

        #expect(await model.commitChanges(workspaceId: workspace.id, subject: "Edit", description: "Why") == false)

        let progress = try #require(model.commits[workspace.id])
        #expect(progress.subject == "Edit")
        #expect(progress.description == "Why")
        #expect(progress.lines == ["lint failed: README.md"])
        #expect(progress.failure == "git commit exited 1")
        #expect(!progress.isRunning)
        let worktree = URL(fileURLWithPath: workspace.path)
        #expect(try await GitFixture.gitOffMain(["log", "--format=%s"], in: worktree) == "init")

        model.dismissCommit(workspaceId: workspace.id)
        #expect(model.commits[workspace.id] == nil)
    }

    // MARK: All files (FIL-01…FIL-07)

    /// Writes `text` to `path` in the worktree, creating its folders.
    private func writeFile(_ text: String, to path: String, in workspace: Workspace) async throws {
        let file = URL(fileURLWithPath: workspace.path).appendingPathComponent(path)
        try await Task.blocking {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }.value
    }

    private func folderPath(_ folder: String, in workspace: Workspace) -> String {
        URL(fileURLWithPath: workspace.path).appendingPathComponent(folder).path
    }

    /// FIL-07 (Review Focus 1 and 6): with the All files tab hidden, events read no file list and no folder. The tab
    /// reads git's list and the root when it first shows, nothing when it shows again with nothing changed, and a
    /// workspace that is not selected keeps nothing and reads nothing.
    @Test func hiddenFilesTabRunsNoGit() async throws {
        let watchers = FakeWatchers()
        let files = FakeWorktreeFiles()
        let (model, workspace) = try await watchedWorkspace(watchers: watchers, files: files)
        model.visibleRightPanelTab = .changes
        try await writeFile("one\n", to: "src/a.ts", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { model.diffStats[workspace.id]?.files == 1 }
        #expect(files.listCount == 0)
        #expect(files.listedFolders.isEmpty)
        #expect(model.fileTrees[workspace.id] == nil)

        model.visibleRightPanelTab = .files
        try await waitUntil { model.fileTrees[workspace.id]?.list != nil && model.fileTrees[workspace.id]?.listings[""] != nil }
        #expect(files.listCount == 1)
        #expect(files.listedFolders == [""])
        #expect(model.fileTrees[workspace.id]?.list?.paths == ["README.md", "src/a.ts"])

        model.visibleRightPanelTab = .checks
        model.visibleRightPanelTab = .files
        await model.refreshFiles(workspaceId: workspace.id)
        #expect(files.listCount == 1)
        #expect(files.listedFolders == [""])

        model.selectedWorkspaceId = nil
        #expect(model.fileTrees[workspace.id] == nil)
        try await writeFile("two\n", to: "src/b.ts", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { model.diffStats[workspace.id]?.files == 2 }
        #expect(files.listCount == 1)
        #expect(files.listedFolders == [""])
    }

    /// FIL-07 (Review Focus 6): an event while the tab shows reads git's list and, of the folders, only the expanded
    /// one it names; one naming a collapsed folder only drops that folder's listing.
    @Test func anEventReReadsOnlyTheExpandedFolderItNames() async throws {
        let watchers = FakeWatchers()
        let files = FakeWorktreeFiles()
        let (model, workspace) = try await watchedWorkspace(watchers: watchers, files: files)
        try await writeFile("a\n", to: "src/a.ts", in: workspace)
        try await writeFile("x\n", to: "docs/x.md", in: workspace)
        let tree = { model.fileTrees[workspace.id] }
        model.visibleRightPanelTab = .files
        try await waitUntil { tree()?.listings[""]?.contains { $0.name == "src" } == true }
        model.setFolder("src", expanded: true, workspaceId: workspace.id)
        model.setFolder("docs", expanded: true, workspaceId: workspace.id)
        try await waitUntil { tree()?.listings["src"] != nil && tree()?.listings["docs"] != nil }
        await model.refreshFiles(workspaceId: workspace.id)
        files.reset()

        try await writeFile("b\n", to: "src/b.ts", in: workspace)
        watchers.fire(workspace.path, folders: [folderPath("src", in: workspace)])
        try await waitUntil { tree()?.listings["src"]?.map(\.name) == ["a.ts", "b.ts"] }
        await model.refreshFiles(workspaceId: workspace.id)
        #expect(files.listedFolders == ["src"])
        #expect(files.listCount == 1)
        #expect(tree()?.list?.paths.contains("src/b.ts") == true)

        model.setFolder("docs", expanded: false, workspaceId: workspace.id)
        files.reset()
        watchers.fire(workspace.path, folders: [folderPath("docs", in: workspace)])
        try await waitUntil { tree()?.listings["docs"] == nil }
        await model.refreshFiles(workspaceId: workspace.id)
        #expect(files.listedFolders.isEmpty)
        #expect(files.listCount == 1)
        #expect(tree()?.expanded == ["src"])
    }

    /// FIL-07: events while the tab is hidden only mark what they name; showing the tab reads it then, once.
    @Test func eventsWhileHiddenAreReadWhenTheTabShows() async throws {
        let watchers = FakeWatchers()
        let files = FakeWorktreeFiles()
        let (model, workspace) = try await watchedWorkspace(watchers: watchers, files: files)
        try await writeFile("a\n", to: "src/a.ts", in: workspace)
        let tree = { model.fileTrees[workspace.id] }
        model.visibleRightPanelTab = .files
        try await waitUntil { tree()?.listings[""]?.contains { $0.name == "src" } == true }
        model.setFolder("src", expanded: true, workspaceId: workspace.id)
        try await waitUntil { tree()?.listings["src"] != nil }
        await model.refreshFiles(workspaceId: workspace.id)

        model.visibleRightPanelTab = .changes
        files.reset()
        try await writeFile("b\n", to: "src/b.ts", in: workspace)
        watchers.fire(workspace.path, folders: [folderPath("src", in: workspace)])
        try await waitUntil { model.diffStats[workspace.id]?.files == 2 }
        #expect(files.listCount == 0)
        #expect(files.listedFolders.isEmpty)
        #expect(tree()?.listings["src"]?.map(\.name) == ["a.ts"])

        model.visibleRightPanelTab = .files
        try await waitUntil { tree()?.listings["src"]?.map(\.name) == ["a.ts", "b.ts"] }
        await model.refreshFiles(workspaceId: workspace.id)
        #expect(files.listCount == 1)
        #expect(files.listedFolders == ["src"])
    }

    /// FIL-01: the expanded folders are stored per workspace, come back after a relaunch, and Collapse All Folders
    /// empties them.
    @Test func expandedFoldersSurviveRelaunch() async throws {
        let store = try RockyStore.inMemory()
        let first = try makeModel(store: store)
        await first.bootstrap()
        await first.addRepo(at: try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos")))
        let repoId = try #require(first.repos.first?.id)
        await first.createWorkspace(repoId: repoId)
        let workspace = try #require(first.workspaces[repoId]?.first)
        try await writeFile("a\n", to: "src/a.ts", in: workspace)
        // The first time, only the top level shows.
        first.visibleRightPanelTab = .files
        try await waitUntil { first.fileTrees[workspace.id]?.listings[""] != nil }
        #expect(first.fileTrees[workspace.id]?.expanded.isEmpty == true)
        first.setFolder("src", expanded: true, workspaceId: workspace.id)
        #expect(try store.expandedFolders(workspaceId: workspace.id) == ["src"])

        let files = FakeWorktreeFiles()
        let relaunched = try makeModel(store: store, worktreeFiles: files)
        await relaunched.bootstrap()
        relaunched.selectedWorkspaceId = workspace.id
        relaunched.visibleRightPanelTab = .files
        try await waitUntil { relaunched.fileTrees[workspace.id]?.listings["src"]?.map(\.name) == ["a.ts"] }
        #expect(relaunched.fileTrees[workspace.id]?.expanded == ["src"])
        #expect(Set(files.listedFolders) == ["", "src"])

        relaunched.collapseAllFolders(workspaceId: workspace.id)
        #expect(relaunched.fileTrees[workspace.id]?.expanded.isEmpty == true)
        #expect(try store.expandedFolders(workspaceId: workspace.id).isEmpty)
    }

    /// FIL-03: Show Ignored Files is stored per repository, column only, so another setting's save keeps it, and the
    /// workspaces of that repository show their ignored entries.
    @Test func showIgnoredFilesIsRememberedPerRepository() async throws {
        let store = try RockyStore.inMemory()
        let model = try makeModel(store: store)
        await model.bootstrap()
        let parent = try Fixtures.temporaryDirectory("repos")
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: parent, name: "one"))
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: parent, name: "two"))
        let one = try #require(model.repos.first { $0.name == "one" })
        let two = try #require(model.repos.first { $0.name == "two" })
        #expect(!one.showsIgnoredFiles)

        model.setShowsIgnoredFiles(true, repoId: one.id)
        model.setLinkedPaths(repoId: one.id, ".env.local")
        #expect(model.repo(id: one.id)?.showsIgnoredFiles == true)
        #expect(model.repo(id: two.id)?.showsIgnoredFiles == false)

        let relaunched = try makeModel(store: store)
        await relaunched.bootstrap()
        #expect(relaunched.repo(id: one.id)?.showsIgnoredFiles == true)
        #expect(relaunched.repo(id: two.id)?.showsIgnoredFiles == false)
        #expect(relaunched.repo(id: one.id)?.linkedPaths == ".env.local")

        await relaunched.createWorkspace(repoId: one.id)
        let workspace = try #require(relaunched.workspaces[one.id]?.first)
        #expect(relaunched.showsIgnoredFiles(workspaceId: workspace.id))
        try await writeFile("dist/\n", to: ".gitignore", in: workspace)
        try await writeFile("built\n", to: "dist/out.js", in: workspace)
        relaunched.visibleRightPanelTab = .files
        try await waitUntil { relaunched.fileTrees[workspace.id]?.list != nil && relaunched.fileTrees[workspace.id]?.listings[""] != nil }
        let state = try #require(relaunched.fileTrees[workspace.id])
        let list = try #require(state.list)
        let rows = FileTree.rows(listings: state.listings, expanded: state.expanded, list: list, showsIgnored: true)
        #expect(rows.first { $0.path == "dist" }?.isIgnored == true)
        #expect(rows.first { $0.path == ".gitignore" }?.isIgnored == false)
    }

    // MARK: Opening files (FIL-05)

    /// FIL-05 (Review Focus 8): a single click in the tree opens the workspace's one preview tab, in place of the
    /// last preview; a kept tab is only shown; the Changes tab's open keeps the preview of its file; closing the preview
    /// forgets it.
    @Test func aSingleClickReplacesThePreviewTab() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        model.openDiff(workspaceId: workspace.id, path: "kept.md")
        model.openFromTree(workspaceId: workspace.id, path: "a.md", keep: false)
        #expect(model.diffTabs[workspace.id] == ["kept.md", "a.md"])
        #expect(model.previewTabs[workspace.id] == "a.md")

        model.openFromTree(workspaceId: workspace.id, path: "b.md", keep: false)
        #expect(model.diffTabs[workspace.id] == ["kept.md", "b.md"])
        #expect(model.previewTabs[workspace.id] == "b.md")
        #expect(model.selectedDiffTabs[workspace.id] == "b.md")

        model.openFromTree(workspaceId: workspace.id, path: "kept.md", keep: false)
        #expect(model.diffTabs[workspace.id] == ["kept.md", "b.md"])
        #expect(model.previewTabs[workspace.id] == "b.md")
        #expect(model.selectedDiffTabs[workspace.id] == "kept.md")

        model.openDiff(workspaceId: workspace.id, path: "b.md")
        #expect(model.previewTabs[workspace.id] == nil)
        model.openFromTree(workspaceId: workspace.id, path: "c.md", keep: false)
        #expect(model.diffTabs[workspace.id] == ["kept.md", "b.md", "c.md"])
        model.closeDiff(workspaceId: workspace.id, path: "c.md")
        #expect(model.previewTabs[workspace.id] == nil)
    }

    /// FIL-05: a double-click on the row (its second click) or on the preview tab keeps it; a double-click on another
    /// row (its first click, then its second) replaces the preview with a kept tab.
    @Test func aDoubleClickKeepsThePreview() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        model.openFromTree(workspaceId: workspace.id, path: "a.md", keep: false)
        model.openFromTree(workspaceId: workspace.id, path: "a.md", keep: true)
        #expect(model.previewTabs[workspace.id] == nil)
        model.openFromTree(workspaceId: workspace.id, path: "b.md", keep: false)
        #expect(model.diffTabs[workspace.id] == ["a.md", "b.md"])

        model.keepPreview(workspaceId: workspace.id)
        #expect(model.previewTabs[workspace.id] == nil)
        model.openFromTree(workspaceId: workspace.id, path: "c.md", keep: false)
        #expect(model.diffTabs[workspace.id] == ["a.md", "b.md", "c.md"])

        model.openFromTree(workspaceId: workspace.id, path: "d.md", keep: false)
        model.openFromTree(workspaceId: workspace.id, path: "d.md", keep: true)
        #expect(model.diffTabs[workspace.id] == ["a.md", "b.md", "d.md"])
        #expect(model.previewTabs[workspace.id] == nil)
    }

    /// FIL-05 (Review Focus 8) with FIL-08: a file opened to keep (Quick Open's Return) gets a kept tab after the others
    /// and leaves the preview tab alone; only a new preview replaces the preview.
    @Test func openingToKeepLeavesThePreviewTabAlone() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        model.openFromTree(workspaceId: workspace.id, path: "a.md", keep: false)
        model.openFromTree(workspaceId: workspace.id, path: "b.md", keep: true)
        #expect(model.diffTabs[workspace.id] == ["a.md", "b.md"])
        #expect(model.previewTabs[workspace.id] == "a.md")
        #expect(model.selectedDiffTabs[workspace.id] == "b.md")

        model.openFromTree(workspaceId: workspace.id, path: "c.md", keep: false)
        #expect(model.diffTabs[workspace.id] == ["c.md", "b.md"])
        #expect(model.previewTabs[workspace.id] == "c.md")
    }

    /// FIL-05 (Review Focus 8): the first edit keeps the preview, so the next click opens another tab and the edits
    /// stay; setting the text it already has is no edit.
    @Test func theFirstEditKeepsThePreview() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        let readme = AppModel.editorPath(worktree: workspace.path, relativePath: "README.md")
        model.openFromTree(workspaceId: workspace.id, path: "README.md", keep: false)
        await model.openEditor(workspaceId: workspace.id, path: readme)
        model.setEditorText("hello\n", workspaceId: workspace.id, path: readme)
        #expect(model.previewTabs[workspace.id] == "README.md")

        model.setEditorText("hello there\n", workspaceId: workspace.id, path: readme)
        #expect(model.previewTabs[workspace.id] == nil)
        model.openFromTree(workspaceId: workspace.id, path: "notes.md", keep: false)
        #expect(model.diffTabs[workspace.id] == ["README.md", "notes.md"])
        #expect(model.isEditorDirty(workspaceId: workspace.id, path: readme))
    }

    /// FIL-05: a file in Changes opens in Diff mode, or as its open tab was left; any other file in Edit.
    @Test func aChangedFileOpensInDiffAndAnUnchangedOneInEdit() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        try await write("draft\n", to: "notes.md", in: workspace)
        model.visibleRightPanelTab = .files
        try await waitUntil { model.changes[workspace.id]?.files.map(\.path) == ["notes.md"] }

        model.openFromTree(workspaceId: workspace.id, path: "notes.md", keep: true)
        #expect(model.diffMode(workspaceId: workspace.id, path: "notes.md") == .diff)
        model.setDiffMode(.edit, workspaceId: workspace.id, path: "notes.md")
        model.openFromTree(workspaceId: workspace.id, path: "notes.md", keep: false)
        #expect(model.diffMode(workspaceId: workspace.id, path: "notes.md") == .edit)

        model.openFromTree(workspaceId: workspace.id, path: "README.md", keep: true)
        #expect(model.diffMode(workspaceId: workspace.id, path: "README.md") == .edit)
        #expect(model.diffTabs[workspace.id] == ["notes.md", "README.md"])
    }

    /// FIL-05 with DIFF-05: a badge's worktree file, spelled as FSEvents resolves it (`/private/var/…`), opens the same
    /// worktree tab as the tree, with one buffer; a file outside the worktree keeps its file tab.
    @Test func aBadgeInsideTheWorktreeOpensItsWorktreeTab() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        model.visibleRightPanelTab = .files
        try await waitUntil { model.changes[workspace.id] != nil }
        let worktree = URL(fileURLWithPath: workspace.path)
        let canonical = await Task.blocking { FileWatcher.canonicalPath(worktree) }.value
        #expect(canonical.hasPrefix("/private/") || !workspace.path.hasPrefix("/var/"))

        model.openBadgeFile(workspaceId: workspace.id, path: canonical + "/README.md")
        #expect(model.selectedDiffTabs[workspace.id] == "README.md")
        #expect(model.diffMode(workspaceId: workspace.id, path: "README.md") == .edit)
        #expect((model.openFiles[workspace.id] ?? []).isEmpty)

        model.openFromTree(workspaceId: workspace.id, path: "README.md", keep: false)
        #expect(model.diffTabs[workspace.id] == ["README.md"])
        #expect(model.previewTabs[workspace.id] == nil)
        await model.openEditor(workspaceId: workspace.id, path: AppModel.editorPath(worktree: workspace.path, relativePath: "README.md"))
        #expect(model.editors[workspace.id]?.count == 1)

        model.openBadgeFile(workspaceId: workspace.id, path: "/elsewhere/notes.md")
        #expect(model.openFiles[workspace.id] == ["/elsewhere/notes.md"])
    }

    /// FIL-05's Reveal: the panel's tab turns to All files, the file's folders are expanded and stored, and once the
    /// tab shows they are read down to the file's row.
    @Test func revealExpandsTheFilesFolders() async throws {
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers())
        try await writeFile("a\n", to: "src/api/a.ts", in: workspace)
        model.rightPanelTabs[workspace.id] = .changes
        model.reveal(workspaceId: workspace.id, path: "src/api/a.ts")
        #expect(model.rightPanelTab(workspaceId: workspace.id) == .files)
        #expect(model.fileTrees[workspace.id]?.expanded == ["src", "src/api"])
        #expect(try model.store.expandedFolders(workspaceId: workspace.id) == ["src", "src/api"])
        #expect(model.revealedPaths[workspace.id] == "src/api/a.ts")

        model.visibleRightPanelTab = .files
        try await waitUntil { model.fileTrees[workspace.id]?.listings["src/api"]?.map(\.name) == ["a.ts"] }
        model.revealHandled(workspaceId: workspace.id)
        #expect(model.revealedPaths[workspace.id] == nil)
    }

    // MARK: Quick Open (FIL-08)

    /// FIL-08's energy: Quick Open reads git's list itself, with the All files tab hidden, and lists no folder; opened
    /// again with no event in between, it reads nothing. It never changes the right panel.
    @Test func quickOpenReadsTheListOnceWhileItIsCurrent() async throws {
        let files = FakeWorktreeFiles()
        let (model, workspace) = try await watchedWorkspace(watchers: FakeWatchers(), files: files)
        try await writeFile("a\n", to: "src/a.ts", in: workspace)
        model.quickOpenWillShow(workspaceId: workspace.id)
        try await waitUntil { model.fileTrees[workspace.id]?.list != nil }
        await model.refreshFiles(workspaceId: workspace.id)
        #expect(files.listCount == 1)
        #expect(files.listedFolders.isEmpty)
        #expect(model.fileTrees[workspace.id]?.list?.paths == ["README.md", "src/a.ts"])
        #expect(model.fileTrees[workspace.id]?.listings.isEmpty == true)
        #expect(model.rightPanelTabs[workspace.id] == nil)
        model.quickOpenDidHide()

        model.quickOpenWillShow(workspaceId: workspace.id)
        await model.refreshFiles(workspaceId: workspace.id)
        #expect(files.listCount == 1)
        model.quickOpenDidHide()
        #expect(files.listedFolders.isEmpty)
    }

    /// FIL-08: an FSEvents batch between two openings makes the next one read git's list again, and only the list.
    @Test func quickOpenReadsAgainAfterAnEvent() async throws {
        let watchers = FakeWatchers()
        let files = FakeWorktreeFiles()
        let (model, workspace) = try await watchedWorkspace(watchers: watchers, files: files)
        model.quickOpenWillShow(workspaceId: workspace.id)
        try await waitUntil { model.fileTrees[workspace.id]?.list != nil }
        await model.refreshFiles(workspaceId: workspace.id)
        model.quickOpenDidHide()
        #expect(files.listCount == 1)

        try await writeFile("b\n", to: "src/b.ts", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { model.diffStats[workspace.id]?.files == 1 }
        #expect(files.listCount == 1)

        model.quickOpenWillShow(workspaceId: workspace.id)
        try await waitUntil { model.fileTrees[workspace.id]?.list?.paths.contains("src/b.ts") == true }
        await model.refreshFiles(workspaceId: workspace.id)
        #expect(files.listCount == 2)
        #expect(files.listedFolders.isEmpty)
        model.quickOpenDidHide()
    }

    /// FIL-08: events while Quick Open is open only mark the list stale, so typing never waits on git; the full diff
    /// follows them, for the status letters. The next opening reads the list.
    @Test func eventsWhileQuickOpenIsOpenReadNothing() async throws {
        let watchers = FakeWatchers()
        let files = FakeWorktreeFiles()
        let (model, workspace) = try await watchedWorkspace(watchers: watchers, files: files)
        model.quickOpenWillShow(workspaceId: workspace.id)
        try await waitUntil { model.fileTrees[workspace.id]?.list != nil && model.changes[workspace.id] != nil }
        await model.refreshFiles(workspaceId: workspace.id)
        #expect(files.listCount == 1)

        try await writeFile("b\n", to: "src/b.ts", in: workspace)
        watchers.fire(workspace.path)
        try await waitUntil { model.changes[workspace.id]?.files.map(\.path) == ["src/b.ts"] }
        #expect(files.listCount == 1)
        #expect(files.listedFolders.isEmpty)
        #expect(model.fileTrees[workspace.id]?.list?.paths.contains("src/b.ts") == false)
        model.quickOpenDidHide()

        model.quickOpenWillShow(workspaceId: workspace.id)
        try await waitUntil { model.fileTrees[workspace.id]?.list?.paths.contains("src/b.ts") == true }
        #expect(files.listCount == 2)
        model.quickOpenDidHide()
    }

    /// FIL-08: every open of a worktree tab (the tree, the Changes tab, a badge, Quick Open) makes its file the newest
    /// recent file; selecting a tab already on screen does not. The last 20 are kept, and they come back after a
    /// relaunch, read when Quick Open first shows.
    @Test func openingRecordsARecentFile() async throws {
        let store = try RockyStore.inMemory()
        let model = try makeModel(store: store)
        await model.bootstrap()
        await model.addRepo(at: try await GitFixture.localRepoOffMain(in: try Fixtures.temporaryDirectory("repos")))
        let repoId = try #require(model.repos.first?.id)
        await model.createWorkspace(repoId: repoId)
        let workspace = try #require(model.workspaces[repoId]?.first)

        model.openFromTree(workspaceId: workspace.id, path: "a.md", keep: false)
        model.openDiff(workspaceId: workspace.id, path: "b.md")
        model.openBadgeFile(workspaceId: workspace.id, path: workspace.path + "/c.md")
        #expect(model.recentFiles[workspace.id] == ["c.md", "b.md", "a.md"])
        model.showDiff(workspaceId: workspace.id, path: "a.md")
        #expect(model.recentFiles[workspace.id] == ["c.md", "b.md", "a.md"])
        model.openFromTree(workspaceId: workspace.id, path: "a.md", keep: true)
        #expect(model.recentFiles[workspace.id] == ["a.md", "c.md", "b.md"])

        for index in 0..<25 {
            model.openDiff(workspaceId: workspace.id, path: "f\(index).md")
        }
        let recent = try #require(model.recentFiles[workspace.id])
        #expect(recent.count == QuickOpen.recentLimit)
        #expect(recent.first == "f24.md")
        #expect(recent.last == "f5.md")
        #expect(try store.recentFiles(workspaceId: workspace.id) == recent)

        let relaunched = try makeModel(store: store)
        await relaunched.bootstrap()
        relaunched.selectedWorkspaceId = workspace.id
        #expect(relaunched.recentFiles[workspace.id] == nil)
        relaunched.quickOpenWillShow(workspaceId: workspace.id)
        #expect(relaunched.recentFiles[workspace.id] == recent)
        relaunched.quickOpenDidHide()
    }

    @Test func worktreeRelativePathIsOnlyForFilesInsideTheWorktree() {
        #expect(AppModel.worktreeRelativePath(of: "/w/tokyo/src/a.ts", worktree: "/w/tokyo") == "src/a.ts")
        #expect(AppModel.worktreeRelativePath(of: "/w/tokyo/a.ts", worktree: "/w/tokyo/") == "a.ts")
        #expect(AppModel.worktreeRelativePath(of: "/w/tokyo-2/a.ts", worktree: "/w/tokyo") == nil)
        #expect(AppModel.worktreeRelativePath(of: "/w/tokyo", worktree: "/w/tokyo") == nil)
        #expect(AppModel.worktreeRelativePath(of: "/w/tokyo/", worktree: "/w/tokyo") == nil)
    }

    @Test func environmentCaptureFailureFallsBackAndReports() async throws {
        struct Boom: Error {}
        let model = try makeModel(capture: { throw Boom() })
        await model.bootstrap()
        #expect(model.loginEnvironment["PATH"] != nil)
        #expect(model.errorMessage?.hasPrefix("Could not read your login shell environment") == true)
    }
}
