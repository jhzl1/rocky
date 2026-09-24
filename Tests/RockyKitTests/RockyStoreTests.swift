import Foundation
import GRDB
import Testing
@testable import RockyKit

struct RockyStoreTests {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func storesAndUpdatesRepos() throws {
        let store = try RockyStore.inMemory()
        var repo = Repo(name: "app", path: "/dev/app", createdAt: day)
        try store.add(repo)
        repo.claudeConfigDir = "/Users/me/.claude-celes"
        try store.update(repo)
        #expect(try store.repos() == [repo])
    }

    @Test func keepsARepoLinkedPaths() throws {
        let store = try RockyStore.inMemory()
        var repo = Repo(name: "app", path: "/dev/app", createdAt: day)
        try store.add(repo)
        repo.linkedPaths = "apps/api-core/.venv\n.vscode/*"
        try store.update(repo)
        #expect(try store.repos().first?.linkedPaths == "apps/api-core/.venv\n.vscode/*")
    }

    @Test func rejectsTheSameRepoPathTwice() throws {
        let store = try RockyStore.inMemory()
        try store.add(Repo(name: "app", path: "/dev/app"))
        #expect(throws: RockyStoreError.duplicateRepo("/dev/app")) { try store.add(Repo(name: "app2", path: "/dev/app")) }
    }

    @Test func deletingARepoCascadesToWorkspacesAndTranscripts() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let workspace = Workspace(repoId: repo.id, name: "lisbon", path: "/dev/app-worktrees/lisbon", branch: "rocky/lisbon")
        try store.add(workspace)
        let session = ChatSessionRecord(workspaceId: workspace.id, agent: "claude")
        try store.add(session)
        try store.upsert(ChatMessageRecord(id: "m1", sessionId: session.id, seq: 0, kind: "user", text: "hi", status: nil))

        try store.deleteRepo(id: repo.id)

        #expect(try store.workspaces(repoId: repo.id).isEmpty)
        #expect(try store.latestSession(workspaceId: workspace.id, agent: "claude") == nil)
        #expect(try store.messages(sessionId: session.id).isEmpty)
    }

    @Test func latestSessionIsPerAgent() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let workspace = Workspace(repoId: repo.id, name: "lisbon", path: "/p", branch: "rocky/lisbon")
        try store.add(workspace)
        let older = ChatSessionRecord(workspaceId: workspace.id, agent: "claude", createdAt: day)
        let newer = ChatSessionRecord(workspaceId: workspace.id, agent: "claude", createdAt: day.addingTimeInterval(60))
        let other = ChatSessionRecord(workspaceId: workspace.id, agent: "opencode", createdAt: day.addingTimeInterval(120))
        for session in [older, newer, other] { try store.add(session) }
        #expect(try store.latestSession(workspaceId: workspace.id, agent: "claude") == newer)
    }

    @Test func upsertAppendsInOrderAndReplacesInPlace() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let workspace = Workspace(repoId: repo.id, name: "lisbon", path: "/p", branch: "b")
        try store.add(workspace)
        let session = ChatSessionRecord(workspaceId: workspace.id, agent: "claude")
        try store.add(session)

        try store.upsert(ChatMessageRecord(id: "a", sessionId: session.id, seq: 0, kind: "user", text: "hi", status: nil))
        try store.upsert(ChatMessageRecord(id: "b", sessionId: session.id, seq: 0, kind: "tool", text: "Run ls", status: "pending"))
        try store.upsert(ChatMessageRecord(id: "b", sessionId: session.id, seq: 0, kind: "tool", text: "Run ls", status: "completed"))

        let messages = try store.messages(sessionId: session.id)
        #expect(messages.map(\.id) == ["a", "b"])
        #expect(messages.map(\.seq) == [1, 2])
        #expect(messages[1].status == "completed")
    }

    @Test func keepsAMessagesFilesAndToolKind() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let workspace = Workspace(repoId: repo.id, name: "lisbon", path: "/p", branch: "b")
        try store.add(workspace)
        let session = ChatSessionRecord(workspaceId: workspace.id, agent: "claude")
        try store.add(session)

        try store.upsert(ChatMessageRecord(id: "a", sessionId: session.id, seq: 0, kind: "user", text: "look", status: nil, attachments: ["/tmp/shot.png"]))
        try store.upsert(ChatMessageRecord(id: "b", sessionId: session.id, seq: 0, kind: "tool", text: "Read shot.png", status: "completed", attachments: ["/tmp/shot.png"], toolKind: "read"))

        let messages = try store.messages(sessionId: session.id)
        #expect(messages.map(\.attachments) == [["/tmp/shot.png"], ["/tmp/shot.png"]])
        #expect(messages.map(\.toolKind) == [nil, "read"])
    }

    /// ROW-02: the oldest open conversation that has a title; closed and untitled ones are ignored.
    @Test func conversationTitlesPickTheOldestOpenTitledConversation() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let workspace = Workspace(repoId: repo.id, name: "lisbon", path: "/p", branch: "b")
        let other = Workspace(repoId: repo.id, name: "oslo", path: "/q", branch: "c")
        try store.add(workspace)
        try store.add(other)
        let day = Date(timeIntervalSince1970: 1_000_000)
        try store.add(ChatSessionRecord(workspaceId: workspace.id, agent: "claude", title: "Closed first", closedAt: day, createdAt: day))
        try store.add(ChatSessionRecord(workspaceId: workspace.id, agent: "claude", title: nil, createdAt: day.addingTimeInterval(10)))
        try store.add(ChatSessionRecord(workspaceId: workspace.id, agent: "claude", title: "Fix invoice rounding", createdAt: day.addingTimeInterval(20)))
        try store.add(ChatSessionRecord(workspaceId: workspace.id, agent: "opencode", title: "Later task", createdAt: day.addingTimeInterval(30)))
        try store.add(ChatSessionRecord(workspaceId: other.id, agent: "claude", title: nil, createdAt: day))

        #expect(try store.conversationTitles() == [workspace.id: "Fix invoice rounding"])
    }

    @Test func aTabTitleLeavesTheFilesOut() {
        let marker = PromptAttachment.marker
        #expect(ChatSessionRecord.title(from: "\(marker) Mira \(marker) esta imagen\nsegunda línea") == "Mira esta imagen")
    }

    // MARK: GitHub (M2.7)

    /// v7 adds `repo.githubLogin` and the workspace's pull request columns; rows of a v6 database keep their data and
    /// get nil in them.
    @Test func theNextMigrationAddsTheGitHubColumns() throws {
        let path = try Fixtures.temporaryDirectory("store").appendingPathComponent("rocky.sqlite").path
        let v6 = try DatabaseQueue(path: path)
        try RockyStore.migrator.migrate(v6, upTo: "v6")
        try v6.write { db in
            try db.execute(sql: "INSERT INTO repo (id, name, path, linkedPaths, createdAt) VALUES ('r1', 'app', '/r/app', '.venv', '2026-09-01 10:00:00.000')")
            try db.execute(sql: """
                INSERT INTO workspace (id, repoId, name, path, branch, port, baseRef, createdAt)
                VALUES ('w1', 'r1', 'lisbon', '/r/app-worktrees/lisbon', 'rocky/lisbon', 41000, 'origin/main', '2026-09-01 10:00:00.000')
                """)
        }
        try v6.close()

        let store = try RockyStore(path: path)
        let repo = try #require(try store.repos().first)
        #expect(repo.linkedPaths == ".venv")
        #expect(repo.githubLogin == nil)
        let workspace = try #require(try store.workspaces(repoId: "r1").first)
        #expect(workspace.name == "lisbon")
        #expect(workspace.port == 41000)
        #expect(workspace.baseRef == "origin/main")
        #expect(workspace.prNumber == nil)
        #expect(workspace.prHiddenCommentIds == nil)
        #expect(workspace.storedPullRequest == nil)
    }

    @Test func keepsTheRepoGitHubLogin() throws {
        let store = try RockyStore.inMemory()
        var repo = Repo(name: "app", path: "/dev/app", createdAt: day)
        try store.add(repo)
        repo.githubLogin = "ocampos-biai"
        try store.update(repo)
        #expect(try store.repos().first?.githubLogin == "ocampos-biai")
        repo.githubLogin = nil
        try store.update(repo)
        #expect(try store.repos().first?.githubLogin == nil)
    }

    private func storedPullRequest() -> StoredPullRequest {
        StoredPullRequest(
            number: 4525,
            url: URL(string: "https://github.com/jhzl1/rocky/pull/4525")!,
            state: "OPEN",
            headerState: "checksFailing",
            checks: [
                PullRequestCheck(
                    name: "e2e / chromium", state: .failed, startedAt: day, completedAt: day.addingTimeInterval(200),
                    url: URL(string: "https://github.com/jhzl1/rocky/actions/runs/901/job/7002"), checkRunId: 7002, workflowRunId: 901
                ),
                PullRequestCheck(name: "Vercel", state: .pending, url: URL(string: "https://vercel.com/jhzl1/rocky/abc")),
            ],
            updatedAt: day,
            hiddenCommentIds: ["PRRT_retry", "IC_timeout"]
        )
    }

    @Test func storedPullRequestRoundTrips() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let workspace = Workspace(repoId: repo.id, name: "tokyo", path: "/p", branch: "rocky/tokyo")
        try store.add(workspace)
        #expect(try store.workspaces(repoId: repo.id).first?.storedPullRequest == nil)

        let stored = storedPullRequest()
        try store.savePullRequest(stored, workspaceId: workspace.id)
        #expect(try store.workspaces(repoId: repo.id).first?.storedPullRequest == stored)

        try store.savePullRequest(nil, workspaceId: workspace.id)
        let cleared = try #require(try store.workspaces(repoId: repo.id).first)
        #expect(cleared.storedPullRequest == nil)
        #expect(cleared.prNumber == nil)
        #expect(cleared.prHiddenCommentIds == nil)
    }

    /// The pull request columns are written alone: saving never brings back a name changed since the copy was read.
    @Test func savingAPullRequestKeepsTheWorkspaceName() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let stale = Workspace(repoId: repo.id, name: "tokyo", path: "/p", branch: "rocky/tokyo")
        try store.add(stale)
        var renamed = stale
        renamed.name = "kyoto"
        try store.update(renamed)

        try store.savePullRequest(storedPullRequest(), workspaceId: stale.id)
        let saved = try #require(try store.workspaces(repoId: repo.id).first)
        #expect(saved.name == "kyoto")
        #expect(saved.storedPullRequest?.number == 4525)
    }

    @Test func persistsAcrossReopen() throws {
        let path = try Fixtures.temporaryDirectory("db").appendingPathComponent("rocky.sqlite").path
        try RockyStore(path: path).add(Repo(name: "app", path: "/dev/app"))
        #expect(try RockyStore(path: path).repos().map(\.name) == ["app"])
    }
}
