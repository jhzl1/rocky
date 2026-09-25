import Foundation
import Testing
@testable import RockyKit

/// CMT-05 (Review Focus 4): the agent's text for a line comment has exactly its format, on each side.
struct ReviewPromptTests {
    @Test func newSideLines() {
        let text = ReviewPrompt.single(
            path: "src/openapi.ts",
            side: .new,
            start: 18,
            end: 25,
            code: ["function operation(route: Route) {", "  …"],
            language: "ts",
            comment: "Use the route's name as operationId only when it is unique."
        )
        #expect(text == """
            Comment on src/openapi.ts, lines 18–25:
            ```ts
            function operation(route: Route) {
              …
            ```
            Use the route's name as operationId only when it is unique.
            """)
    }

    /// One line says "line", and a file Rocky does not highlight gets a bare fence; the comment keeps its lines.
    @Test func oneLineOfAPlainFile() {
        let text = ReviewPrompt.single(
            path: "Makefile",
            side: .new,
            start: 2,
            end: 2,
            code: ["\tswift test"],
            language: nil,
            comment: "Add a lint target.\nRun it in CI too."
        )
        #expect(text == """
            Comment on Makefile, line 2:
            ```
            \tswift test
            ```
            Add a lint target.
            Run it in CI too.
            """)
    }

    @Test func removedSideLines() {
        let text = ReviewPrompt.single(
            path: "src/openapi.ts",
            side: .old,
            start: 12,
            end: 13,
            code: ["  retry(times: 3)", "  log(route)"],
            language: "ts",
            comment: "Why did the retry go?"
        )
        #expect(text == """
            Comment on src/openapi.ts, removed lines 12–13 (from the base):
            ```ts
              retry(times: 3)
              log(route)
            ```
            Why did the retry go?
            """)
        #expect(ReviewPrompt.single(path: "a.swift", side: .old, start: 7, end: 7, code: ["x"], language: "swift", comment: "Gone?")
            .hasPrefix("Comment on a.swift, removed line 7 (from the base):\n"))
    }

    /// A CRLF file's lines lose their "\r"; code with a fence of its own gets a longer one.
    @Test func carriageReturnsGoAndAFenceInTheCodeGetsALongerOne() {
        let text = ReviewPrompt.single(
            path: "README.md",
            side: .new,
            start: 3,
            end: 5,
            code: ["```swift\r", "let a = 1\r", "```\r"],
            language: "md",
            comment: "Show the output too."
        )
        #expect(text == """
            Comment on README.md, lines 3–5:
            ````md
            ```swift
            let a = 1
            ```
            ````
            Show the output too.
            """)
    }

    /// CMT-05's Resend, all or nothing: lines that cannot be read give the block without code, on each side.
    @Test func noCodeOnTheNewSideGivesTheHeaderAndTheComment() {
        let text = ReviewPrompt.single(path: "src/openapi.ts", side: .new, start: 18, end: 25, code: nil, language: "ts", comment: "Still needed?")
        #expect(text == "Comment on src/openapi.ts, lines 18–25:\nStill needed?")
        #expect(ReviewPrompt.single(path: "a.swift", side: .new, start: 3, end: 3, code: nil, language: nil, comment: "Why?")
            == "Comment on a.swift, line 3:\nWhy?")
    }

    @Test func noCodeOnTheRemovedSideGivesTheHeaderAndTheComment() {
        let text = ReviewPrompt.single(path: "src/openapi.ts", side: .old, start: 12, end: 13, code: nil, language: "ts", comment: "Why did the retry go?")
        #expect(text == "Comment on src/openapi.ts, removed lines 12–13 (from the base):\nWhy did the retry go?")
    }

    /// Files attached next to a chip go as links after the block: in it, each one's marker reads as its name.
    @Test func filesInACommentReadAsTheirNames() {
        let marker = PromptAttachment.marker
        #expect(ReviewPrompt.comment("Like \(marker) and \(marker)?", naming: ["/tmp/a/shot.png", "/tmp/b.ts"]) == "Like shot.png and b.ts?")
        #expect(ReviewPrompt.comment("No files", naming: []) == "No files")
        #expect(ReviewPrompt.comment("\(marker) extra", naming: []) == " extra")
    }

    @Test func fenceLanguageIsTheExtensionOfAHighlightedFile() {
        #expect(ReviewPrompt.fenceLanguage(forPath: "src/openapi.ts") == "ts")
        #expect(ReviewPrompt.fenceLanguage(forPath: "Sources/App.SWIFT") == "swift")
        #expect(ReviewPrompt.fenceLanguage(forPath: "config/.zshrc") == "bash")
        #expect(ReviewPrompt.fenceLanguage(forPath: "Makefile") == nil)
        #expect(ReviewPrompt.fenceLanguage(forPath: "notes.txt") == nil)
    }
}
