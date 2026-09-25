import Testing
@testable import RockyKit

/// OPN-02's default app, resolved from the stored bundle identifier and the editors installed at that moment.
struct DefaultOpenAppTests {
    @Test func theStoredEditorWinsWhileItIsInstalled() {
        let app = DefaultOpenApp.resolve(stored: "dev.zed.Zed", installed: [.cursor, .vscode, .zed])
        #expect(app == .editor(.zed))
        #expect(app.displayName == "Zed")
        #expect(app.bundleIdentifier == "dev.zed.Zed")
    }

    /// Nothing stored: the first installed editor in OPN-01's order, whatever order the list comes in.
    @Test func nothingStoredGivesTheFirstInstalledEditor() {
        #expect(DefaultOpenApp.resolve(stored: nil, installed: [.zed, .vscode]) == .editor(.vscode))
        #expect(DefaultOpenApp.resolve(stored: nil, installed: [.zed]) == .editor(.zed))
    }

    @Test func noEditorInstalledGivesFinder() {
        #expect(DefaultOpenApp.resolve(stored: nil, installed: []) == .finder)
        #expect(DefaultOpenApp.resolve(stored: "dev.zed.Zed", installed: []) == .finder)
    }

    /// The stored editor uninstalled: the same fallback, and since the stored value is left alone, the editor comes
    /// back as the default once it is installed again. An identifier Rocky does not know falls back the same way.
    @Test func anUninstalledStoredEditorFallsBackAndComesBackWhenReinstalled() {
        let stored = "dev.zed.Zed"
        #expect(DefaultOpenApp.resolve(stored: stored, installed: [.antigravity, .vscode]) == .editor(.antigravity))
        #expect(DefaultOpenApp.resolve(stored: stored, installed: [.antigravity, .vscode, .zed]) == .editor(.zed))
        #expect(DefaultOpenApp.resolve(stored: "com.example.Unknown", installed: [.cursor]) == .editor(.cursor))
    }

    @Test func finderStoredStaysFinderWithEditorsInstalled() {
        let app = DefaultOpenApp.resolve(stored: OpenApp.finderBundleIdentifier, installed: [.vscode, .zed])
        #expect(app == .finder)
        #expect(app.displayName == "Finder")
        #expect(app.bundleIdentifier == "com.apple.finder")
    }
}
