import Foundation
import Testing
@testable import RockyKit

/// Every agent prompt's exact text, copied from its requirement in the M2.7 design with the base filled in.
struct AgentPromptsTests {
    @Test func createPullRequestIsAGT01() {
        #expect(AgentPrompts.createPullRequest(base: "development", draft: false) == "Create a pull request for this branch. First commit any uncommitted changes and push with `git push -u origin HEAD`. Then run `gh pr create --base development` with a title under 80 characters and a description of at most five sentences. If the repository has a pull request template, fill it in.")
    }

    @Test func createDraftPullRequestAddsDraft() {
        #expect(AgentPrompts.createPullRequest(base: "main", draft: true) == "Create a pull request for this branch. First commit any uncommitted changes and push with `git push -u origin HEAD`. Then run `gh pr create --base main --draft` with a title under 80 characters and a description of at most five sentences. If the repository has a pull request template, fill it in.")
    }

    @Test func commitAndPushIsAGT02() {
        #expect(AgentPrompts.commitAndPush() == "Commit and push all changes.")
    }

    @Test func fixFailingChecksIsAGT03() {
        #expect(AgentPrompts.fixFailingChecks(notes: []) == "Fix the failing CI actions. I've attached the failure logs.")
        let notes = [
            AgentPrompts.checkNote(name: "e2e / webkit", detail: "The job was not started because\nyour account is locked."),
            AgentPrompts.checkNote(name: "ci/jenkins", detail: "https://jenkins.example.com/job/42"),
        ]
        #expect(AgentPrompts.fixFailingChecks(notes: notes) == """
            Fix the failing CI actions. I've attached the failure logs.

            e2e / webkit: The job was not started because your account is locked.
            ci/jenkins: https://jenkins.example.com/job/42
            """)
    }

    @Test func resolveConflictsFollowsPullRebase() {
        #expect(AgentPrompts.resolveConflicts(base: "development", rebase: true) == "Rebase your branch onto the remote branch (origin/development) and resolve the conflicts. Then push with `git push --force-with-lease`.")
        #expect(AgentPrompts.resolveConflicts(base: "development", rebase: false) == "Merge the remote branch (origin/development) into your branch and resolve the conflicts. Then commit and push your changes.")
    }

    @Test func resolveIncompatibilityIsAGT06() {
        #expect(AgentPrompts.resolveIncompatibility() == "Resolve branch incompatibility with remote.")
    }

    @Test func pullFromTheBaseIsGST02() {
        #expect(AgentPrompts.commitThenBringInBase(base: "development") == "Commit your changes, then bring in origin/development and push.")
        #expect(AgentPrompts.bringInBase(base: "development", rebase: false) == "Merge origin/development into this branch. Then push.")
        #expect(AgentPrompts.bringInBase(base: "development", rebase: true) == "Rebase this branch onto origin/development. Then push --force-with-lease.")
    }

    /// AGT-05's example, verbatim.
    @Test func reviewCommentsIsAGT05sExample() {
        let comments = [
            PendingComment(
                id: "PRRT_1",
                kind: .thread,
                author: "ana",
                body: "Use exponential backoff instead of a fixed delay.",
                path: "src/ocr/retry.ts",
                line: 42,
                replies: [
                    PendingComment.Reply(author: "jhzl", body: "Would a jitter help too?"),
                    PendingComment.Reply(author: "ana", body: "Yes, add full jitter."),
                ]
            ),
            PendingComment(id: "IC_1", kind: .conversation, author: "ana", body: "Please add a test for the timeout path."),
            PendingComment(id: "PRR_1", kind: .review, author: "ana", body: "Split the retry policy out of the OCR client."),
        ]
        #expect(AgentPrompts.reviewComments(number: 4512, comments: comments) == """
            Review comments on pull request #4512:

            1. ana on src/ocr/retry.ts, line 42
            > Use exponential backoff instead of a fixed delay.
            > jhzl: Would a jitter help too?
            > ana: Yes, add full jitter.

            2. ana (conversation)
            > Please add a test for the timeout path.

            3. ana (review)
            > Split the retry policy out of the OCR client.

            Address each comment and say what you changed for each number.
            """)
    }

    @Test func reviewCommentsQuoteEveryLineAndNameAFileWithoutALine() {
        let comments = [
            PendingComment(id: "PRRT_2", kind: .thread, author: "ana", body: "Rename this file.\r\nIt holds the client.\r\n", path: "src/ocr/client.ts"),
        ]
        #expect(AgentPrompts.reviewComments(number: 7, comments: comments) == """
            Review comments on pull request #7:

            1. ana on src/ocr/client.ts
            > Rename this file.
            > It holds the client.

            Address each comment and say what you changed for each number.
            """)
    }
}
