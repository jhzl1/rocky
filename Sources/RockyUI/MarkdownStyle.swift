import AppKit
import SwiftUI
import Textual

/// Markdown as Textual parses it, except that inline code becomes `InlineCodeAttachment`: Textual can only color
/// the background of a text run, and Conductor draws inline code as a small bordered badge.
struct RockyMarkdownParser: MarkupParser {
    /// `Zoom.scale` when the text is parsed.
    var zoom: Double = 1

    func attributedString(for input: String) throws -> AttributedString {
        var string = try AttributedStringMarkdownParser.markdown().attributedString(for: input)
        let codeRanges = string.runs[\.inlinePresentationIntent].compactMap { intent, range in
            intent?.contains(.code) == true ? range : nil
        }
        for range in codeRanges {
            let code = String(string[range].characters)
            string[range].textual.attachment = AnyAttachment(InlineCodeAttachment(code: code, zoom: zoom))
        }
        return string
    }
}

/// Inline code drawn as a badge: monospaced text in a rounded box with a hairline border. Textual lays it out
/// inline like a glyph; copying a selection copies the code.
struct InlineCodeAttachment: Attachment {
    let code: String
    var zoom: Double = 1
    private static let fontSize: CGFloat = 12.5

    private var padding: CGSize {
        CGSize(width: 5 * zoom, height: 2 * zoom)
    }

    private var font: NSFont {
        .monospacedSystemFont(ofSize: Self.fontSize * zoom, weight: .regular)
    }

    var description: String { code }
    var selectionStyle: AttachmentSelectionStyle { .text }

    private var size: CGSize {
        let font = font
        let text = (code as NSString).size(withAttributes: [.font: font])
        return CGSize(
            width: ceil(text.width) + 2 * padding.width + 2,
            height: ceil(font.ascender - font.descender) + 2 * padding.height
        )
    }

    var body: some View {
        Text(verbatim: code)
            .font(.system(size: Self.fontSize * zoom, design: .monospaced))
            .foregroundStyle(Markdown.codeText)
            .lineLimit(1)
            .frame(width: size.width, height: size.height)
            .background(Markdown.codeBackground, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Markdown.codeBorder))
    }

    func sizeThatFits(_: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        size
    }

    /// The badge sits on the text's baseline; lowering it by its descender and padding lines its code up with the
    /// words around it.
    func baselineOffset(in _: TextEnvironmentValues) -> CGFloat {
        font.descender - padding.height
    }
}

/// How agent replies look, modelled on Conductor: roomy paragraphs, headings without GitHub's rule, inline code as
/// a bordered badge (`RockyMarkdownParser`), bordered code blocks with their language and a Copy button, tables
/// with a marked header.
struct RockyMarkdownStyle: StructuredText.Style {
    let inlineStyle = InlineStyle()
        .code(.monospaced, .fontScale(0.9), .backgroundColor(Markdown.codeBackground))
        .strong(.fontWeight(.semibold))
        .link(.foregroundColor(Markdown.link))
    let headingStyle = RockyHeadingStyle()
    let paragraphStyle = RockyParagraphStyle()
    let blockQuoteStyle: StructuredText.GitHubBlockQuoteStyle = .gitHub
    let codeBlockStyle = RockyCodeBlockStyle()
    let listItemStyle: StructuredText.DefaultListItemStyle = .default
    let unorderedListMarker: StructuredText.HierarchicalSymbolListMarker = .hierarchical(.disc, .circle, .square)
    let orderedListMarker: StructuredText.DecimalListMarker = .decimal
    let tableStyle = RockyTableStyle()
    let tableCellStyle = RockyTableCellStyle()
    let thematicBreakStyle: StructuredText.GitHubThematicBreakStyle = .gitHub
}

/// The colors the markdown style uses, on top of Rocky's dark background.
enum Markdown {
    static let codeBackground = Color.white.opacity(0.05)
    static let codeBorder = Color.white.opacity(0.14)
    static let codeText = Color.white.opacity(0.88)
    static let blockBackground = Color.black.opacity(0.22)
    static let border = Color.white.opacity(0.1)
    static let tableHeader = Color.white.opacity(0.05)
    static let link = Color(red: 0.89, green: 0.62, blue: 0.47)
}

struct RockyParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(0.4))
            .textual.blockSpacing(.init(top: 0, bottom: 14))
    }
}

struct RockyHeadingStyle: StructuredText.HeadingStyle {
    private static let fontScales: [CGFloat] = [1.6, 1.35, 1.15, 1, 0.95, 0.9]

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.fontScale(Self.fontScales[min(configuration.headingLevel, 6) - 1])
            .textual.lineSpacing(.fontScaled(0.15))
            .textual.blockSpacing(.init(top: 22, bottom: 10))
            .fontWeight(.semibold)
    }
}

struct RockyCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.languageHint ?? "text")
                    .font(.rocky(10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { configuration.codeBlock.copyToPasteboard() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy the code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Rectangle().fill(Markdown.border).frame(height: 1)
            Overflow {
                configuration.label
                    .textual.lineSpacing(.fontScaled(0.25))
                    .textual.fontScale(0.9)
                    .fixedSize(horizontal: false, vertical: true)
                    .monospaced()
                    .padding(14)
            }
        }
        .background(Markdown.blockBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Markdown.border))
        .textual.blockSpacing(.init(top: 4, bottom: 14))
    }
}

struct RockyTableStyle: StructuredText.TableStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.tableCellSpacing(horizontal: 1, vertical: 1)
            .textual.blockSpacing(.init(top: 4, bottom: 14))
            .textual.tableBackground { layout in
                Canvas { context, _ in
                    guard layout.numberOfRows > 0 else { return }
                    context.fill(Path(layout.rowBounds(0).integral), with: .color(Markdown.tableHeader))
                }
            }
            .textual.tableOverlay { layout in
                Canvas { context, _ in
                    for divider in layout.dividers() {
                        context.fill(Path(divider), with: .color(Markdown.border))
                    }
                }
            }
            .padding(1)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Markdown.border))
    }
}

struct RockyTableCellStyle: StructuredText.TableCellStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(configuration.row == 0 ? .semibold : .regular)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .textual.lineSpacing(.fontScaled(0.25))
    }
}
