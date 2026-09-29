import Foundation
import Testing
@testable import RockyKit

/// `GHL-04`, `GHL-05`, `GHL-06` and `KIT-14`'s attachments: their exact files, names and headings.
struct LinkAttachmentsTests {
    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private var issue: GitHubIssue {
        GitHubIssue(
            number: 154,
            title: "Refresh the button styles",
            url: URL(string: "https://github.com/owner/acme-platform/issues/154")!,
            state: .open,
            author: "jhzl1",
            createdAt: date("2026-09-20T15:30:00Z"),
            labels: ["ui", "design"],
            assignees: ["jhzl1"],
            body: "The components of the design system.\r\n\r\n- Buttons\r\n- Inputs\r\n",
            comments: [
                GitHubComment(author: "reviewer", createdAt: date("2026-09-21T08:00:00Z"), body: "Start with the buttons."),
                GitHubComment(author: "jhzl1", createdAt: date("2026-09-22T09:00:00Z"), body: "Done in #3700."),
            ]
        )
    }

    /// GHL-04's exact file: the heading GHL-06 reads, the facts, the description and every comment.
    @Test func anIssueIsGHL04sMarkdown() {
        let document = LinkAttachments.issue(issue)
        #expect(document.fileName == "[GITHUB]-154.md")
        #expect(document.markdown == """
            # #154 Refresh the button styles

            - URL: https://github.com/owner/acme-platform/issues/154
            - State: open
            - Author: @jhzl1, opened 2026-09-20
            - Labels: ui, design
            - Assignees: @jhzl1

            ## Description

            The components of the design system.

            - Buttons
            - Inputs

            ## Comments (2)

            ### @reviewer, 2026-09-21

            Start with the buttons.

            ### @jhzl1, 2026-09-22

            Done in #3700.

            """)
    }

    /// Over 100 comments, the file ends with how many more GitHub has; empty lists and no body say so plainly.
    @Test func moreCommentsThanFetchedEndWithHowManyMore() {
        let closed = GitHubIssue(
            number: 12,
            title: "Old",
            url: URL(string: "https://github.com/o/n/issues/12")!,
            state: .closed,
            stateReason: "not planned",
            author: "ghost",
            createdAt: date("2026-01-02T00:00:00Z"),
            body: "  ",
            comments: [GitHubComment(author: "a", createdAt: date("2026-01-03T00:00:00Z"), body: "First")],
            totalComments: 44
        )
        #expect(LinkAttachments.issue(closed).markdown == """
            # #12 Old

            - URL: https://github.com/o/n/issues/12
            - State: closed (not planned)
            - Author: @ghost, opened 2026-01-02

            ## Description

            No description provided.

            ## Comments (44)

            ### @a, 2026-01-03

            First

            …and 43 more comments on GitHub: https://github.com/o/n/issues/12

            """)
        let silent = GitHubIssue(number: 13, title: "Quiet", url: URL(string: "https://github.com/o/n/issues/13")!, state: .open, author: "a", createdAt: date("2026-01-02T00:00:00Z"), body: "Body")
        #expect(!LinkAttachments.issue(silent).markdown.contains("## Comments"))
    }

    /// GHL-05: a pull request is GHL-04's format with its branch and, for a draft, "Draft: yes".
    @Test func aPullRequestAddsItsBranchAndDraft() {
        let pull = GitHubIssue(
            number: 131,
            title: "Retry failed webhooks",
            url: URL(string: "https://github.com/owner/acme-platform/pull/131")!,
            state: .open,
            author: "jhzl1",
            createdAt: date("2026-09-22T10:00:00Z"),
            body: "Checks the flow.",
            pullRequest: .init(headRefName: "fix/webhook-retry", baseRefName: "development", isDraft: true, isCrossRepository: false)
        )
        let document = LinkAttachments.pullRequest(pull)
        #expect(document.fileName == "[GITHUB]-PR-131.md")
        #expect(document.markdown == """
            # #131 Retry failed webhooks

            - URL: https://github.com/owner/acme-platform/pull/131
            - State: open
            - Branch: fix/webhook-retry → development
            - Draft: yes
            - Author: @jhzl1, opened 2026-09-22

            ## Description

            Checks the flow.

            """)
    }

    /// GHL-05: a branch's file, "/" as "-" in its name, with its upstream and the commits the base lacks.
    @Test func aBranchListsItsCommitsTheBaseLacks() {
        let document = LinkAttachments.branch(
            name: "feat/button-styles",
            upstream: "origin/feat/button-styles",
            base: "origin/development",
            commits: ["a1b2c3d Add the buttons", "e4f5a6b Add the inputs"],
            total: 23
        )
        #expect(document.fileName == "[BRANCH]-feat-button-styles.md")
        #expect(document.markdown == """
            # feat/button-styles

            - Upstream: origin/feat/button-styles
            - Base: origin/development

            ## Commits not in origin/development (23)

            - a1b2c3d Add the buttons
            - e4f5a6b Add the inputs

            …and 21 older commits.

            """)
        let empty = LinkAttachments.branch(name: "spike", upstream: nil, base: "origin/main", commits: [], total: 0)
        #expect(empty.markdown.contains("- Upstream: none"))
        #expect(empty.markdown.contains("None: the branch has no commits of its own."))
    }

    /// KIT-14's `heading`: a document's number and title, and nothing for text without one.
    @Test func theHeadingIsTheNumberAndTheTitle() throws {
        let heading = try #require(LinkAttachments.heading(of: LinkAttachments.issue(issue).markdown))
        #expect(heading.number == 154)
        #expect(heading.title == "Refresh the button styles")
        #expect(LinkAttachments.heading(of: "Refresh the button styles") == nil)
        #expect(LinkAttachments.heading(of: "# feat/button-styles\n") == nil)
        #expect(LinkAttachments.heading(of: "") == nil)
        #expect(LinkAttachments.title(of: "# feat/button-styles\n\n- Upstream: none") == "feat/button-styles")
        #expect(LinkAttachments.title(of: "No heading") == nil)
    }

    /// Decision 4: the badge's mark comes from the name's prefix alone.
    @Test func theKindComesFromTheFileName() {
        #expect(LinkAttachments.kind(ofPath: "/tmp/Pasted/A/[GITHUB]-154.md") == .issue(154))
        #expect(LinkAttachments.kind(ofPath: "[GITHUB]-PR-131.md") == .pullRequest(131))
        #expect(LinkAttachments.kind(ofPath: "[BRANCH]-feat-button-styles.md") == .branch)
        for name in ["[GITHUB]-.md", "[GITHUB]-PR-x.md", "[GITHUB]-154.txt", "[BRANCH]-.md", "notes.md", "image.png"] {
            #expect(LinkAttachments.kind(ofPath: name) == nil, "\(name)")
        }
    }

    /// GHL-06: the first issue among a message's files names the workspace, read from the file; a pull request, a
    /// branch or a file gone name nothing.
    @Test func theFirstIssueFileGivesTheTitle() throws {
        let folder = try Fixtures.temporaryDirectory("links")
        let branch = try LinkAttachments.write(LinkAttachments.branch(name: "feat/x", upstream: nil, base: "origin/main", commits: [], total: 0), in: folder)
        let first = try LinkAttachments.write(LinkAttachments.issue(issue), in: folder)
        let second = try LinkAttachments.write(("[GITHUB]-9.md", "# #9 Second\n"), in: folder)

        #expect(LinkAttachments.issueTitle(attachments: [branch.path, first.path, second.path]) == "#154 Refresh the button styles")
        #expect(LinkAttachments.issueTitle(attachments: [branch.path]) == nil)
        #expect(LinkAttachments.issueTitle(attachments: [folder.appendingPathComponent("[GITHUB]-1.md").path]) == nil)
        #expect(LinkAttachments.title(ofFileAt: branch) == "feat/x")
    }

    /// The writer: a folder of its own for each file, which keeps the badge's name.
    @Test func eachFileGetsAFolderOfItsOwn() throws {
        let folder = try Fixtures.temporaryDirectory("pasted")
        let one = try PastedFiles.write(Data("a".utf8), named: "image.png", in: folder)
        let two = try PastedFiles.write(Data("b".utf8), named: "image.png", in: folder)
        #expect(one.lastPathComponent == "image.png")
        #expect(one.deletingLastPathComponent() != two.deletingLastPathComponent())
        #expect(one.deletingLastPathComponent().deletingLastPathComponent().path == folder.path)
        #expect(try Data(contentsOf: one) == Data("a".utf8))
        #expect(try Data(contentsOf: two) == Data("b".utf8))
    }
}
