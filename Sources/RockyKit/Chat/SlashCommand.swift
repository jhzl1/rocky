import Foundation

/// A command the conversation's agent announced over ACP (`available_commands_update`, KIT-01): Claude's built-in
/// commands, skills, the repository's custom commands and MCP prompts, or OpenCode's commands. There is no command
/// request in ACP: a command runs as an ordinary prompt whose text starts with "/name" (ACP-03). Rocky adds no
/// commands of its own (OUT-20).
public struct SlashCommand: Equatable, Sendable, Identifiable {
    /// Claude's adapter announces an MCP server's prompt "server:prompt (MCP)" as "mcp:server:prompt", and turns
    /// "/mcp:server:prompt" back when it receives the prompt (ACP-02). Rocky inserts the name as announced.
    public static let mcpPrefix = "mcp:"

    public var id: String { name }
    /// As announced, without the slash: "compact", "security-review", "mcp:linear:triage".
    public let name: String
    /// May be empty.
    public let description: String
    /// `input.hint`: what goes after the name ("<optional custom summarization instructions>"). nil for a command
    /// that takes no input; OpenCode never sends one.
    public let inputHint: String?

    public var isMCP: Bool { name.hasPrefix(Self.mcpPrefix) }
    /// `name` and `description` lowercased once, when the list arrives: `SlashCommandFilter` searches them on every
    /// keystroke.
    let foldedName: String
    let foldedDescription: String

    public init(name: String, description: String = "", inputHint: String? = nil) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
        foldedName = name.lowercased()
        foldedDescription = description.lowercased()
    }

    /// The name a sent message starts with: the text after its leading "/", up to the first whitespace or file.
    /// nil when the message does not start with "/" or the name is empty. It says nothing about whether the agent
    /// has that command; see `invoked(by:among:)`.
    public static func leadingName(in message: String) -> String? {
        guard message.hasPrefix("/") else { return nil }
        let name = message.dropFirst().prefix { !$0.isWhitespace && $0 != markerCharacter }
        return name.isEmpty ? nil : String(name)
    }

    private static let markerCharacter = Character(PromptAttachment.marker)

    /// The command a message runs: its first token is "/name" and `name` is one of `commands`. A message whose first
    /// token names no announced command ("/notacommand hi", "/tmp/log.txt") is an ordinary message.
    public static func invoked(by message: String, among commands: [SlashCommand]) -> SlashCommand? {
        guard let name = leadingName(in: message) else { return nil }
        return commands.first { $0.name == name }
    }
}

/// One of Claude Code's commands whose screen exists only in its own terminal (CMD-08). Over ACP they answer with a
/// single line ("Use /mcp in the terminal for details"), so Rocky never sends them to the agent: like Conductor, it
/// offers to run them in a terminal embedded above the message box. A fixed list, for Claude Code conversations only;
/// OpenCode's commands all go to the agent.
public struct TerminalOnlyCommand: Equatable, Sendable {
    /// The names, and the description the popup shows for one the agent did not announce (Conductor's wording).
    static let known: [(name: String, description: String)] = [
        ("mcp", "Manage MCP servers"),
        ("agents", "Manage agent configurations"),
        ("hooks", "Manage hook configurations for tool events"),
        ("memory", "Edit Claude memory files"),
        ("permissions", "Manage allow and deny tool permission rules"),
        ("plugins", "Manage plugins"),
    ]
    public static var names: [String] { known.map(\.name) }
    /// Ends the popup description of each of them.
    public static let descriptionSuffix = "(opens terminal)"

    public let name: String
    /// What followed the command in the message, on one line, file badges left out: Claude Code gets it with the
    /// command.
    public let arguments: String

    public init(name: String, arguments: String = "") {
        self.name = name
        self.arguments = arguments
    }

    /// "/mcp", as the strip and the terminal's header show it.
    public var label: String { "/" + name }

    /// Claude Code's argument: the command and its arguments, as if typed at its prompt.
    public var prompt: String { arguments.isEmpty ? label : label + " " + arguments }

    public static func isTerminalOnly(_ name: String, agent: AgentKind) -> Bool {
        agent == .claude && names.contains(name)
    }

    /// The terminal command a message runs: in a Claude Code conversation, its first token is "/name" with a name on
    /// the list. "/mcpx" and "/mcp:linear:triage" are not.
    public static func invoked(by message: String, agent: AgentKind) -> TerminalOnlyCommand? {
        guard let name = SlashCommand.leadingName(in: message), isTerminalOnly(name, agent: agent) else { return nil }
        let marker = Character(PromptAttachment.marker)
        let rest = message.dropFirst(1 + name.count)
        let arguments = rest.split { $0.isWhitespace || $0 == marker }.joined(separator: " ")
        return TerminalOnlyCommand(name: name, arguments: arguments)
    }

    /// The list the popup offers (CMD-08). In a Claude Code conversation the six commands say "(opens terminal)" and
    /// take no input, so Return on one opens the terminal instead of completing it; those the agent did not announce
    /// are added at the end. OpenCode's list is unchanged, and so is a list not known yet (none of the conversation's
    /// own and none cached), which keeps the popup's "Starting Claude Code…".
    public static func offered(_ commands: [SlashCommand], agent: AgentKind, confirmed: Bool) -> [SlashCommand] {
        guard agent == .claude, confirmed || !commands.isEmpty else { return commands }
        var offered = commands.map { command -> SlashCommand in
            guard names.contains(command.name) else { return command }
            let description = command.description.isEmpty ? defaultDescription(of: command.name) : command.description
            return SlashCommand(name: command.name, description: marked(description))
        }
        let announced = Set(commands.map(\.name))
        for (name, description) in known where !announced.contains(name) {
            offered.append(SlashCommand(name: name, description: marked(description)))
        }
        return offered
    }

    private static func defaultDescription(of name: String) -> String {
        known.first { $0.name == name }?.description ?? ""
    }

    private static func marked(_ description: String) -> String {
        description.isEmpty ? descriptionSuffix : description + " " + descriptionSuffix
    }
}

/// When the message box's popup opens, and on what (KIT-02). Offsets are UTF-16 units, as in `NSTextView`'s selected
/// range: file badges (`PromptAttachment.marker`) and emoji make them differ from `Character` offsets.
public enum SlashQuery {
    /// The query the popup filters on, the text between the leading "/" and the caret; nil when the popup must stay
    /// closed. It opens only while the text's first character is "/", no file badge comes before it, and the caret is
    /// inside the first token (after the "/", up to the first whitespace or badge). A "/" anywhere else is usually a
    /// path ("src/openapi.ts", "a / b"), and the adapters only run a prompt whose first text starts with "/".
    public static func parse(text: String, caret: Int, firstIsAttachment: Bool) -> String? {
        guard !firstIsAttachment, let token = tokenRange(in: text), caret >= 1, caret <= token.upperBound else { return nil }
        return String(decoding: text.utf16.dropFirst().prefix(caret - 1), as: UTF16.self)
    }

    /// The first token, "/" included, as a UTF-16 range: what choosing a command replaces. nil when the text does not
    /// start with "/".
    public static func tokenRange(in text: String) -> Range<Int>? {
        let units = text.utf16
        guard units.first == slash else { return nil }
        var end = 1
        for unit in units.dropFirst() {
            if endsToken(unit) { break }
            end += 1
        }
        return 0..<end
    }

    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let marker = PromptAttachment.marker.utf16.first!

    /// Whitespace (a newline included) or a file badge. A surrogate is part of a character outside the Basic
    /// Multilingual Plane, which is never whitespace.
    private static func endsToken(_ unit: UInt16) -> Bool {
        unit == marker || (Unicode.Scalar(unit)?.properties.isWhitespace ?? false)
    }
}

/// Filters and orders the announced commands for a query (KIT-03). Tiers, rather than fuzzy scoring, keep the order
/// predictable with the hundreds of commands a user with many skills gets.
public enum SlashCommandFilter {
    public struct Match: Equatable, Sendable {
        public let command: SlashCommand
        /// The part of the name that matched, in `Character` offsets into `command.name`, drawn in accent (CMD-02).
        /// nil for an empty query and for a match on the description only.
        public let nameRange: Range<Int>?

        public init(command: SlashCommand, nameRange: Range<Int>?) {
            self.command = command
            self.nameRange = nameRange
        }
    }

    /// The commands `query` finds, in the order the popup shows them.
    public static func rank(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
        matches(commands, query: query).map(\.command)
    }

    /// Case-insensitive. An empty query keeps every command in the announced order. Otherwise, in tiers, each in the
    /// announced order: (0) the name is the query, so "/mcp" and Return runs mcp and not an mcp:linear:triage
    /// announced before it; (1) the name starts with the query; (2) a segment of the name does, segments being split
    /// on ":", "-" and "_" ("rev" finds security-review, "tri" finds mcp:linear:triage); (3) the name contains it;
    /// (4) the description contains it. Nothing else matches.
    public static func matches(_ commands: [SlashCommand], query: String) -> [Match] {
        guard !query.isEmpty else { return commands.map { Match(command: $0, nameRange: nil) } }
        let needle = query.lowercased()
        var tiers: [[Match]] = [[], [], [], [], []]
        for command in commands {
            if let (tier, range) = nameMatch(command.foldedName, needle: needle) {
                tiers[tier].append(Match(command: command, nameRange: range))
            } else if firstOccurrence(of: needle, in: command.foldedDescription) != nil {
                tiers[4].append(Match(command: command, nameRange: nil))
            }
        }
        return tiers.flatMap { $0 }
    }

    private static let segmentSeparators: Set<UInt8> = [UInt8(ascii: ":"), UInt8(ascii: "-"), UInt8(ascii: "_")]

    /// The best tier the lowercased name reaches (0 to 3) and where, in `Character` offsets of the lowercased name,
    /// which match the name's for the names agents announce. The occurrences are visited left to right, so the first
    /// one at a segment start wins over an earlier one inside a segment.
    private static func nameMatch(_ name: String, needle: String) -> (tier: Int, range: Range<Int>)? {
        if name == needle { return (0, 0..<name.count) }
        var best: (tier: Int, offset: Int)?
        forEachOccurrence(of: needle, in: name) { offset, bytes in
            if offset == 0 || segmentSeparators.contains(bytes[offset - 1]) {
                best = (offset == 0 ? 1 : 2, offset)
                return false
            }
            if best == nil { best = (3, offset) }
            return true
        }
        guard let best else { return nil }
        let utf8 = name.utf8
        let lower = utf8.index(utf8.startIndex, offsetBy: best.offset)
        let upper = utf8.index(lower, offsetBy: needle.utf8.count)
        let start = name.distance(from: name.startIndex, to: lower)
        return (best.tier, start..<(start + name.distance(from: lower, to: upper)))
    }

    private static func firstOccurrence(of needle: String, in text: String) -> Int? {
        var first: Int?
        forEachOccurrence(of: needle, in: text) { offset, _ in
            first = offset
            return false
        }
        return first
    }

    /// Every UTF-8 offset where `needle` starts in `text`, left to right, until `visit` returns false. A byte search
    /// (`memmem`) of valid UTF-8 in valid UTF-8 only matches at character boundaries, and it costs one C call per
    /// string instead of a case-insensitive Foundation search, which took about 3 ms per ranking of 300 commands.
    private static func forEachOccurrence(of needle: String, in text: String, _ visit: (Int, UnsafeBufferPointer<UInt8>) -> Bool) {
        var text = text
        var needle = needle
        text.withUTF8 { bytes in
            needle.withUTF8 { pattern in
                guard let base = bytes.baseAddress, let patternBase = pattern.baseAddress, pattern.count <= bytes.count else { return }
                var start = 0
                while start <= bytes.count - pattern.count,
                      let found = memmem(base + start, bytes.count - start, patternBase, pattern.count) {
                    let offset = Int(bitPattern: found) - Int(bitPattern: base)
                    guard visit(offset, bytes) else { return }
                    start = offset + 1
                }
            }
        }
    }
}
