import Foundation
import Testing
@testable import RockyKit

/// CMT-05 (Review Focus 4): the review prompt has exactly its format.
struct ReviewPromptTests {
    private static func comment(
        path: String,
        side: DiffCommentRecord.Side = .new,
        lines: ClosedRange<Int>,
        snippet: [String],
        body: String
    ) -> DiffCommentRecord {
        DiffCommentRecord(
            workspaceId: "w1",
            path: path,
            side: side,
            startLine: lines.lowerBound,
            endLine: lines.upperBound,
            snippet: snippet,
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    @Test func formatForOneAndSeveralComments() {
        let operation = Self.comment(
            path: "src/openapi.ts",
            lines: 18...25,
            snippet: ["function operation(route: Route) {", "  …"],
            body: "Use the route's name as operationId only when it is unique."
        )
        #expect(ReviewPrompt.build(branch: "jhzl/openapi-export", comments: [operation]) == """
            Review comments on jhzl/openapi-export:

            1. src/openapi.ts, lines 18–25
            ```ts
            function operation(route: Route) {
              …
            ```
            Use the route's name as operationId only when it is unique.

            Address each comment and say what you changed for each number.
            """)

        let removed = Self.comment(
            path: "Sources/App.swift",
            side: .old,
            lines: 7...7,
            snippet: ["    retry(times: 3)"],
            body: "Why did the retry go?\nIt covered flaky uploads."
        )
        let makefile = Self.comment(path: "Makefile", lines: 2...3, snippet: ["test:", "\tswift test"], body: "Add a lint target.")
        #expect(ReviewPrompt.build(branch: "rocky/lisbon", comments: [operation, removed, makefile]) == """
            Review comments on rocky/lisbon:

            1. src/openapi.ts, lines 18–25
            ```ts
            function operation(route: Route) {
              …
            ```
            Use the route's name as operationId only when it is unique.

            2. Sources/App.swift, line 7 (removed)
            ```swift
                retry(times: 3)
            ```
            Why did the retry go?
            It covered flaky uploads.

            3. Makefile, lines 2–3
            ```
            test:
            \tswift test
            ```
            Add a lint target.

            Address each comment and say what you changed for each number.
            """)
    }

    /// A CRLF file's snippet loses its "\r"; a snippet with a fence of its own gets a longer one.
    @Test func carriageReturnsGoAndAFenceInTheSnippetGetsALongerOne() {
        let readme = Self.comment(path: "README.md", lines: 3...5, snippet: ["```swift\r", "let a = 1\r", "```\r"], body: "Show the output too.")
        #expect(ReviewPrompt.build(branch: "main", comments: [readme]) == """
            Review comments on main:

            1. README.md, lines 3–5
            ````md
            ```swift
            let a = 1
            ```
            ````
            Show the output too.

            Address each comment and say what you changed for each number.
            """)
    }

    @Test func fenceLanguageIsTheExtensionOfAHighlightedFile() {
        #expect(ReviewPrompt.fenceLanguage(forPath: "src/openapi.ts") == "ts")
        #expect(ReviewPrompt.fenceLanguage(forPath: "Sources/App.SWIFT") == "swift")
        #expect(ReviewPrompt.fenceLanguage(forPath: "config/.zshrc") == "bash")
        #expect(ReviewPrompt.fenceLanguage(forPath: "Makefile") == nil)
        #expect(ReviewPrompt.fenceLanguage(forPath: "notes.txt") == nil)
    }
}
