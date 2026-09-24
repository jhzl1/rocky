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
    /// Extra paths or globs `WorktreeLinker` links from the main clone into every new workspace, one per line, and
    /// `!<pattern>` lines turning one of its defaults off (`LinkedPaths`). Added to the `links` of a `rocky.json`, not
    /// replaced by them.
    public var linkedPaths: String?
    /// The repository's GitHub account (`ACC-01`); nil is the default: the login equal to the remote's owner, else
    /// gh's active account.
    public var githubLogin: String?
    /// The monogram's color in `Theme.repoPalette` (SB-03), picked at random among the colors the other repositories
    /// use least when the repository is added (`RepoMonogram.pickColor`); nil for a repository from before colors
    /// were stored, which gets one on the next launch.
    public var colorIndex: Int?
    /// `FIL-03`'s Show Ignored Files in the All files tab: git-ignored entries shown dimmed. Off by default. Toggled
    /// through `RockyStore.setShowsIgnoredFiles`, a column-only update; `AppModel` keeps its own copy current, so the
    /// whole-row updates of the other settings write it back as it is.
    public var showsIgnoredFiles: Bool
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
        githubLogin: String? = nil,
        colorIndex: Int? = nil,
        showsIgnoredFiles: Bool = false,
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
        self.githubLogin = githubLogin
        self.colorIndex = colorIndex
        self.showsIgnoredFiles = showsIgnoredFiles
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
    /// The last pull request state Rocky saw (`PR-07`), for other workspaces and the next launch. Written only by
    /// `RockyStore.savePullRequest`; read through `storedPullRequest`.
    public var prNumber: Int?
    public var prUrl: String?
    /// "OPEN", "DRAFT" or "MERGED".
    public var prState: String?
    /// A `HeaderState` raw value.
    public var prHeaderState: String?
    /// JSON `[PullRequestCheck]`.
    public var prChecks: String?
    public var prUpdatedAt: Date?
    /// JSON `[String]`: the GitHub node ids of the comments hidden with Hide (`REV-01`).
    public var prHiddenCommentIds: String?

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

    /// The pull request columns as one value; nil while any of the required ones is missing.
    public var storedPullRequest: StoredPullRequest? {
        guard let prNumber, let url = prUrl.flatMap({ URL(string: $0) }), let prState, let prHeaderState, let prUpdatedAt else {
            return nil
        }
        let decoder = JSONDecoder()
        return StoredPullRequest(
            number: prNumber,
            url: url,
            state: prState,
            headerState: prHeaderState,
            checks: prChecks.flatMap { try? decoder.decode([PullRequestCheck].self, from: Data($0.utf8)) } ?? [],
            updatedAt: prUpdatedAt,
            hiddenCommentIds: prHiddenCommentIds.flatMap { try? decoder.decode([String].self, from: Data($0.utf8)) } ?? []
        )
    }
}

/// A workspace's last pull request state, kept in its `pr*` columns (`PR-07`).
public struct StoredPullRequest: Codable, Equatable, Sendable {
    public var number: Int
    public var url: URL
    /// "OPEN", "DRAFT" or "MERGED".
    public var state: String
    /// A `HeaderState` raw value.
    public var headerState: String
    public var checks: [PullRequestCheck]
    public var updatedAt: Date
    public var hiddenCommentIds: [String]

    public init(number: Int, url: URL, state: String, headerState: String, checks: [PullRequestCheck], updatedAt: Date, hiddenCommentIds: [String] = []) {
        self.number = number
        self.url = url
        self.state = state
        self.headerState = headerState
        self.checks = checks
        self.updatedAt = updatedAt
        self.hiddenCommentIds = hiddenCommentIds
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

/// A review comment on a range of a diff tab's lines (`CMT-03`), which the user sends to the agent (`CMT-05`). It goes
/// with its workspace.
public struct DiffCommentRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "diffComment"

    /// The side of the diff a comment's lines are on (`CMT-01`): the worktree file's lines, which added and context rows
    /// show, or the base's, which removed rows show. A range never mixes them.
    public enum Side: String, Codable, Sendable, DatabaseValueConvertible {
        case new, old
    }

    /// `CMT-02`'s chips. A pending comment waits for Send to agent; an outdated one lost its lines (`CMT-04`).
    public enum State: String, Codable, Sendable, DatabaseValueConvertible {
        case pending, sent, outdated
    }

    public var id: String
    public var workspaceId: String
    /// Worktree-relative, like the diff tab's path.
    public var path: String
    public var side: Side
    /// 1-based and inclusive, numbered on `side`. `CommentAnchor` moves them as the worktree file changes (`CMT-04`);
    /// an outdated comment keeps its last ones.
    public var startLine: Int
    public var endLine: Int
    /// The commented lines as they were when the comment was written: what `CommentAnchor` looks for after each change,
    /// and the code block of the review prompt. A CRLF file's lines keep their `\r`, as the diff's do.
    public var snippet: [String]
    /// Up to `CommentAnchor.contextLineCount` lines above and below the snippet, kept with it (`CMT-03`).
    public var contextBefore: [String]
    public var contextAfter: [String]
    public var body: String
    public var state: State
    public var createdAt: Date
    /// When Send to agent sent it; nil while it has not been sent.
    public var sentAt: Date?

    public init(
        id: String = UUID().uuidString,
        workspaceId: String,
        path: String,
        side: Side,
        startLine: Int,
        endLine: Int,
        snippet: [String],
        contextBefore: [String] = [],
        contextAfter: [String] = [],
        body: String,
        state: State = .pending,
        createdAt: Date = Date(),
        sentAt: Date? = nil
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.path = path
        self.side = side
        self.startLine = startLine
        self.endLine = endLine
        self.snippet = snippet
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.body = body
        self.state = state
        self.createdAt = createdAt
        self.sentAt = sentAt
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
