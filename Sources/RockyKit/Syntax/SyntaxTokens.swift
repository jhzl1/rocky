import Foundation

/// What a token of code is, for its color (`DIFF-04`, `TOK-10`'s `syntax`): one map for the diff and the editor.
/// The raw values are the ones the tokenizer's script returns.
public enum SyntaxKind: Int, Sendable, CaseIterable {
    case plain, keyword, string, number, comment, function, type
}

/// A colored span of a tokenized text. `range` is in UTF-16 code units, the unit of JavaScript's strings, from the
/// start of the text that was tokenized.
public struct SyntaxToken: Equatable, Sendable {
    public let range: Range<Int>
    public let kind: SyntaxKind

    public init(range: Range<Int>, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }

    /// `tokens` of `lines` joined with "\n", cut at the line ends: one list per line, each range relative to the start
    /// of its line. A token over several lines (a block comment) gives a piece to each; newlines get none. Tokens
    /// must come in order and not overlap, as the tokenizer returns them.
    public static func split(_ tokens: [SyntaxToken], lines: [String]) -> [[SyntaxToken]] {
        var result = Array(repeating: [SyntaxToken](), count: lines.count)
        let lengths = lines.map(\.utf16.count)
        // The line the next token starts on, and where that line starts in the joined text.
        var lineIndex = 0
        var lineStart = 0
        for token in tokens {
            while lineIndex < lines.count, token.range.lowerBound > lineStart + lengths[lineIndex] {
                lineStart += lengths[lineIndex] + 1
                lineIndex += 1
            }
            var index = lineIndex
            var start = token.range.lowerBound
            var indexStart = lineStart
            while index < lines.count, start < token.range.upperBound {
                let lineEnd = indexStart + lengths[index]
                let end = min(token.range.upperBound, lineEnd)
                if end > start {
                    result[index].append(SyntaxToken(range: (start - indexStart)..<(end - indexStart), kind: token.kind))
                }
                // Past this line's newline, onto the next line.
                indexStart = lineEnd + 1
                start = max(start, indexStart)
                index += 1
            }
        }
        return result
    }
}

/// The Prism grammar for a file (`DIFF-04`: the language comes from the extension; unknown is plain text).
public enum SyntaxLanguage {
    private static let byExtension: [String: String] = [
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "tsx": "tsx",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "jsx",
        "json": "json", "jsonc": "json",
        "swift": "swift",
        "py": "python",
        "go": "go",
        "rs": "rust",
        "css": "css",
        "html": "markup", "htm": "markup", "xml": "markup", "svg": "markup", "plist": "markup",
        "yaml": "yaml", "yml": "yaml",
        "toml": "toml",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "md": "markdown", "markdown": "markdown", "mdx": "markdown",
        "sql": "sql",
    ]

    /// The grammar's name in the bundle, or nil for plain text.
    public static func language(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if let language = byExtension[ext] { return language }
        // Shell dotfiles have no extension of their own.
        return [".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile"].contains(name) ? "bash" : nil
    }
}
