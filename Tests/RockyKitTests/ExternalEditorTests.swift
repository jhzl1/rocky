import Foundation
import Testing
@testable import RockyKit

struct ExternalEditorTests {
    /// OPN-01: the installed editors in alphabetical order, each with its app; a missing one has no item.
    @Test func installedKeepsTheMenuOrderAndDropsMissingApps() {
        let apps = [
            "dev.zed.Zed": URL(fileURLWithPath: "/Applications/Zed.app"),
            "com.microsoft.VSCode": URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            "com.google.antigravity-ide": URL(fileURLWithPath: "/Applications/Antigravity IDE.app"),
        ]
        var asked: [String] = []
        let installed = ExternalEditor.installed { identifier in
            asked.append(identifier)
            return apps[identifier]
        }

        #expect(installed.map { $0.editor } == [.antigravity, .vscode, .zed])
        #expect(installed.map { $0.app.lastPathComponent } == ["Antigravity IDE.app", "Visual Studio Code.app", "Zed.app"])
        // Every editor is looked up, Cursor included, each time the menu opens.
        #expect(asked == ExternalEditor.allCases.map(\.bundleIdentifier))
        #expect(ExternalEditor.installed { _ in nil }.isEmpty)
    }

    /// OPN-01's names, in the menu's alphabetical order, and the bundle identifiers checked on 2026-09-23.
    @Test func everyEditorHasABundleIdentifierAndAName() {
        #expect(ExternalEditor.allCases.map(\.displayName) == ["Antigravity", "Cursor", "VS Code", "Zed"])
        #expect(ExternalEditor.allCases.map(\.displayName) == ExternalEditor.allCases.map(\.displayName).sorted())
        #expect(ExternalEditor.allCases.map(\.bundleIdentifier) == [
            "com.google.antigravity-ide",
            "com.todesktop.230313mzl4w4u92",
            "com.microsoft.VSCode",
            "dev.zed.Zed",
        ])
        #expect(Set(ExternalEditor.allCases.map(\.bundleIdentifier)).count == ExternalEditor.allCases.count)
    }
}
