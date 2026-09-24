import Testing
@testable import RockyKit

/// `DIFF-04`: the language from a file's extension, and the tokenizer's ranges over a joined text cut into the lines
/// the diff draws.
struct SyntaxTokensTests {
    @Test func languageFollowsTheExtension() {
        #expect(SyntaxLanguage.language(forPath: "src/api/openapi.ts") == "typescript")
        #expect(SyntaxLanguage.language(forPath: "App.TSX") == "tsx")
        #expect(SyntaxLanguage.language(forPath: "Sources/Rocky/RockyApp.swift") == "swift")
        #expect(SyntaxLanguage.language(forPath: "README.md") == "markdown")
        #expect(SyntaxLanguage.language(forPath: "Cargo.toml") == "toml")
        #expect(SyntaxLanguage.language(forPath: "index.html") == "markup")
        #expect(SyntaxLanguage.language(forPath: "scripts/make-app.sh") == "bash")
        #expect(SyntaxLanguage.language(forPath: ".zshrc") == "bash")
        // Unknown: plain text.
        #expect(SyntaxLanguage.language(forPath: "Makefile") == nil)
        #expect(SyntaxLanguage.language(forPath: "notes.txt") == nil)
    }

    /// A block comment over two lines gives each line its piece; offsets restart at each line.
    @Test func splitCutsATokenAtEachLineEnd() {
        let lines = ["let a = 1 /* x", "y */ b"]
        let tokens = [
            SyntaxToken(range: 0..<3, kind: .keyword),
            SyntaxToken(range: 8..<9, kind: .number),
            SyntaxToken(range: 10..<19, kind: .comment),
        ]
        #expect(SyntaxToken.split(tokens, lines: lines) == [
            [SyntaxToken(range: 0..<3, kind: .keyword), SyntaxToken(range: 8..<9, kind: .number), SyntaxToken(range: 10..<14, kind: .comment)],
            [SyntaxToken(range: 0..<4, kind: .comment)],
        ])
    }

    /// Ranges are UTF-16, as JavaScript counts: "😀" is two units, "é" one.
    @Test func splitCountsUTF16Units() {
        let lines = ["é😀 x", "y"]
        let tokens = [SyntaxToken(range: 4..<5, kind: .function), SyntaxToken(range: 6..<7, kind: .string)]
        #expect(SyntaxToken.split(tokens, lines: lines) == [
            [SyntaxToken(range: 4..<5, kind: .function)],
            [SyntaxToken(range: 0..<1, kind: .string)],
        ])
    }

    /// A token that is only the newline between two lines, or that starts on an empty line, draws nothing there.
    @Test func newlinesAndEmptyLinesGetNoPieces() {
        let lines = ["ab", "", "cd"]
        let tokens = [SyntaxToken(range: 2..<3, kind: .comment), SyntaxToken(range: 3..<6, kind: .string)]
        #expect(SyntaxToken.split(tokens, lines: lines) == [[], [], [SyntaxToken(range: 0..<2, kind: .string)]])
    }
}
