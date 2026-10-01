import Foundation
import Testing
@testable import RockyKit

/// An agent reply cut where its code blocks are, with lists kept whole (user decision, 2026-09-30).
struct MessageSegmentsTests {
    private func parse(_ markdown: String) throws -> AttributedString {
        try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full))
    }

    private func texts(_ segments: [MessageSegment]) -> [String] {
        segments.map { segment in
            switch segment {
            case .text(let string, let depth): "text(\(depth)): " + String(string.characters)
            case .code(let block): "code(\(block.listDepth), \(block.language ?? "-")): " + block.code
            }
        }
    }

    /// The ordinals and list items of a text segment's runs.
    private func listItems(_ segment: MessageSegment) -> [Int] {
        guard case .text(let string, _) = segment else { return [] }
        var ordinals: [Int] = []
        for run in string.runs {
            for component in run.presentationIntent?.components ?? [] {
                if case .listItem(let ordinal) = component.kind, !ordinals.contains(ordinal) { ordinals.append(ordinal) }
            }
        }
        return ordinals
    }

    @Test func aCodeBlockBetweenParagraphsIsItsOwnSegment() throws {
        let segments = MessageSegments.split(try parse("""
            Run this:

            ```swift
            let x = 42
            print(x)
            ```

            Then check the output.
            """))
        #expect(texts(segments) == [
            "text(0): Run this:",
            "code(0, swift): let x = 42\nprint(x)",
            "text(0): Then check the output.",
        ])
    }

    @Test func aBlockWithoutALanguageAndTwoInARow() throws {
        let segments = MessageSegments.split(try parse("""
            ```
            one
            ```

            ```json
            {"two": 2}
            ```
            """))
        #expect(texts(segments) == ["code(0, -): one", "code(0, json): {\"two\": 2}"])
    }

    /// The case of the user's report: a block inside item 2 of a numbered list, text after it in the same item, then
    /// item 3. The item's text after the block loses its list, so its number is not drawn again, and item 3 keeps 3.
    @Test func aBlockInsideAListItemKeepsTheListWhole() throws {
        let segments = MessageSegments.split(try parse("""
            Two options:

            1. **Run them.** The three commands.
            2. **Give me permission.** Add this rule:

               ```json
               "Bash(pnpm exec supabase db push:*)"
               ```

               Or I add it myself.
            3. **Wait.** Nothing happens.
            """))
        #expect(texts(segments).count == 4)
        guard segments.count == 4 else { return }
        #expect(texts(segments)[1] == "code(1, json): \"Bash(pnpm exec supabase db push:*)\"")
        #expect(listItems(segments[0]) == [1, 2])
        // Item 2 goes on, indented one level, with no list item of its own.
        #expect(texts(segments)[2] == "text(1): Or I add it myself.")
        #expect(listItems(segments[2]).isEmpty)
        #expect(listItems(segments[3]) == [3])
    }

    @Test func aHintNamesItsGrammar() {
        #expect(SyntaxLanguage.language(forHint: "json") == "json")
        #expect(SyntaxLanguage.language(forHint: "TypeScript") == "typescript")
        #expect(SyntaxLanguage.language(forHint: "ts") == "typescript")
        #expect(SyntaxLanguage.language(forHint: "shell") == "bash")
        #expect(SyntaxLanguage.language(forHint: "swift title=\"a.swift\"") == "swift")
        #expect(SyntaxLanguage.language(forHint: "text") == nil)
        #expect(SyntaxLanguage.language(forHint: nil) == nil)
    }
}
