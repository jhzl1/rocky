import AppKit
import RockyKit
import SwiftUI
import Textual

/// An agent's reply: its Markdown parsed once, then drawn in pieces (`MessageSegments`), the text by Textual and each
/// code block by `ReplyCodeBlock`, outside Textual's selection layer, so the block's Copy button, its sideways
/// scrolling and its selection work (user decision, 2026-09-30).
struct AgentReplyView: View {
    let text: String
    private let segments: [IdentifiedSegment]

    /// A list's text indent: Textual's marker, 1.5 em wide, and its 0.5 em spacing, at the chat's 14 points.
    static let listIndent: CGFloat = 28

    struct IdentifiedSegment: Identifiable {
        let id: Int
        let segment: MessageSegment
    }

    init(text: String) {
        self.text = text
        let parsed = (try? RockyMarkdownParser(zoom: Zoom.shared.scale).attributedString(for: text)) ?? AttributedString(text)
        segments = MessageSegments.split(parsed).enumerated().map { IdentifiedSegment(id: $0.offset, segment: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments) { piece in
                switch piece.segment {
                case .text(let string, let depth):
                    StructuredText(String(string.characters), parser: PreparsedMarkup(string: string))
                        .textual.structuredTextStyle(RockyMarkdownStyle())
                        .textual.textSelection(.enabled)
                        .padding(.leading, Zoom.shared(Self.listIndent) * CGFloat(depth))
                case .code(let block):
                    ReplyCodeBlock(block: block)
                        .padding(.leading, Zoom.shared(Self.listIndent) * CGFloat(block.listDepth))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hands Textual a piece of a reply already parsed: `StructuredText` asks its parser again only when the text changes.
private struct PreparsedMarkup: MarkupParser {
    let string: AttributedString

    func attributedString(for input: String) throws -> AttributedString {
        string
    }
}

/// A code block of a reply: the language and a Copy button over the code, which keeps its lines and scrolls sideways
/// when they are long, the side with code out of view fading, and selects and copies with ⌘C (SwiftUI's own
/// selection). Colors come from the diff's highlighter (`SyntaxHighlighter`, DIFF-04).
struct ReplyCodeBlock: View {
    let block: CodeBlockSegment
    @State private var highlighted: AttributedString?
    @State private var hidden = HiddenEdges()
    @State private var copied = false

    /// Which sides have code out of view.
    struct HiddenEdges: Equatable {
        var leading = false
        var trailing = false
    }

    /// How wide the fade is where code is hidden.
    private static let fade: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(block.language ?? "text")
                    .font(.rocky(10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                // One box for both glyphs: the checkmark is shorter than doc.on.doc, and the header shrank when it
                // showed (user report, 2026-09-30).
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.rocky(12))
                        .frame(width: Zoom.shared(16), height: Zoom.shared(16))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .clickable()
                .help(copied ? "Copied" : "Copy the code")
                .accessibilityLabel(copied ? "Copied" : "Copy")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Rectangle().fill(Markdown.border).frame(height: 1)
            ScrollView(.horizontal) {
                Text(highlighted ?? AttributedString(block.code))
                    .font(.rocky(12.5, design: .monospaced))
                    .lineSpacing(Zoom.shared(3))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(14)
                    // Only a crossing of an edge changes the state, not every frame of a scroll.
                    .onGeometryChange(for: HiddenEdges.self) { proxy in
                        let frame = proxy.frame(in: .scrollView)
                        let visible = proxy.bounds(of: .scrollView)?.width ?? frame.width
                        return HiddenEdges(leading: frame.minX < -1, trailing: frame.maxX > visible + 1)
                    } action: { hidden = $0 }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            // No scroller over the code: its knob and the track it grows on hover covered the last line (user
            // report, 2026-09-30). The fading edge is the cue that more is there.
            .scrollIndicators(.hidden)
            .mask {
                GeometryReader { geometry in
                    let fraction = geometry.size.width > 0 ? min(0.4, Self.fade / geometry.size.width) : 0
                    LinearGradient(
                        stops: [
                            .init(color: hidden.leading ? .clear : .black, location: 0),
                            .init(color: .black, location: fraction),
                            .init(color: .black, location: 1 - fraction),
                            .init(color: hidden.trailing ? .clear : .black, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }
        }
        .background(Markdown.blockBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Markdown.border))
        .task(id: block) { await highlight() }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(block.code, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func highlight() async {
        guard let language = SyntaxLanguage.language(forHint: block.language) else {
            highlighted = nil
            return
        }
        let tokens = await SyntaxHighlighter.shared.tokens(for: block.code, language: language)
        guard !Task.isCancelled else { return }
        highlighted = HighlightedLine.attributed(block.code, tokens: tokens)
    }
}
