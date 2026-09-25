import Foundation

/// `CMT-05`'s text for the agent: one comment on a diff's lines with their code, the one text block of the message
/// that carries the comment.
public enum ReviewPrompt {
    /// The exact text of `CMT-05`:
    ///
    ///     Comment on src/openapi.ts, lines 18–25:
    ///     ```ts
    ///     function operation(route: Route) {
    ///     ```
    ///     Use the route's name as operationId only when it is unique.
    ///
    /// One line says "line 18"; the removed side says "removed lines 12–13 (from the base)" over the base's code. `path`
    /// is worktree-relative. `language` names the code block (nil leaves it bare; `fenceLanguage(forPath:)` gives it),
    /// and code holding a fence of its own gets a longer one, so its block stays whole. A CRLF file's lines keep their
    /// "\r" in the diff; the prompt's lines end with "\n" alone.
    ///
    /// nil `code` gives the block without one, the header and the comment: `CMT-05`'s Resend when a line of the range
    /// can no longer be read, which sends no code at all rather than part of it (designer's update, 2026-09-25).
    public static func single(
        path: String,
        side: CommentLine.Side,
        start: Int,
        end: Int,
        code: [String]?,
        language: String?,
        comment: String
    ) -> String {
        let lines = start == end ? "line \(start)" : "lines \(start)–\(end)"
        let range = side == .old ? "removed \(lines) (from the base)" : lines
        var text = "Comment on \(path), \(range):\n"
        guard let read = code else { return text + comment }
        let code = read.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: code) + 1))
        text += fence + (language ?? "") + "\n"
        if !code.isEmpty { text += code.joined(separator: "\n") + "\n" }
        text += fence + "\n"
        text += comment
        return text
    }

    /// A comment's text for its block when files sat in it (`CMT-05`'s Resend, files attached next to the chip): each
    /// `PromptAttachment.marker` reads as its file's name. The files go as links after the block, which is one text
    /// block never split at a marker, so a marker left in it would reach the agent as a stray character.
    public static func comment(_ text: String, naming files: [String]) -> String {
        var names = files.map { ($0 as NSString).lastPathComponent }[...]
        return text.components(separatedBy: PromptAttachment.marker).enumerated().map { index, part in
            index == 0 ? part : (names.popFirst() ?? "") + part
        }.joined()
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
