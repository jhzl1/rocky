import Foundation
import GRDB

public enum RockyStoreError: Error, Equatable {
    case duplicateRepo(String)
}

/// SQLite persistence for repos, workspaces and chat transcripts.
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

    private static var migrator: DatabaseMigrator {
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

    public func deleteWorkspace(id: String) throws {
        _ = try db.write { try Workspace.deleteOne($0, key: id) }
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
