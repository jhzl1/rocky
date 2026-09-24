import Foundation

/// A file whose editor has unsaved edits (`EDIT-02`): what closing its tab, or quitting Rocky, asks about.
public struct UnsavedEditor: Equatable, Sendable, Identifiable {
    public let workspaceId: String
    /// Absolute: the file's key in `AppModel.editors`.
    public let path: String
    /// The file as the prompt lists it: worktree-relative for a worktree file, else its path with "~" for the home
    /// folder.
    public let file: String
    /// The workspace's sidebar title, for a list that spans several workspaces.
    public let workspaceTitle: String

    public init(workspaceId: String, path: String, file: String, workspaceTitle: String) {
        self.workspaceId = workspaceId
        self.path = path
        self.file = file
        self.workspaceTitle = workspaceTitle
    }

    public var id: String { workspaceId + "\u{0}" + path }

    /// The file's name, which the prompt's title uses for a single file.
    public var name: String { (path as NSString).lastPathComponent }
}

/// The words of the unsaved edits prompt, the same for a tab that closes and for Rocky quitting: "Save changes to
/// openapi.ts?" over the files, with Save (Save All for several), Don't Save and Cancel.
public enum UnsavedChangesPrompt {
    /// The files listed by name; the rest are counted.
    static let listLimit = 8

    public static func title(for editors: [UnsavedEditor], quitting: Bool) -> String {
        let subject = editors.count == 1 ? editors[0].name : "\(editors.count) files"
        return "Save changes to \(subject)\(quitting ? " before quitting" : "")?"
    }

    /// One line per file, each with its workspace when they are in several, then what not saving does.
    public static func message(for editors: [UnsavedEditor]) -> String {
        let namesWorkspaces = Set(editors.map(\.workspaceId)).count > 1
        var lines = editors.prefix(listLimit).map { namesWorkspaces ? "\($0.file) · \($0.workspaceTitle)" : $0.file }
        if editors.count > listLimit { lines.append("and \(editors.count - listLimit) more") }
        return lines.joined(separator: "\n") + "\n\nYour edits are lost if you don’t save them."
    }

    /// "Save" for one file, "Save All" for several.
    public static func saveTitle(count: Int) -> String {
        count == 1 ? "Save" : "Save All"
    }
}
