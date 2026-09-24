import Foundation

/// The editors the Open menu offers for a workspace's worktree (`OPN-01`), declared in the menu's alphabetical order.
/// Rocky opens the folder with the app itself, so no editor needs its command on the PATH.
public enum ExternalEditor: String, CaseIterable, Sendable {
    case antigravity, cursor, vscode, zed

    /// The name after "Open in".
    public var displayName: String {
        switch self {
        case .antigravity: "Antigravity"
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .zed: "Zed"
        }
    }

    /// Checked on this Mac on 2026-09-23. Antigravity installs as "Antigravity IDE.app"; Cursor's is its
    /// ToDesktop build id.
    public var bundleIdentifier: String {
        switch self {
        case .antigravity: "com.google.antigravity-ide"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .vscode: "com.microsoft.VSCode"
        case .zed: "dev.zed.Zed"
        }
    }

    /// The installed editors in the menu's order, each with its app. `lookup` answers a bundle identifier with the
    /// app's URL (`NSWorkspace.urlForApplication(withBundleIdentifier:)`), nil when it is not installed. The menu calls
    /// it each time it opens: nothing is cached, and nothing looks at rest.
    public static func installed(lookup: (String) -> URL?) -> [(editor: ExternalEditor, app: URL)] {
        allCases.compactMap { editor in
            lookup(editor.bundleIdentifier).map { (editor: editor, app: $0) }
        }
    }
}
