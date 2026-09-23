import Foundation
import GRDB
import Testing
@testable import RockyKit

struct RockyStoreV2Tests {
    @Test func migrationGivesExistingWorkspacesTheirOwnPorts() throws {
        let path = try Fixtures.temporaryDirectory("store").appendingPathComponent("rocky.sqlite").path
        let v1 = try DatabaseQueue(path: path)
        try RockyStore.migrator.migrate(v1, upTo: "v1")
        try v1.write { db in
            try db.execute(sql: "INSERT INTO repo (id, name, path, createdAt) VALUES ('r1', 'app', '/r/app', '2026-09-01 10:00:00.000')")
            try db.execute(sql: """
                INSERT INTO workspace (id, repoId, name, path, branch, createdAt) VALUES
                ('w1', 'r1', 'lisbon', '/r/app-worktrees/lisbon', 'rocky/lisbon', '2026-09-01 10:00:00.000'),
                ('w2', 'r1', 'oslo', '/r/app-worktrees/oslo', 'rocky/oslo', '2026-09-02 10:00:00.000')
                """)
        }
        try v1.close()

        let store = try RockyStore(path: path)
        let workspaces = try store.workspaces(repoId: "r1")
        #expect(workspaces.map(\.port) == [41000, 41010])
        #expect(workspaces.map(\.baseRef) == [nil, nil])
        #expect(try store.nextPort() == 41020)
    }

    @Test func repoScriptsAndWorkspacePortPersist() throws {
        let store = try RockyStore.inMemory()
        var repo = Repo(name: "app", path: "/r/app")
        try store.add(repo)
        repo.setupScript = "pnpm install"
        repo.runScriptMode = "nonconcurrent"
        try store.update(repo)
        let saved = try #require(try store.repos().first)
        #expect(saved.setupScript == "pnpm install")
        #expect(saved.runScriptMode == "nonconcurrent")

        let workspace = Workspace(
            repoId: repo.id, name: "lisbon", path: "/r/app-worktrees/lisbon", branch: "rocky/lisbon",
            port: try store.nextPort(), baseRef: "origin/main"
        )
        try store.add(workspace)
        #expect(try store.workspaces(repoId: repo.id).first?.port == 41000)
        #expect(try store.workspaces(repoId: repo.id).first?.baseRef == "origin/main")
        #expect(try store.nextPort() == 41010)
    }

    @Test func repoVariablesUpsertByNameAndGoWithTheRepo() throws {
        let store = try RockyStore.inMemory()
        let repo = Repo(name: "app", path: "/r/app")
        try store.add(repo)
        try store.save(RepoVar(repoId: repo.id, name: "API_URL", value: "http://a", isSecret: false))
        try store.save(RepoVar(repoId: repo.id, name: "API_URL", value: "http://b", isSecret: false))
        try store.save(RepoVar(repoId: repo.id, name: "TOKEN", value: nil, isSecret: true))
        #expect(try store.repoVars(repoId: repo.id).map { "\($0.name)=\($0.value ?? "<secret>")" } == ["API_URL=http://b", "TOKEN=<secret>"])

        try store.deleteRepoVar(repoId: repo.id, name: "API_URL")
        #expect(try store.repoVars(repoId: repo.id).map(\.name) == ["TOKEN"])

        try store.deleteRepo(id: repo.id)
        #expect(try store.repoVars(repoId: repo.id).isEmpty)
    }
}
