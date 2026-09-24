import Foundation
import Testing
@testable import RockyKit

/// EDIT-02's prompt, the same words for a tab that closes and for Rocky quitting with unsaved edits.
struct UnsavedChangesPromptTests {
    private func editor(_ file: String, workspace: String = "w1", title: String = "Fix login") -> UnsavedEditor {
        UnsavedEditor(workspaceId: workspace, path: "/w/\(workspace)/\(file)", file: file, workspaceTitle: title)
    }

    /// One file is named, with Save; several are counted, with Save All, and name their workspaces when they are in
    /// more than one.
    @Test func oneFileIsNamedAndSeveralAreCounted() {
        let one = [editor("src/api/openapi.ts")]
        #expect(UnsavedChangesPrompt.title(for: one, quitting: false) == "Save changes to openapi.ts?")
        #expect(UnsavedChangesPrompt.message(for: one) == "src/api/openapi.ts\n\nYour edits are lost if you don’t save them.")
        #expect(UnsavedChangesPrompt.saveTitle(count: one.count) == "Save")

        let sameWorkspace = [editor("a.ts"), editor("b.ts")]
        #expect(UnsavedChangesPrompt.title(for: sameWorkspace, quitting: true) == "Save changes to 2 files before quitting?")
        #expect(UnsavedChangesPrompt.message(for: sameWorkspace) == "a.ts\nb.ts\n\nYour edits are lost if you don’t save them.")
        #expect(UnsavedChangesPrompt.saveTitle(count: sameWorkspace.count) == "Save All")

        let twoWorkspaces = [editor("a.ts"), editor("b.ts", workspace: "w2", title: "Docs")]
        #expect(UnsavedChangesPrompt.message(for: twoWorkspaces) == "a.ts · Fix login\nb.ts · Docs\n\nYour edits are lost if you don’t save them.")
    }

    /// A long list names eight files and counts the rest.
    @Test func theListNamesEightFilesAndCountsTheRest() {
        let files = (1...10).map { editor("f\($0).ts") }
        let lines = UnsavedChangesPrompt.message(for: files).components(separatedBy: "\n")
        #expect(Array(lines.prefix(9)) == (1...8).map { "f\($0).ts" } + ["and 2 more"])
    }
}
