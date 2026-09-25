import AppKit
import RockyKit
import SwiftUI

/// The diff's horizontal scroll position, for the rows' sticky parts: the number columns stay while long lines scroll
/// (DIFF-02). A class the scroll view writes and only those parts read, so scrolling redraws them and not every row.
@MainActor
@Observable
final class DiffScrollOffset {
    var x: CGFloat = 0
}

/// DIFF-02's measures at 100 % zoom, through `Zoom.shared` where they are drawn.
enum DiffMetrics {
    static let lineHeight: CGFloat = 20
    /// Collapsed runs and captions.
    static let barHeight: CGFloat = 26
    /// One number column, as Conductor draws it (user request, 2026-09-24: the old and new columns read as the number
    /// twice): five digits and their 8-point trailing padding.
    static let numberWidth: CGFloat = 48
    static let markerWidth: CGFloat = 16
    /// The number column and the marker: where the code and a collapsed run start.
    static var gutterWidth: CGFloat { numberWidth + markerWidth }
    static let codeTrailingPadding: CGFloat = 24
    static let fontSize: CGFloat = 12

    /// The advance of one character of the 12-point code font at the current zoom: rows are as wide as their longest
    /// line, measured in columns, so the horizontal scroll range never changes as rows come into view.
    @MainActor
    static var characterWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: Zoom.shared(fontSize), weight: .regular)
        return ceil(("0" as NSString).size(withAttributes: [.font: font]).width * 100) / 100
    }

    /// The widest line of `file`'s hunks and of the worktree file's lines, in columns (`HighlightedLine.columns`).
    static func maxColumns(file: FileDiff, lines: [String]?) -> Int {
        var widest = 0
        for hunk in file.hunks {
            for line in hunk.lines {
                widest = max(widest, HighlightedLine.columns(of: line.text))
            }
        }
        for line in lines ?? [] {
            widest = max(widest, HighlightedLine.columns(of: line))
        }
        return widest
    }
}

/// Moves its content by the horizontal scroll position, so it stays at the left edge of the viewport while the row
/// under it scrolls. Only this view reads the position. The comment box uses it too (`UnifiedDiffView.commentBox`).
struct Sticky<Content: View>: View {
    let scroll: DiffScrollOffset
    let content: Content

    init(scroll: DiffScrollOffset, @ViewBuilder content: () -> Content) {
        self.scroll = scroll
        self.content = content()
    }

    var body: some View {
        content.offset(x: scroll.x)
    }
}

/// One line of the unified diff (DIFF-02): 20 points, 12 mono. One number (48, right-aligned: the new number, the old
/// one on a removed row, in `success` on an added row, `danger` on a removed one and `textTertiary` otherwise) and the
/// + / − marker (16) stay put on an opaque background while the code scrolls under them; the code carries its tokens'
/// colors (DIFF-04). Added rows fill with `diffAddLine` and their number with `diffAddGutter`, removed ones with the
/// delete tokens; context rows have no fill.
///
/// With `commenting`, CMT-01: hovering shows the "+" over the one number, and a press on it comments on the line: a
/// removed row's number is the old one, so its comment is on the removed side, and any other row's is on the new side
/// (`DiffLine.commentLine`). A drag across rows makes a range on the pressed row's side, and Shift extends the last
/// one. Selected rows, and the rows of an open comment box (CMT-02), fill with `commentRange` and a 3-point `accent`
/// bar at their left edge.
struct DiffLineRow: View {
    let line: DiffLine
    let tokens: [SyntaxToken]
    let width: CGFloat
    let scroll: DiffScrollOffset
    var commenting: DiffCommentState?
    @State private var hovering = false

    var body: some View {
        let target = commenting == nil ? nil : line.commentLine
        let isSelected = target.map { commenting?.isSelected($0) == true } ?? false
        let rowId = DiffRow.line(line).id
        HStack(spacing: 0) {
            Sticky(scroll: scroll) {
                DiffLineGutter(line: line, isSelected: isSelected, showsAdd: hovering && target != nil)
                    .contentShape(Rectangle())
                    .gesture(commentGesture(target), including: target == nil ? .none : .all)
                    .pointerStyle(target == nil ? nil : .link)
            }
            // Drawn over the code that scrolls under it.
            .zIndex(1)
            Text(HighlightedLine.attributed(line.text, tokens: tokens))
                .font(.rocky(DiffMetrics.fontSize, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: Zoom.shared(DiffMetrics.lineHeight), alignment: .leading)
        .background(isSelected ? Theme.commentRange : (line.kind.lineFill ?? Color.clear))
        .onHover { hovering = $0 }
        // Where a drag finds this line (`DiffCommentState.drag`): measured in the rows' own space, so scrolling moves
        // nothing.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DiffCommentState.space)) } action: { frame in
            if let target { commenting?.record(target, rowId: rowId, frame: frame) }
        }
        .onDisappear { commenting?.forget(rowId: rowId) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityActions {
            if let target, let commenting {
                Button("Comment on this line") { commenting.comment(on: target) }
            }
        }
    }

    /// The press is the first change, with nothing dragged yet; a Shift-press extends the last range. The release opens
    /// the comment box (CMT-02).
    private func commentGesture(_ target: CommentLine?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(DiffCommentState.space))
            .onChanged { value in
                guard let target, let commenting else { return }
                if value.translation == .zero {
                    commenting.press(target, extending: NSEvent.modifierFlags.contains(.shift))
                } else {
                    commenting.drag(toY: value.location.y)
                }
            }
            .onEnded { _ in commenting?.release() }
    }

    private var accessibilityText: String {
        switch line.kind {
        case .added: "Added line \(line.newNumber ?? 0): \(line.text)"
        case .removed: "Removed line \(line.oldNumber ?? 0): \(line.text)"
        case .context: "Line \(line.newNumber ?? 0): \(line.text)"
        }
    }
}

/// The number and the marker of a diff line, opaque so the code can pass under them. Selected for a comment, they take
/// `commentRange` and the `accent` bar; `showsAdd` puts CMT-01's "+" over the number.
private struct DiffLineGutter: View {
    let line: DiffLine
    var isSelected = false
    var showsAdd = false

    var body: some View {
        HStack(spacing: 0) {
            number(line.kind == .removed ? line.oldNumber : line.newNumber)
                .background(isSelected ? Color.clear : (line.kind.gutterFill ?? Color.clear))
            Text(verbatim: line.kind.marker)
                .foregroundStyle(line.kind.markerColor)
                .frame(width: Zoom.shared(DiffMetrics.markerWidth))
        }
        .font(.rocky(DiffMetrics.fontSize, design: .monospaced))
        .frame(height: Zoom.shared(DiffMetrics.lineHeight))
        .background(isSelected ? Theme.commentRange : (line.kind.lineFill ?? Color.clear))
        .background(Color.rockyBackground)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Theme.accent).frame(width: 3)
            }
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(verbatim: value.map(String.init) ?? "")
            .monospacedDigit()
            .foregroundStyle(line.kind.numberColor)
            .lineLimit(1)
            .padding(.trailing, 8)
            .frame(width: Zoom.shared(DiffMetrics.numberWidth), alignment: .trailing)
            .overlay(alignment: .trailing) {
                if showsAdd {
                    CommentAddGlyph()
                        .padding(.trailing, 2)
                }
            }
    }
}

/// An unchanged run collapsed to one 26-point row (DIFF-02): "⋯ 18 unchanged lines" in 12 `textSecondary`, lit with
/// `fillHover` on hover; a click shows the run's lines.
struct DiffGapRow: View {
    let count: Int
    let width: CGFloat
    let scroll: DiffScrollOffset
    let expand: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: expand) {
            Sticky(scroll: scroll) {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis")
                        .font(.rocky(11, weight: .semibold))
                    Text(verbatim: count == 1 ? "1 unchanged line" : "\(count) unchanged lines")
                        .font(.rocky(12))
                }
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .padding(.leading, Zoom.shared(DiffMetrics.gutterWidth))
            }
            .frame(width: width, height: Zoom.shared(DiffMetrics.barHeight), alignment: .leading)
            .background(hovering ? Theme.fillHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .help("Show the unchanged lines")
    }
}

/// A line of the diff that is not code, such as DIFF-03's "File mode changed 644 → 755" above a file's hunks: 26
/// points, 12 `textSecondary`, where the code starts.
struct DiffCaptionRow: View {
    let text: String
    let width: CGFloat
    let scroll: DiffScrollOffset

    var body: some View {
        Sticky(scroll: scroll) {
            Text(text)
                .font(.rocky(12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, Zoom.shared(DiffMetrics.gutterWidth))
        }
        .frame(width: width, height: Zoom.shared(DiffMetrics.barHeight), alignment: .leading)
    }
}

extension DiffLine.Kind {
    /// The whole row's fill (TOK-10).
    var lineFill: Color? {
        switch self {
        case .added: Theme.diffAddLine
        case .removed: Theme.diffDeleteLine
        case .context: nil
        }
    }

    /// The number column's fill, over the row's.
    var gutterFill: Color? {
        switch self {
        case .added: Theme.diffAddGutter
        case .removed: Theme.diffDeleteGutter
        case .context: nil
        }
    }

    /// The line number's color: the side it counts on, as Conductor colors it.
    var numberColor: Color {
        switch self {
        case .added: Theme.success
        case .removed: Theme.danger
        case .context: Theme.textTertiary
        }
    }

    var marker: String {
        switch self {
        case .added: "+"
        case .removed: "−"
        case .context: ""
        }
    }

    var markerColor: Color {
        switch self {
        case .added: Theme.success
        case .removed: Theme.danger
        case .context: Theme.textTertiary
        }
    }
}
