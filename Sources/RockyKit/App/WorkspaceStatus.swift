import Foundation

/// A workspace's state in the sidebar (ROW-03): one glyph per row; when several apply, the first case wins. Pull
/// requests (open, merged) come later between `unread` and `idle` (OUT-02).
public enum WorkspaceStatus: Equatable, Sendable {
    /// An agent waits on a permission or a question.
    case needsYou
    /// An agent stopped on an error, or the Setup script failed; the text is the row's tooltip.
    case failed(String)
    case working
    /// A turn ended while the workspace was not on screen (ROW-04).
    case unread
    case idle

    public static func resolve(needsYou: Bool, failure: String?, working: Bool, unread: Bool) -> WorkspaceStatus {
        if needsYou { return .needsYou }
        if let failure { return .failed(failure) }
        if working { return .working }
        if unread { return .unread }
        return .idle
    }

    /// For a repository folded in the sidebar (SB-04): the most urgent state among its workspaces.
    public static func mostUrgent(_ statuses: [WorkspaceStatus]) -> WorkspaceStatus {
        statuses.min { $0.rank < $1.rank } ?? .idle
    }

    private var rank: Int {
        switch self {
        case .needsYou: 0
        case .failed: 1
        case .working: 2
        case .unread: 3
        case .idle: 4
        }
    }
}
