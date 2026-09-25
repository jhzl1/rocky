import Foundation

/// An app Rocky opens a worktree or a file in (`OPN-02`): Finder, or one of the Open menu's editors (`OPN-01`).
public enum OpenApp: Hashable, Sendable {
    case finder
    case editor(ExternalEditor)

    public static let finderBundleIdentifier = "com.apple.finder"

    /// What `DefaultOpenApp.storageKey` holds once this app is picked in the Open menu.
    public var bundleIdentifier: String {
        switch self {
        case .finder: Self.finderBundleIdentifier
        case .editor(let editor): editor.bundleIdentifier
        }
    }

    /// The name in the Open menu, in the split button's tooltip and in ⌘O's title ("Open in Zed").
    public var displayName: String {
        switch self {
        case .finder: "Finder"
        case .editor(let editor): editor.displayName
        }
    }
}

/// The default app (`OPN-02`): the last app picked in the Open menu, one for all of Rocky (user decision, 2026-09-24).
/// It drives the Open split button's left part (`TB-03`), ⌘O and the tab headers' path chip (`DIFF-01`). It is a
/// preference of this Mac, like the folded repositories, so it lives in `UserDefaults` and not in the database.
public enum DefaultOpenApp {
    /// `@AppStorage`'s key: the picked app's bundle identifier, Finder's or an editor's.
    public static let storageKey = "defaultOpenApp"

    /// The stored app when it is Finder or an installed editor. Otherwise (nothing stored, the stored editor no longer
    /// installed, or an identifier Rocky does not know) the first installed editor in `OPN-01`'s order, else Finder.
    /// The caller keeps the stored value as it is, so reinstalling the app brings it back. Pure: the caller looks the
    /// editors up each time it needs the default (the menu opening, a click, ⌘O), and nothing is cached.
    public static func resolve(stored: String?, installed: [ExternalEditor]) -> OpenApp {
        if stored == OpenApp.finderBundleIdentifier { return .finder }
        if let editor = installed.first(where: { $0.bundleIdentifier == stored }) { return .editor(editor) }
        let firstInstalled = ExternalEditor.allCases.first { installed.contains($0) }
        return firstInstalled.map(OpenApp.editor) ?? .finder
    }
}
