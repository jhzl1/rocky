import Foundation

/// The sidebar's search (SB-02): an inline filter over the rows, not a command palette.
public enum WorkspaceFilter {
    /// Whether a row matches `query`: a case-insensitive substring of its title, branch, workspace name or repository
    /// name. Surrounding spaces are ignored, and a query with nothing else matches every row.
    public static func matches(query: String, title: String, branch: String, name: String, repo: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return [title, branch, name, repo].contains { $0.range(of: needle, options: .caseInsensitive) != nil }
    }
}
