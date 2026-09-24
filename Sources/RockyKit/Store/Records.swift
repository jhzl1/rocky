import Foundation
import GRDB

public struct Repo: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repo"

    public var id: String
    public var name: String
    public var path: String
    /// Claude Code instance for this repo's agents (for example `~/.claude-celes`); nil uses Claude's default.
    public var claudeConfigDir: String?
    /// Scripts from Rocky's repo settings. A `rocky.json` at a workspace root replaces all of them there.
    public var setupScript: String?
    public var runScript: String?
    public var archiveScript: String?
    /// `RunScriptMode` raw value; nil means concurrent.
    public var runScriptMode: String?
    /// Extra paths or globs `WorktreeLinker` links from the main clone into every new workspace, one per line. Added
    /// to the `links` of a `rocky.json`, not replaced by them.
    public var linkedPaths: String?
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
        linkedPaths: String? = nil,
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
        self.linkedPaths = linkedPaths
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
    /// First of the ten ports this workspace owns (`PORT`, `ROCKY_PORT`); see `PortAllocator`.
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
    /// The conversation's tab title, from its first message; nil until the user sends one.
    public var title: String?
    /// When its tab was closed. A closed conversation stays in the store.
    public var closedAt: Date?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        workspaceId: String,
        agent: String,
        acpSessionId: String? = nil,
        title: String? = nil,
        closedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.agent = agent
        self.acpSessionId = acpSessionId
        self.title = title
        self.closedAt = closedAt
        self.createdAt = createdAt
    }

    /// A tab title from a message: its first line without the file markers, cut to 40 characters.
    public static func title(from message: String) -> String {
        let text = message.replacingOccurrences(of: PromptAttachment.marker, with: "")
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        // A removed marker leaves two spaces behind.
        let trimmed = firstLine.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }

    /// A tab title from a message, or nil for a message that runs one of `commands` (TITLE-01): "/compact" or "/init"
    /// must not name the conversation, so the caller keeps looking for the first message that is not a command. A
    /// first token that names no command ("/notacommand hi") is an ordinary message and titles it.
    public static func title(from message: String, commands: [SlashCommand]) -> String? {
        SlashCommand.invoked(by: message, among: commands) == nil ? title(from: message) : nil
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
    /// File paths, stored as a JSON array; see `ChatItem.attachments`. nil for messages saved before v5.
    public var attachments: [String]?
    public var toolKind: String?
    public var createdAt: Date
    /// A user message's turn end; see `ChatItem.completedAt`.
    public var completedAt: Date?

    public init(
        id: String,
        sessionId: String,
        seq: Int,
        kind: String,
        text: String,
        status: String?,
        attachments: [String]? = nil,
        toolKind: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.seq = seq
        self.kind = kind
        self.text = text
        self.status = status
        self.attachments = attachments
        self.toolKind = toolKind
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}
