import Foundation

/// The right panel's tabs (`PNL-03`), in the row's order. The row is drawn from `allCases`: M3's All files tab
/// (`FIL-01`) first, then its Changes tab (`CHG-01`), then Checks.
public enum RightPanelTab: String, CaseIterable, Sendable {
    case files
    case changes
    case checks

    public var title: String {
        switch self {
        case .files: "All files"
        case .changes: "Changes"
        case .checks: "Checks"
        }
    }
}

/// A git failure of the Changes tab (`ERR-02`), shown there with the last lines of its stderr. A diff failure goes
/// away with the next diff that works; a discard failure stays until the next discard or its ×.
public struct ChangesFailure: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case diff, discard
    }

    public let action: Action
    public let message: String

    public init(action: Action, message: String) {
        self.action = action
        self.message = message
    }
}

/// `GIT-04`'s commit sheet while its commit runs, and after it failed until the sheet closes: the message it was
/// given, so a sheet that went away with its tab comes back with it, what git and the hooks wrote, and the failure
/// (`ERR-02`). A commit that worked leaves none.
public struct CommitProgress: Equatable, Sendable {
    public let subject: String
    public let description: String
    /// The output, its last `maxLines` lines: a hook that runs a test suite can print thousands.
    public private(set) var lines: [String] = []
    /// "git commit exited 1", or why git did not run; nil while the commit runs.
    public private(set) var failure: String?

    public static let maxLines = 500

    public init(subject: String, description: String) {
        self.subject = subject
        self.description = description
    }

    public var isRunning: Bool { failure == nil }

    public mutating func append(_ newLines: [String]) {
        lines += newLines
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    public mutating func fail(_ message: String) {
        failure = message
    }
}

/// A diff tab's two modes (`DIFF-01`): the read-only unified diff, and the editor (`EDIT-01`, Task 9).
public enum DiffTabMode: String, Sendable {
    case diff, edit
}

/// `DIFF-05`: a diff tab asked to show its first hunk. `serial` grows with each request, so asking twice for the same
/// file scrolls twice.
public struct DiffScrollRequest: Equatable, Sendable {
    public let path: String
    public let serial: Int

    public init(path: String, serial: Int) {
        self.path = path
        self.serial = serial
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
