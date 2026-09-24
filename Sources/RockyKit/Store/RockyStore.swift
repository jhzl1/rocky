import Foundation
import GRDB

public enum RockyStoreError: Error, Equatable {
    case duplicateRepo(String)
}

/// SQLite persistence for repos, workspaces, chat transcripts and repo variables (secret values live in the Keychain).
public final class RockyStore: Sendable {
    private let db: DatabaseQueue

    public convenience init(path: String) throws {
        try self.init(queue: DatabaseQueue(path: path))
    }

    public static func inMemory() throws -> RockyStore {
        try RockyStore(queue: DatabaseQueue())
    }

    private init(queue: DatabaseQueue) throws {
        db = queue
        try Self.migrator.migrate(db)
    }

    /// Internal, not private: the migration test builds a v1 database with it.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "repo") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("claudeConfigDir", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "workspace") { t in
                t.primaryKey("id", .text)
                t.column("repoId", .text).notNull().indexed().references("repo", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull()
                t.column("branch", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "chatSession") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().indexed().references("workspace", onDelete: .cascade)
                t.column("agent", .text).notNull()
                t.column("acpSessionId", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "chatMessage") { t in
                t.primaryKey("id", .text)
                t.column("sessionId", .text).notNull().indexed().references("chatSession", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("status", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "setupScript", .text)
                t.add(column: "runScript", .text)
                t.add(column: "archiveScript", .text)
                t.add(column: "runScriptMode", .text)
            }
            try db.alter(table: "workspace") { t in
                t.add(column: "port", .integer)
                t.add(column: "baseRef", .text)
            }
            try db.create(table: "repoVar") { t in
                t.primaryKey("id", .text)
                t.column("repoId", .text).notNull().indexed().references("repo", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("value", .text)
                t.column("isSecret", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["repoId", "name"])
            }
            // Workspaces made by M1 had no port: give each its own block, oldest first.
            let ids = try String.fetchAll(db, sql: "SELECT id FROM workspace ORDER BY createdAt, name")
            for (index, id) in ids.enumerated() {
                let port = PortAllocator.firstPort + index * PortAllocator.blockSize
                try db.execute(sql: "UPDATE workspace SET port = ? WHERE id = ?", arguments: [port, id])
            }
        }
        migrator.registerMigration("v3") { db in
            try db.alter(table: "chatMessage") { t in
                t.add(column: "completedAt", .datetime)
            }
        }
        migrator.registerMigration("v4") { db in
            try db.alter(table: "chatSession") { t in
                t.add(column: "title", .text)
                t.add(column: "closedAt", .datetime)
            }
        }
        migrator.registerMigration("v5") { db in
            try db.alter(table: "chatMessage") { t in
                t.add(column: "attachments", .text)
                t.add(column: "toolKind", .text)
            }
        }
        migrator.registerMigration("v6") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "linkedPaths", .text)
            }
        }
        // M2.7: the repository's GitHub account (ACC-01) and each workspace's last pull request (PR-07).
        migrator.registerMigration("v7") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "githubLogin", .text)
            }
            try db.alter(table: "workspace") { t in
                t.add(column: "prNumber", .integer)
                t.add(column: "prUrl", .text)
                t.add(column: "prState", .text)
                t.add(column: "prHeaderState", .text)
                t.add(column: "prChecks", .text)
                t.add(column: "prUpdatedAt", .datetime)
                t.add(column: "prHiddenCommentIds", .text)
            }
        }
        // Each repository's monogram color, stored instead of hashed from its id: the hash put most repositories on
        // the same pink (user report, 2026-09-23).
        migrator.registerMigration("v8") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "colorIndex", .integer)
            }
        }
        // M3: review comments on diff lines (CMT-03), which go with their workspace. The snippet and its context are
        // JSON arrays of lines.
        migrator.registerMigration("v9") { db in
            try db.create(table: "diffComment") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().indexed().references("workspace", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("side", .text).notNull()
                t.column("startLine", .integer).notNull()
                t.column("endLine", .integer).notNull()
                t.column("snippet", .text).notNull()
                t.column("contextBefore", .text).notNull()
                t.column("contextAfter", .text).notNull()
                t.column("body", .text).notNull()
                t.column("state", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("sentAt", .datetime)
            }
        }
        // M3: the All files tab's state (FIL-01, FIL-03). Each workspace's expanded folders, worktree-relative, go with
        // it; each repository remembers Show Ignored Files, off by default.
        migrator.registerMigration("v10") { db in
            try db.create(table: "expandedFolder") { t in
                t.column("workspaceId", .text).notNull().references("workspace", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.primaryKey(["workspaceId", "path"])
            }
            try db.alter(table: "repo") { t in
                t.add(column: "showsIgnoredFiles", .boolean).notNull().defaults(to: false)
            }
        }
        return migrator
    }

    // MARK: Repos

    public func add(_ repo: Repo) throws {
        do {
            try db.write { try repo.insert($0) }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw RockyStoreError.duplicateRepo(repo.path)
        }
    }

    public func update(_ repo: Repo) throws {
        try db.write { try repo.update($0) }
    }

    public func repos() throws -> [Repo] {
        try db.read { try Repo.order(Column("createdAt"), Column("name")).fetchAll($0) }
    }

    /// `FIL-03`'s Show Ignored Files: this column only, so the repository's other settings are left as they are.
    public func setShowsIgnoredFiles(_ shows: Bool, repoId: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE repo SET showsIgnoredFiles = ? WHERE id = ?", arguments: [shows, repoId])
        }
    }

    /// Deletes the repo and, by cascade, its workspaces and transcripts. Files on disk are untouched.
    public func deleteRepo(id: String) throws {
        _ = try db.write { try Repo.deleteOne($0, key: id) }
    }

    // MARK: Workspaces

    public func add(_ workspace: Workspace) throws {
        try db.write { try workspace.insert($0) }
    }

    public func workspaces(repoId: String) throws -> [Workspace] {
        try db.read { try Workspace.filter(Column("repoId") == repoId).order(Column("createdAt"), Column("name")).fetchAll($0) }
    }

    public func update(_ workspace: Workspace) throws {
        try db.write { try workspace.update($0) }
    }

    /// Writes only the workspace's pull request columns, so a stale copy of the workspace never undoes a rename;
    /// nil clears them, hidden comment ids included.
    public func savePullRequest(_ stored: StoredPullRequest?, workspaceId: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let checks = try stored.map { String(decoding: try encoder.encode($0.checks), as: UTF8.self) }
        let hidden = try stored.map { String(decoding: try encoder.encode($0.hiddenCommentIds), as: UTF8.self) }
        let number = stored?.number
        let url = stored?.url.absoluteString
        let state = stored?.state
        let headerState = stored?.headerState
        let updatedAt = stored?.updatedAt
        try db.write { db in
            try db.execute(
                sql: "UPDATE workspace SET prNumber = ?, prUrl = ?, prState = ?, prHeaderState = ?, prChecks = ?, "
                    + "prUpdatedAt = ?, prHiddenCommentIds = ? WHERE id = ?",
                arguments: [number, url, state, headerState, checks, updatedAt, hidden, workspaceId]
            )
        }
    }

    public func deleteWorkspace(id: String) throws {
        _ = try db.write { try Workspace.deleteOne($0, key: id) }
    }

    /// First port block no workspace uses yet.
    public func nextPort() throws -> Int {
        try db.read { db in
            PortAllocator.next(taken: try Int.fetchAll(db, sql: "SELECT port FROM workspace WHERE port IS NOT NULL"))
        }
    }

    // MARK: The All files tab (FIL-01)

    /// The workspace's expanded folders, worktree-relative. Removing the workspace deletes them (cascade).
    public func expandedFolders(workspaceId: String) throws -> Set<String> {
        try db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT path FROM expandedFolder WHERE workspaceId = ?", arguments: [workspaceId]))
        }
    }

    /// Replaces the workspace's expanded folders with `paths`, in one transaction.
    public func setExpandedFolders(_ paths: Set<String>, workspaceId: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM expandedFolder WHERE workspaceId = ?", arguments: [workspaceId])
            for path in paths.sorted() {
                try db.execute(sql: "INSERT INTO expandedFolder (workspaceId, path) VALUES (?, ?)", arguments: [workspaceId, path])
            }
        }
    }

    // MARK: Repo variables

    public func repoVars(repoId: String) throws -> [RepoVar] {
        try db.read { try RepoVar.filter(Column("repoId") == repoId).order(Column("name")).fetchAll($0) }
    }

    /// Inserts, or replaces the variable with the same name in the repo (keeping its id and creation date).
    public func save(_ variable: RepoVar) throws {
        try db.write { db in
            var variable = variable
            let existing = try RepoVar
                .filter(Column("repoId") == variable.repoId && Column("name") == variable.name)
                .fetchOne(db)
            if let existing {
                variable.id = existing.id
                variable.createdAt = existing.createdAt
            }
            try variable.save(db)
        }
    }

    public func deleteRepoVar(repoId: String, name: String) throws {
        _ = try db.write { try RepoVar.filter(Column("repoId") == repoId && Column("name") == name).deleteAll($0) }
    }

    // MARK: Review comments (CMT-03)

    /// The workspace's comments on its diffs, oldest first. Removing the workspace deletes them (cascade).
    public func comments(workspaceId: String) throws -> [DiffCommentRecord] {
        try db.read {
            try DiffCommentRecord
                .filter(Column("workspaceId") == workspaceId)
                .order(Column("createdAt"), Column.rowID)
                .fetchAll($0)
        }
    }

    /// Inserts the comment, or replaces the one with its id.
    public func saveComment(_ comment: DiffCommentRecord) throws {
        try db.write { try comment.save($0) }
    }

    public func deleteComment(id: String) throws {
        _ = try db.write { try DiffCommentRecord.deleteOne($0, key: id) }
    }

    // MARK: Chat

    public func add(_ session: ChatSessionRecord) throws {
        try db.write { try session.insert($0) }
    }

    public func update(_ session: ChatSessionRecord) throws {
        try db.write { try session.update($0) }
    }

    public func latestSession(workspaceId: String, agent: String) throws -> ChatSessionRecord? {
        try db.read {
            try ChatSessionRecord
                .filter(Column("workspaceId") == workspaceId && Column("agent") == agent)
                .order(Column("createdAt").desc)
                .fetchOne($0)
        }
    }

    public func session(id: String) throws -> ChatSessionRecord? {
        try db.read { try ChatSessionRecord.fetchOne($0, key: id) }
    }

    /// The workspace's conversations whose tab is open, oldest first.
    /// Each workspace's task title for the sidebar (ROW-02): the title of its oldest open conversation that has one.
    public func conversationTitles() throws -> [String: String] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT workspaceId, title FROM chatSession WHERE closedAt IS NULL AND title IS NOT NULL ORDER BY createdAt, rowid"
            )
            var titles: [String: String] = [:]
            for row in rows {
                let workspaceId: String = row["workspaceId"]
                if titles[workspaceId] == nil { titles[workspaceId] = row["title"] }
            }
            return titles
        }
    }

    public func openConversations(workspaceId: String) throws -> [ChatSessionRecord] {
        try db.read {
            try ChatSessionRecord
                .filter(Column("workspaceId") == workspaceId && Column("closedAt") == nil)
                .order(Column("createdAt"))
                .fetchAll($0)
        }
    }

    /// The text of the conversation's first user message, for titling conversations saved before titles existed.
    public func firstUserMessage(sessionId: String) throws -> String? {
        try db.read {
            try String.fetchOne($0, sql: "SELECT text FROM chatMessage WHERE sessionId = ? AND kind = 'user' ORDER BY seq LIMIT 1", arguments: [sessionId])
        }
    }

    /// Appends with the next `seq`, or replaces the record with the same id (a tool call whose status changed).
    public func upsert(_ message: ChatMessageRecord) throws {
        try db.write { db in
            var message = message
            if let existing = try ChatMessageRecord.fetchOne(db, key: message.id) {
                message.seq = existing.seq
            } else {
                let maxSeq = try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM chatMessage WHERE sessionId = ?", arguments: [message.sessionId])
                message.seq = (maxSeq ?? 0) + 1
            }
            try message.save(db)
        }
    }

    public func messages(sessionId: String) throws -> [ChatMessageRecord] {
        try db.read { try ChatMessageRecord.filter(Column("sessionId") == sessionId).order(Column("seq")).fetchAll($0) }
    }
}
