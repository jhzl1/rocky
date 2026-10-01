import Foundation

/// One fenced code block of an agent reply, drawn apart from the text around it.
public struct CodeBlockSegment: Equatable, Sendable {
    public let code: String
    /// The fence's info string ("json", "swift"), nil without one.
    public let language: String?
    /// How many list items the block sits in: the view indents it as the list indents its items' text.
    public let listDepth: Int

    public init(code: String, language: String?, listDepth: Int) {
        self.code = code
        self.language = language
        self.listDepth = listDepth
    }
}

/// A piece of an agent reply: its parsed text, or one of its code blocks.
public enum MessageSegment: Equatable {
    /// Blocks of parsed Markdown. `listDepth` is the indent of a list item's text that goes on after a code block:
    /// its list items are taken out, so the list's marker is not drawn a second time, and the view indents it instead.
    case text(AttributedString, listDepth: Int)
    case code(CodeBlockSegment)
}

/// Cuts a parsed reply where its code blocks are (user decision, 2026-09-30). Textual draws the text, and its selection
/// layer covers everything it draws, so a code block's Copy button never got a click, and its sideways scrolling broke
/// selection (Textual issues #40 and #49). Drawn apart, a block has a working button, scrolling and its own selection.
/// Lists keep their numbers, since each item carries its ordinal from the one parse of the whole reply.
public enum MessageSegments {
    public static func split(_ string: AttributedString) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var text = AttributedString()
        var continuation = AttributedString()
        var continuationDepth = 0
        /// The list items the last code block sat in: the text right after it that is in them goes on the same item.
        var openItems: Set<Int> = []
        var code: (identity: Int, text: String, language: String?, depth: Int, items: Set<Int>)?

        func flushText() {
            if !text.characters.isEmpty { segments.append(.text(text, listDepth: 0)) }
            text = AttributedString()
        }
        func flushContinuation() {
            if !continuation.characters.isEmpty { segments.append(.text(continuation, listDepth: continuationDepth)) }
            continuation = AttributedString()
            continuationDepth = 0
        }
        func flushCode() {
            guard let block = code else { return }
            var body = block.text
            if body.hasSuffix("\n") { body.removeLast() }
            segments.append(.code(CodeBlockSegment(code: body, language: block.language, listDepth: block.depth)))
            openItems = block.items
            code = nil
        }

        for run in string.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first { if case .codeBlock = $0.kind { true } else { false } }
            if let block {
                if code?.identity != block.identity {
                    flushCode()
                    flushContinuation()
                    flushText()
                    let items = Set(components.filter(\.isListItem).map(\.identity))
                    var language: String?
                    if case .codeBlock(let hint) = block.kind { language = hint.flatMap { $0.isEmpty ? nil : $0 } }
                    code = (block.identity, "", language, items.count, items)
                }
                code?.text += String(string[run.range].characters)
                continue
            }
            flushCode()
            let shared = components.filter { $0.isListItem && openItems.contains($0.identity) }
            if !shared.isEmpty, text.characters.isEmpty {
                var piece = AttributedString(string[run.range])
                piece.presentationIntent = Self.intent(components, without: Set(shared.map(\.identity)))
                continuation += piece
                continuationDepth = shared.count
            } else {
                flushContinuation()
                openItems = []
                text += AttributedString(string[run.range])
            }
        }
        flushCode()
        flushContinuation()
        flushText()
        return segments
    }

    /// `components`, innermost first, without the list items in `items` and the lists that hold them.
    static func intent(_ components: [PresentationIntent.IntentType], without items: Set<Int>) -> PresentationIntent? {
        var kept: [PresentationIntent.IntentType] = []
        var skipsParentList = false
        for component in components {
            if component.isListItem, items.contains(component.identity) {
                skipsParentList = true
                continue
            }
            if skipsParentList, component.isList {
                skipsParentList = false
                continue
            }
            skipsParentList = false
            kept.append(component)
        }
        var rebuilt: PresentationIntent?
        for component in kept.reversed() {
            rebuilt = PresentationIntent(component.kind, identity: component.identity, parent: rebuilt)
        }
        return rebuilt
    }
}

extension PresentationIntent.IntentType {
    var isListItem: Bool {
        if case .listItem = kind { return true }
        return false
    }

    var isList: Bool {
        switch kind {
        case .orderedList, .unorderedList: true
        default: false
        }
    }
}
