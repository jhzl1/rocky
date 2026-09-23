import Foundation
import GRDB

public struct Repo: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repo"

    public var id: String
    public var name: String
    public var path: String
    /// Claude Code instance for this repo's agents (for example `~/.claude-celes`); nil uses Claude's default.
    public var claudeConfigDir: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, path: String, claudeConfigDir: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.claudeConfigDir = claudeConfigDir
        self.createdAt = createdAt
    }
}

public struct Workspace: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workspace"

    public var id: String
    public var repoId: String
    public var name: String
    public var path: String
    public var branch: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, repoId: String, name: String, path: String, branch: String, createdAt: Date = Date()) {
        self.id = id
        self.repoId = repoId
        self.name = name
        self.path = path
        self.branch = branch
        self.createdAt = createdAt
    }
}

public struct ChatSessionRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chatSession"

    public var id: String
    public var workspaceId: String
    public var agent: String
    /// ACP session id, used with `session/load` to resume; nil until the agent assigns one.
    public var acpSessionId: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, workspaceId: String, agent: String, acpSessionId: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.workspaceId = workspaceId
        self.agent = agent
        self.acpSessionId = acpSessionId
        self.createdAt = createdAt
    }
}

public struct ChatMessageRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chatMessage"

    public var id: String
    public var sessionId: String
    public var seq: Int
    public var kind: String
    public var text: String
    public var status: String?
    public var createdAt: Date

    public init(id: String, sessionId: String, seq: Int, kind: String, text: String, status: String?, createdAt: Date = Date()) {
        self.id = id
        self.sessionId = sessionId
        self.seq = seq
        self.kind = kind
        self.text = text
        self.status = status
        self.createdAt = createdAt
    }
}
