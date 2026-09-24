import Foundation

/// The right panel's tabs (`PNL-03`), in the row's order. The row is drawn from `allCases`, so M3's Changes tab
/// (`CHG-01`) joins it, before Checks, without changing the panel's layout.
public enum RightPanelTab: String, CaseIterable, Sendable {
    case checks

    public var title: String {
        switch self {
        case .checks: "Checks"
        }
    }
}

/// Whether the panel's agent buttons can send their prompt to the workspace's selected conversation (`AGT-00`).
/// A prompt never waits in the message queue (user decision): while the turn runs, the buttons are disabled.
public enum AgentActionAvailability: Equatable, Sendable {
    case available
    /// The selected conversation's turn is running.
    case working
    /// Its agent stopped (on an error, or it was stopped): it cannot take a prompt until restarted.
    case stopped

    /// The disabled buttons' tooltip.
    public var reason: String? {
        switch self {
        case .available: nil
        case .working: "The agent is working"
        case .stopped: "Restart the agent first"
        }
    }
}

/// Rocky's own pull request actions that take a moment (`PR-07`'s "Rocky action"). While one runs, its button shows a
/// spinner and a second click does nothing.
public enum PullRequestAction: Hashable, Sendable {
    /// `GST-03`.
    case pull, push
    /// `CHK-02`.
    case rerun
    /// `GST-02`.
    case pullFromBase
    /// `AGT-03`'s log downloads, before the prompt goes out.
    case fixErrors
    /// `PR-05`'s merge mutation.
    case merge
    /// `PR-08`.
    case readyForReview
    /// `PR-06`'s archive: the archive script, then the worktree's removal.
    case archive
}
