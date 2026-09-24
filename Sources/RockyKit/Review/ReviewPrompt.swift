import Foundation

/// `CMT-05`'s prompt: a workspace's pending review comments, numbered, each with its file, lines and code, as one
/// message to the agent.
public enum ReviewPrompt {
    /// The exact text of `CMT-05`, the comments in the order given:
    ///
    ///     Review comments on jhzl/openapi-export:
    ///
    ///     1. src/openapi.ts, lines 18–25
    ///     ```ts
    ///     function operation(route: Route) {
    ///     ```
    ///     Use the route's name as operationId only when it is unique.
    ///
    ///     Address each comment and say what you changed for each number.
    ///
    /// A removed-side comment says "(removed)" after its lines. `language` names each file's code block (nil leaves it
    /// bare); a snippet holding a fence of its own gets a longer one, so its block stays whole.
    public static func build(
        branch: String,
        comments: [DiffCommentRecord],
        language: (String) -> String? = ReviewPrompt.fenceLanguage(forPath:)
    ) -> String {
        var text = "Review comments on \(branch):\n"
        for (index, comment) in comments.enumerated() {
            let lines = comment.startLine == comment.endLine
                ? "line \(comment.startLine)"
                : "lines \(comment.startLine)–\(comment.endLine)"
            let side = comment.side == .old ? " (removed)" : ""
            // A CRLF file's lines keep their "\r" in the snippet; the prompt's lines end with "\n" alone.
            let code = comment.snippet.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: code) + 1))
            text += "\n\(index + 1). \(comment.path), \(lines)\(side)\n"
            text += fence + (language(comment.path) ?? "") + "\n"
            text += code.joined(separator: "\n") + "\n"
            text += fence + "\n"
            text += comment.body + "\n"
        }
        text += "\nAddress each comment and say what you changed for each number."
        return text
    }

    /// A code block's language: the file's extension when Rocky highlights the file ("ts" for `src/openapi.ts`, as in
    /// `CMT-05`), the grammar's name for a shell dotfile without one, else nil.
    public static func fenceLanguage(forPath path: String) -> String? {
        guard let grammar = SyntaxLanguage.language(forPath: path) else { return nil }
        // A dotfile's leading dot is its name, not an extension: ".zshrc" has none, ".eslintrc.json" has "json".
        let name = (path as NSString).lastPathComponent
        let stem = name.hasPrefix(".") ? String(name.dropFirst()) : name
        let ext = stem.contains(".") ? (stem as NSString).pathExtension.lowercased() : ""
        return ext.isEmpty ? grammar : ext
    }

    /// The most backticks in a row on any line.
    private static func longestBacktickRun(in lines: [String]) -> Int {
        var longest = 0
        for line in lines {
            var run = 0
            for character in line {
                run = character == "`" ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return longest
    }
}
