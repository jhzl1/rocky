import Foundation
import GRDB

public struct Repo: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repo"

    public var id: String
    public var name: String
    public var path: String
    /// Claude Code instance for this repo's agents (for example `~/.claude-celes`); nil uses Claude's default.
    public var claudeConfigDir: String?
    /// Scripts from Rocky's repo settings. A `conductor.json` at a workspace root replaces all of them there.
    public var setupScript: String?
    public var runScript: String?
    public var archiveScript: String?
    /// `RunScriptMode` raw value; nil means concurrent.
    public var runScriptMode: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        claudeConfigDir: String? = nil,
        setupScript: String? = nil,
        runScript: String? = nil,
        archiveScript: String? = nil,
        runScriptMode: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.claudeConfigDir = claudeConfigDir
        self.setupScript = setupScript
        self.runScript = runScript
        self.archiveScript = archiveScript
        self.runScriptMode = runScriptMode
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
    /// First of the ten ports this workspace owns (`PORT`, `CONDUCTOR_PORT`); see `PortAllocator`.
    public var port: Int?
    /// Ref the worktree was created from, for example `origin/main`. Unknown for workspaces made by M1.
    public var baseRef: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        repoId: String,
        name: String,
        path: String,
        branch: String,
        port: Int? = nil,
        baseRef: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.repoId = repoId
        self.name = name
        self.path = path
        self.branch = branch
        self.port = port
        self.baseRef = baseRef
        self.createdAt = createdAt
    }
}

/// A variable every process of the repo's workspaces gets (spec Section 3).
public struct RepoVar: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repoVar"

    public var id: String
    public var repoId: String
    public var name: String
    /// nil for a secret: its value lives in the Keychain (spec Section 5).
    public var value: String?
    public var isSecret: Bool
    public var createdAt: Date

    public init(id: String = UUID().uuidString, repoId: String, name: String, value: String?, isSecret: Bool, createdAt: Date = Date()) {
        self.id = id
        self.repoId = repoId
        self.name = name
        self.value = value
        self.isSecret = isSecret
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
