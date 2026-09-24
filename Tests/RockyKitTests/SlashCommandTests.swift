import Foundation
import Testing
@testable import RockyKit

/// KIT-02: when the popup opens, and on what.
struct SlashQueryTests {
    private let badge = PromptAttachment.marker

    private func parse(_ text: String, caret: Int? = nil, firstIsAttachment: Bool = false) -> String? {
        SlashQuery.parse(text: text, caret: caret ?? text.utf16.count, firstIsAttachment: firstIsAttachment)
    }

    @Test func opensOnASlashAtTheStart() {
        #expect(parse("/") == "")
        #expect(parse("/rev", caret: 4) == "rev")
        #expect(parse("/rev", caret: 1) == "")
        #expect(parse("/rev", caret: 2) == "r")
    }

    /// Review Focus 3: a "/" anywhere else is usually a path.
    @Test func aSlashThatIsNotAtTheStartNeverOpensIt() {
        #expect(parse("src/foo") == nil)
        #expect(parse(" /rev") == nil)
        #expect(parse("a / b") == nil)
        #expect(parse("look at src/openapi.ts") == nil)
        #expect(parse("\(badge)/rev", firstIsAttachment: true) == nil)
        #expect(parse("\(badge) /rev") == nil)
    }

    @Test func closesOnceTheCaretLeavesTheFirstToken() {
        #expect(parse("/review 12", caret: 10) == nil)
        #expect(parse("/review ", caret: 8) == nil)
        #expect(parse("/rev\nmore", caret: 6) == nil)
        #expect(parse("/rev", caret: 0) == nil)
        // Back inside the token, the arguments after it stay where they are.
        #expect(parse("/review 12", caret: 3) == "re")
    }

    @Test func aFileBadgeEndsTheToken() {
        #expect(parse("/rev\(badge)", caret: 5) == nil)
        #expect(SlashQuery.tokenRange(in: "/rev\(badge) x") == 0..<4)
    }

    /// Offsets are UTF-16 units, as NSTextView's selected range counts them.
    @Test func countsInUTF16Units() {
        #expect(parse("/😀a", caret: 3) == "😀")
        #expect(parse("/😀a", caret: 4) == "😀a")
        #expect(SlashQuery.tokenRange(in: "/😀a b") == 0..<4)
        #expect(SlashQuery.tokenRange(in: "/review 12") == 0..<7)
        #expect(SlashQuery.tokenRange(in: "review") == nil)
    }

    @Test func readsTheCommandASentMessageRuns() {
        let commands = [SlashCommand(name: "compact"), SlashCommand(name: "mcp:linear:triage")]
        #expect(SlashCommand.leadingName(in: "/compact") == "compact")
        #expect(SlashCommand.leadingName(in: "/mcp:linear:triage web") == "mcp:linear:triage")
        #expect(SlashCommand.leadingName(in: "/ hi") == nil)
        #expect(SlashCommand.leadingName(in: "hi /compact") == nil)
        #expect(SlashCommand.invoked(by: "/mcp:linear:triage web", among: commands)?.name == "mcp:linear:triage")
        #expect(SlashCommand.invoked(by: "/compactly", among: commands) == nil)
        #expect(SlashCommand.invoked(by: "/tmp/log.txt", among: commands) == nil)
    }
}

/// KIT-03: filtering and order.
struct SlashCommandFilterTests {
    private let commands = [
        SlashCommand(name: "security-review", description: "Review the pending changes on the current branch"),
        SlashCommand(name: "review", description: "Review a pull request"),
        SlashCommand(name: "mcp:linear:triage", description: "Triage an issue", inputHint: "<issue>"),
        SlashCommand(name: "preview_build", description: "Build a preview"),
        SlashCommand(name: "compact", description: "Clear conversation history but keep a summary"),
        SlashCommand(name: "release", description: "Cut a release and write its notes"),
    ]

    private func names(_ query: String) -> [String] {
        SlashCommandFilter.rank(commands, query: query).map(\.name)
    }

    @Test func anEmptyQueryKeepsTheAnnouncedOrder() {
        #expect(names("") == commands.map(\.name))
        #expect(SlashCommandFilter.matches(commands, query: "").allSatisfy { $0.nameRange == nil })
    }

    @Test func ranksPrefixThenSegmentThenSubstring() {
        // review starts with "rev", security-review has a segment that does, preview_build only contains it.
        #expect(names("rev") == ["review", "security-review", "preview_build"])
        #expect(names("REV") == ["review", "security-review", "preview_build"])
        #expect(names("tri") == ["mcp:linear:triage"])
        #expect(names("lin") == ["mcp:linear:triage"])
    }

    @Test func tiesKeepTheAnnouncedOrder() {
        #expect(names("re") == ["review", "release", "security-review", "preview_build"])
    }

    @Test func aQueryMatchingOnlyDescriptions() {
        #expect(names("notes") == ["release"])
        #expect(SlashCommandFilter.matches(commands, query: "notes").first?.nameRange == nil)
        #expect(names("pull request") == ["review"])
    }

    /// KIT-03 tier 0 (CMD-08): "/mcp" and Return runs mcp, not an mcp:linear:triage announced before it that also
    /// starts with "mcp".
    @Test func anExactNameRanksFirst() {
        let announced = [SlashCommand(name: "mcp:linear:triage", inputHint: "<issue>"), SlashCommand(name: "mcp")]
        let matches = SlashCommandFilter.matches(announced, query: "mcp")
        #expect(matches.map(\.command.name) == ["mcp", "mcp:linear:triage"])
        #expect(matches.first?.nameRange == 0..<3)
        #expect(SlashCommandFilter.rank(announced, query: "MCP").first?.name == "mcp")
    }

    @Test func nothingElseMatches() {
        #expect(names("xyz").isEmpty)
        #expect(names("rvw").isEmpty)
    }

    /// CMD-02 draws this part of the name in accent.
    @Test func reportsTheMatchedPartOfTheName() {
        let ranges = SlashCommandFilter.matches(commands, query: "rev").map(\.nameRange)
        #expect(ranges == [0..<3, 9..<12, 1..<4])
        #expect(SlashCommandFilter.matches(commands, query: "tri").first?.nameRange == 11..<14)
        // A segment start later in the name wins over an earlier occurrence inside a segment.
        let reply = SlashCommandFilter.matches([SlashCommand(name: "prepare-reply")], query: "re")
        #expect(reply.first?.nameRange == 8..<10)
    }

    @Test func rankingThreeHundredCommandsTakesUnderFiveMilliseconds() {
        let description = String(repeating: "Runs one of the skills this machine has installed, with its own instructions. ", count: 3)
        let many = (0..<300).map { SlashCommand(name: "skill-\($0)-helper:tool_\($0 % 7)", description: description) }
        let clock = ContinuousClock()
        _ = SlashCommandFilter.matches(many, query: "hel")
        // The best of three runs, so a busy test machine does not decide it; each run ranks a matching and a missing
        // query, the second of which reads every description.
        let best = (0..<3).map { _ in
            clock.measure {
                _ = SlashCommandFilter.matches(many, query: "hel")
                _ = SlashCommandFilter.matches(many, query: "zzz")
            }
        }.min()!
        #expect(best < .milliseconds(5))
        #expect(SlashCommandFilter.matches(many, query: "hel").count == 300)
    }
}

/// CMD-08: Claude Code's terminal commands.
struct TerminalOnlyCommandTests {
    private let badge = PromptAttachment.marker

    @Test func theListIsFixed() {
        #expect(TerminalOnlyCommand.names == ["mcp", "agents", "hooks", "memory", "permissions", "plugins"])
    }

    @Test func aMessageRunsOneWhenItsFirstTokenIsOnTheList() {
        #expect(TerminalOnlyCommand.invoked(by: "/mcp", agent: .claude) == TerminalOnlyCommand(name: "mcp"))
        for name in TerminalOnlyCommand.names {
            #expect(TerminalOnlyCommand.invoked(by: "/\(name)", agent: .claude)?.name == name)
        }
        let withArguments = TerminalOnlyCommand.invoked(by: "/mcp extra args", agent: .claude)
        #expect(withArguments == TerminalOnlyCommand(name: "mcp", arguments: "extra args"))
        #expect(withArguments?.label == "/mcp")
        #expect(withArguments?.prompt == "/mcp extra args")
        #expect(TerminalOnlyCommand(name: "hooks").prompt == "/hooks")
        // The arguments go to Claude Code on one line, without the files the message box had.
        #expect(TerminalOnlyCommand.invoked(by: "/hooks\(badge) list\n  all", agent: .claude)?.arguments == "list all")
    }

    @Test func nothingElseRunsOne() {
        #expect(TerminalOnlyCommand.invoked(by: "/mcpx", agent: .claude) == nil)
        #expect(TerminalOnlyCommand.invoked(by: "/mcp:linear:triage web", agent: .claude) == nil)
        #expect(TerminalOnlyCommand.invoked(by: "/compact", agent: .claude) == nil)
        #expect(TerminalOnlyCommand.invoked(by: "mcp", agent: .claude) == nil)
        #expect(TerminalOnlyCommand.invoked(by: "use /mcp", agent: .claude) == nil)
        // OpenCode's commands all go to its agent.
        #expect(TerminalOnlyCommand.invoked(by: "/mcp", agent: .opencode) == nil)
        #expect(!TerminalOnlyCommand.isTerminalOnly("mcp", agent: .opencode))
    }

    /// The popup marks them "(opens terminal)", takes no input on them (Return opens the terminal) and adds those the
    /// agent did not announce, after its own.
    @Test func thePopupListMarksAndAddsThem() {
        let announced = [
            SlashCommand(name: "compact", description: "Clear conversation history", inputHint: "<instructions>"),
            SlashCommand(name: "mcp", description: "Manage MCP servers", inputHint: "<server>"),
            SlashCommand(name: "hooks"),
        ]
        let offered = TerminalOnlyCommand.offered(announced, agent: .claude, confirmed: true)
        #expect(offered.map(\.name) == ["compact", "mcp", "hooks", "agents", "memory", "permissions", "plugins"])
        #expect(offered[0] == announced[0])
        #expect(offered[1].description == "Manage MCP servers (opens terminal)")
        #expect(offered[1].inputHint == nil)
        // An empty description gets Rocky's.
        #expect(offered[2].description == "Manage hook configurations for tool events (opens terminal)")
        #expect(offered.last?.description == "Manage plugins (opens terminal)")
        #expect(offered.dropFirst().allSatisfy { $0.description.hasSuffix(TerminalOnlyCommand.descriptionSuffix) })
    }

    @Test func thePopupListIsUnchangedForOpenCodeAndWhileUnknown() {
        let announced = [SlashCommand(name: "init", description: "create/update AGENTS.md")]
        #expect(TerminalOnlyCommand.offered(announced, agent: .opencode, confirmed: true) == announced)
        // "Starting Claude Code…" stays until a list is known.
        #expect(TerminalOnlyCommand.offered([], agent: .claude, confirmed: false).isEmpty)
        // A cached list, or an empty list of the conversation's own, gets them.
        #expect(TerminalOnlyCommand.offered(announced, agent: .claude, confirmed: false).map(\.name) == ["init"] + TerminalOnlyCommand.names)
        #expect(TerminalOnlyCommand.offered([], agent: .claude, confirmed: true).map(\.name) == TerminalOnlyCommand.names)
    }
}
