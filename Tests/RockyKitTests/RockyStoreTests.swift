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

    /// KIT-13: nil while the repository has no user message, the agent's replies and another repository's messages
    /// included.
    @Test func lastUsedAgentIsNilWithoutAUserMessageInTheRepository() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        let other = Repo(name: "web", path: "/dev/web")
        try store.add(repo)
        try store.add(other)
        #expect(try store.lastUsedAgent(repoId: repo.id) == nil)

        let lisbon = Workspace(repoId: repo.id, name: "lisbon", path: "/p", branch: "rocky/lisbon")
        let paris = Workspace(repoId: other.id, name: "paris", path: "/r", branch: "rocky/paris")
        try store.add(lisbon)
        try store.add(paris)
        let session = ChatSessionRecord(workspaceId: lisbon.id, agent: "opencode")
        let elsewhere = ChatSessionRecord(workspaceId: paris.id, agent: "opencode")
        try store.add(session)
        try store.add(elsewhere)
        try store.upsert(ChatMessageRecord(id: "a", sessionId: session.id, seq: 0, kind: "agent", text: "Hello", status: nil))
        try store.upsert(ChatMessageRecord(id: "b", sessionId: elsewhere.id, seq: 0, kind: "user", text: "hi", status: nil))

        #expect(try store.lastUsedAgent(repoId: repo.id) == nil)
        #expect(try store.lastUsedAgent(repoId: other.id) == .opencode)
    }

    /// KIT-13, CNV-02: the agent of the newest user message across the repository's workspaces; a closed tab still
    /// counts, and another repository's newer messages do not.
    @Test func lastUsedAgentFollowsTheNewestUserMessageAcrossTheRepository() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        let other = Repo(name: "web", path: "/dev/web")
        try store.add(repo)
        try store.add(other)
        let lisbon = Workspace(repoId: repo.id, name: "lisbon", path: "/p", branch: "rocky/lisbon")
        let oslo = Workspace(repoId: repo.id, name: "oslo", path: "/q", branch: "rocky/oslo")
        let paris = Workspace(repoId: other.id, name: "paris", path: "/r", branch: "rocky/paris")
        for workspace in [lisbon, oslo, paris] { try store.add(workspace) }
        let claude = ChatSessionRecord(workspaceId: lisbon.id, agent: "claude", createdAt: day)
        var opencode = ChatSessionRecord(workspaceId: oslo.id, agent: "opencode", createdAt: day)
        let elsewhere = ChatSessionRecord(workspaceId: paris.id, agent: "claude", createdAt: day)
        for session in [claude, opencode, elsewhere] { try store.add(session) }

        func send(_ id: String, in session: ChatSessionRecord, kind: String = "user", after seconds: Double) throws {
            try store.upsert(ChatMessageRecord(
                id: id, sessionId: session.id, seq: 0, kind: kind, text: id, status: nil,
                createdAt: day.addingTimeInterval(seconds)
            ))
        }

        try send("first", in: claude, after: 10)
        #expect(try store.lastUsedAgent(repoId: repo.id) == .claude)

        // Another workspace of the repository, later: its agent.
        try send("second", in: opencode, after: 20)
        #expect(try store.lastUsedAgent(repoId: repo.id) == .opencode)

        // The agent's own reply in the other conversation, and a newer message in another repository, change nothing.
        try send("reply", in: claude, kind: "agent", after: 30)
        try send("elsewhere", in: elsewhere, after: 40)
        #expect(try store.lastUsedAgent(repoId: repo.id) == .opencode)

        // Its tab closed: the message still counts.
        opencode.closedAt = day.addingTimeInterval(50)
        try store.update(opencode)
        #expect(try store.lastUsedAgent(repoId: repo.id) == .opencode)

        try send("third", in: claude, after: 60)
        #expect(try store.lastUsedAgent(repoId: repo.id) == .claude)
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

    // MARK: Review comments (M3)

    /// CMT-05 (2026-09-24): Rocky stores no comment any more. A database at the previous migration, with v9's table and
    /// a comment in it, opens without the table and keeps its other rows; a new database never keeps it either.
    @Test func theNextMigrationDropsTheCommentsTable() throws {
        let path = try Fixtures.temporaryDirectory("store").appendingPathComponent("rocky.sqlite").path
        let v11 = try DatabaseQueue(path: path)
        try RockyStore.migrator.migrate(v11, upTo: "v11")
        try v11.write { db in
            try db.execute(sql: "INSERT INTO repo (id, name, path, colorIndex, createdAt) VALUES ('r1', 'app', '/r/app', 2, '2026-09-01 10:00:00.000')")
            try db.execute(sql: """
                INSERT INTO workspace (id, repoId, name, path, branch, port, createdAt)
                VALUES ('w1', 'r1', 'lisbon', '/r/app-worktrees/lisbon', 'rocky/lisbon', 41000, '2026-09-01 10:00:00.000')
                """)
            try db.execute(sql: """
                INSERT INTO diffComment (id, workspaceId, path, side, startLine, endLine, snippet, contextBefore, contextAfter,
                    body, state, createdAt, sentAt)
                VALUES ('c1', 'w1', 'README.md', 'new', 1, 1, '["hello"]', '[]', '[]', 'Keep it.', 'sent',
                    '2026-09-01 10:00:00.000', '2026-09-01 10:01:00.000')
                """)
            try db.execute(sql: "INSERT INTO recentFile (workspaceId, path, openedAt) VALUES ('w1', 'README.md', '2026-09-01 10:02:00.000')")
        }
        try v11.close()

        let store = try RockyStore(path: path)
        #expect(try store.workspaces(repoId: "r1").map(\.name) == ["lisbon"])
        #expect(try store.recentFiles(workspaceId: "w1") == ["README.md"])
        let reopened = try DatabaseQueue(path: path)
        #expect(try reopened.read { try $0.tableExists("diffComment") } == false)
        try reopened.close()

        let freshPath = try Fixtures.temporaryDirectory("store").appendingPathComponent("rocky.sqlite").path
        _ = try RockyStore(path: freshPath)
        let fresh = try DatabaseQueue(path: freshPath)
        #expect(try fresh.read { try $0.tableExists("diffComment") } == false)
        #expect(try fresh.read { try $0.tableExists("recentFile") })
        try fresh.close()
    }

    /// FIL-01, FIL-03: a database at the previous migration opens, gains the expanded folders' table and the
    /// repository's Show Ignored Files (off), and keeps its rows.
    @Test func treeStateMigrationAddsItsTableAndColumn() throws {
        let path = try Fixtures.temporaryDirectory("store").appendingPathComponent("rocky.sqlite").path
        let v9 = try DatabaseQueue(path: path)
        try RockyStore.migrator.migrate(v9, upTo: "v9")
        try v9.write { db in
            try db.execute(sql: "INSERT INTO repo (id, name, path, colorIndex, createdAt) VALUES ('r1', 'app', '/r/app', 2, '2026-09-01 10:00:00.000')")
            try db.execute(sql: """
                INSERT INTO workspace (id, repoId, name, path, branch, port, createdAt)
                VALUES ('w1', 'r1', 'lisbon', '/r/app-worktrees/lisbon', 'rocky/lisbon', 41000, '2026-09-01 10:00:00.000')
                """)
        }
        try v9.close()

        let store = try RockyStore(path: path)
        let repo = try #require(try store.repos().first)
        #expect(repo.colorIndex == 2)
        #expect(repo.showsIgnoredFiles == false)
        #expect(try store.workspaces(repoId: "r1").map(\.name) == ["lisbon"])
        #expect(try store.expandedFolders(workspaceId: "w1").isEmpty)

        try store.setShowsIgnoredFiles(true, repoId: "r1")
        #expect(try store.repos().first?.showsIgnoredFiles == true)
        // Column-only: the other settings stay as they were.
        #expect(try store.repos().first?.colorIndex == 2)
        try store.setExpandedFolders(["src", "src/api"], workspaceId: "w1")
        #expect(try store.expandedFolders(workspaceId: "w1") == ["src", "src/api"])
    }

    /// FIL-01: the expanded folders are replaced as a set, kept per workspace, and go with their workspace.
    @Test func expandedFoldersRoundTripAndGoWithTheWorkspace() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let lisbon = Workspace(repoId: repo.id, name: "lisbon", path: "/p", branch: "rocky/lisbon")
        let oslo = Workspace(repoId: repo.id, name: "oslo", path: "/q", branch: "rocky/oslo")
        try store.add(lisbon)
        try store.add(oslo)

        try store.setExpandedFolders(["src", "src/api", "docs"], workspaceId: lisbon.id)
        try store.setExpandedFolders(["src"], workspaceId: oslo.id)
        #expect(try store.expandedFolders(workspaceId: lisbon.id) == ["src", "src/api", "docs"])
        try store.setExpandedFolders(["src"], workspaceId: lisbon.id)
        #expect(try store.expandedFolders(workspaceId: lisbon.id) == ["src"])
        try store.setExpandedFolders([], workspaceId: lisbon.id)
        #expect(try store.expandedFolders(workspaceId: lisbon.id).isEmpty)

        try store.setExpandedFolders(["a"], workspaceId: lisbon.id)
        try store.deleteWorkspace(id: lisbon.id)
        #expect(try store.expandedFolders(workspaceId: lisbon.id).isEmpty)
        #expect(try store.expandedFolders(workspaceId: oslo.id) == ["src"])
    }

    /// FIL-08: a database at the previous migration opens, gains the recent files' table, and keeps its rows.
    @Test func recentFilesMigrationAddsItsTable() throws {
        let path = try Fixtures.temporaryDirectory("store").appendingPathComponent("rocky.sqlite").path
        let v10 = try DatabaseQueue(path: path)
        try RockyStore.migrator.migrate(v10, upTo: "v10")
        try v10.write { db in
            try db.execute(sql: "INSERT INTO repo (id, name, path, colorIndex, createdAt) VALUES ('r1', 'app', '/r/app', 2, '2026-09-01 10:00:00.000')")
            try db.execute(sql: """
                INSERT INTO workspace (id, repoId, name, path, branch, port, createdAt)
                VALUES ('w1', 'r1', 'lisbon', '/r/app-worktrees/lisbon', 'rocky/lisbon', 41000, '2026-09-01 10:00:00.000')
                """)
            try db.execute(sql: "INSERT INTO expandedFolder (workspaceId, path) VALUES ('w1', 'src')")
        }
        try v10.close()

        let store = try RockyStore(path: path)
        #expect(try store.expandedFolders(workspaceId: "w1") == ["src"])
        #expect(try store.recentFiles(workspaceId: "w1").isEmpty)
        try store.recordRecentFile(path: "src/a.ts", workspaceId: "w1", at: day)
        #expect(try store.recentFiles(workspaceId: "w1") == ["src/a.ts"])
    }

    /// FIL-08: the newest 20 of each workspace are kept, the oldest dropped; a file opened again moves to the front,
    /// once; opens at the same time keep their order; they go with their workspace, and another workspace's stay.
    @Test func recentFilesKeepTheNewest20AndGoWithTheWorkspace() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let lisbon = Workspace(repoId: repo.id, name: "lisbon", path: "/p", branch: "rocky/lisbon")
        let oslo = Workspace(repoId: repo.id, name: "oslo", path: "/q", branch: "rocky/oslo")
        try store.add(lisbon)
        try store.add(oslo)

        for index in 0..<22 {
            try store.recordRecentFile(path: "file\(index).ts", workspaceId: lisbon.id, at: day.addingTimeInterval(Double(index)))
        }
        try store.recordRecentFile(path: "other.ts", workspaceId: oslo.id, at: day)
        let kept = try store.recentFiles(workspaceId: lisbon.id)
        #expect(kept.count == QuickOpen.recentLimit)
        #expect(kept.first == "file21.ts")
        #expect(kept.last == "file2.ts")
        #expect(!kept.contains("file0.ts") && !kept.contains("file1.ts"))

        try store.recordRecentFile(path: "file5.ts", workspaceId: lisbon.id, at: day.addingTimeInterval(100))
        let reopened = try store.recentFiles(workspaceId: lisbon.id)
        #expect(reopened.first == "file5.ts")
        #expect(reopened.filter { $0 == "file5.ts" }.count == 1)
        #expect(reopened.count == QuickOpen.recentLimit)

        // The same time: the later open is newer.
        let later = day.addingTimeInterval(200)
        try store.recordRecentFile(path: "x.ts", workspaceId: lisbon.id, at: later)
        try store.recordRecentFile(path: "y.ts", workspaceId: lisbon.id, at: later)
        #expect(try store.recentFiles(workspaceId: lisbon.id).prefix(3) == ["y.ts", "x.ts", "file5.ts"])

        try store.deleteWorkspace(id: lisbon.id)
        #expect(try store.recentFiles(workspaceId: lisbon.id).isEmpty)
        #expect(try store.recentFiles(workspaceId: oslo.id) == ["other.ts"])
    }

    // MARK: Line counts (DIFF-06)

    /// A database at the previous migration opens, and its transcript rows keep their data, with no counts.
    @Test func theNextMigrationAddsTheLineCountColumns() throws {
        let path = try Fixtures.temporaryDirectory("store").appendingPathComponent("rocky.sqlite").path
        let v12 = try DatabaseQueue(path: path)
        try RockyStore.migrator.migrate(v12, upTo: "v12")
        try v12.write { db in
            try db.execute(sql: "INSERT INTO repo (id, name, path, createdAt) VALUES ('r1', 'app', '/r/app', '2026-09-01 10:00:00.000')")
            try db.execute(sql: """
                INSERT INTO workspace (id, repoId, name, path, branch, createdAt)
                VALUES ('w1', 'r1', 'lisbon', '/r/app-worktrees/lisbon', 'rocky/lisbon', '2026-09-01 10:00:00.000')
                """)
            try db.execute(sql: "INSERT INTO chatSession (id, workspaceId, agent, createdAt) VALUES ('s1', 'w1', 'claude', '2026-09-01 10:00:00.000')")
            try db.execute(sql: """
                INSERT INTO chatMessage (id, sessionId, seq, kind, text, status, toolKind, createdAt)
                VALUES ('m1', 's1', 1, 'tool', 'Edit README.md', 'completed', 'edit', '2026-09-01 10:01:00.000')
                """)
        }
        try v12.close()

        let store = try RockyStore(path: path)
        let message = try #require(try store.messages(sessionId: "s1").first)
        #expect(message.text == "Edit README.md")
        #expect(message.toolKind == "edit")
        #expect(message.additions == nil)
        #expect(message.deletions == nil)
        #expect(ChatItem(record: message).diffStat == nil)
    }

    /// A tool call's counts round-trip through its transcript row, "+10 −0" included, and a call without them stays
    /// without, so a resumed conversation shows what it showed.
    @Test func aToolCallKeepsItsLineCounts() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/dev/app")
        try store.add(repo)
        let workspace = Workspace(repoId: repo.id, name: "lisbon", path: "/p", branch: "b")
        try store.add(workspace)
        let session = ChatSessionRecord(workspaceId: workspace.id, agent: "claude")
        try store.add(session)

        let edit = ChatItem(
            kind: .tool, text: "Edit README.md", status: "completed", attachments: ["/p/README.md"], toolKind: "edit",
            createdAt: day, diffStat: DiffStat(additions: 1, deletions: 1)
        )
        let write = ChatItem(kind: .tool, text: "Write notes.md", status: "completed", toolKind: "edit", createdAt: day, diffStat: DiffStat(additions: 10))
        let read = ChatItem(kind: .tool, text: "Read a.ts", status: "completed", toolKind: "read", createdAt: day)
        for item in [edit, write, read] { try store.upsert(ChatMessageRecord(item: item, sessionId: session.id)) }

        let messages = try store.messages(sessionId: session.id)
        #expect(messages.map(\.additions) == [1, 10, nil])
        #expect(messages.map(\.deletions) == [1, 0, nil])
        #expect(messages.map(ChatItem.init(record:)) == [edit, write, read])
    }

    @Test func persistsAcrossReopen() throws {
        let path = try Fixtures.temporaryDirectory("db").appendingPathComponent("rocky.sqlite").path
        try RockyStore(path: path).add(Repo(name: "app", path: "/dev/app"))
        #expect(try RockyStore(path: path).repos().map(\.name) == ["app"])
    }
}
