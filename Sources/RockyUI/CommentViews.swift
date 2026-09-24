import AppKit
import RockyKit
import SwiftUI

/// A diff tab's commenting (CMT-01, CMT-02): the selected range, the composer's draft, and the frames of the rows on
/// screen, which a drag reads. A class the rows read, like `DiffScrollOffset`, so a drag redraws the rows and not the
/// whole diff; only the composer opening or closing redraws the diff, to place it.
@MainActor
@Observable
final class DiffCommentState {
    /// The coordinate space of the diff's rows: a drag's location and the rows' frames are measured in it. Read by
    /// geometry closures, which run off the main actor.
    nonisolated static let space = "diff-comment-rows"

    /// CMT-01's range: on one side only, from the line first pressed (`anchor`) to the line the drag or a Shift-click
    /// reached.
    struct Selection: Equatable {
        let side: DiffCommentRecord.Side
        let anchor: Int
        let start: Int
        let end: Int

        func contains(_ line: CommentLine) -> Bool {
            line.side == side && line.number >= start && line.number <= end
        }
    }

    /// The composer's range, and the comment it edits (nil for a new one).
    struct Draft: Equatable {
        let side: DiffCommentRecord.Side
        let start: Int
        let end: Int
        let editing: String?

        var range: ClosedRange<Int> { start...end }
        var lastLine: CommentLine { CommentLine(side: side, number: end) }
    }

    private(set) var selection: Selection?
    private(set) var draft: Draft?
    /// The composer's text, kept apart from `draft` so typing redraws the composer alone.
    var text = ""
    /// CMT-02: Esc in a composer with text asks before dropping it.
    var asksToDiscard = false
    /// The side of the press in progress; nil between presses.
    @ObservationIgnored private var pressedSide: DiffCommentRecord.Side?
    /// The rows on screen, by row id: the line each one takes a comment on and its vertical extent.
    @ObservationIgnored private var frames: [String: (line: CommentLine, minY: CGFloat, maxY: CGFloat)] = [:]

    func isSelected(_ line: CommentLine) -> Bool {
        selection?.contains(line) ?? false
    }

    /// A press on a line's "+" or number: a range of that line, or with Shift one from the last range's anchor, when
    /// that range is on the same side.
    func press(_ line: CommentLine, extending: Bool) {
        if extending, let selection, selection.side == line.side {
            self.selection = Selection(
                side: line.side,
                anchor: selection.anchor,
                start: min(selection.anchor, line.number),
                end: max(selection.anchor, line.number)
            )
        } else {
            selection = Selection(side: line.side, anchor: line.number, start: line.number, end: line.number)
        }
        pressedSide = line.side
    }

    /// The press dragged to `y`: the range reaches the line of its side nearest there. Rows of the other side are
    /// passed over (CMT-01: a range stays on one side).
    func drag(toY y: CGFloat) {
        guard let side = pressedSide, let selection, let number = nearestLine(to: y, side: side) else { return }
        let start = min(selection.anchor, number)
        let end = max(selection.anchor, number)
        guard start != selection.start || end != selection.end else { return }
        self.selection = Selection(side: side, anchor: selection.anchor, start: start, end: end)
    }

    /// The press ended: the composer opens under the range. The text of a new comment not saved yet stays, as in the
    /// mock; an edit's text does not carry over to a new comment.
    func release() {
        guard pressedSide != nil, let selection else { return }
        pressedSide = nil
        if draft?.editing != nil { text = "" }
        draft = Draft(side: selection.side, start: selection.start, end: selection.end, editing: nil)
    }

    /// VoiceOver's Comment action on a row: that line, with the composer open.
    func comment(on line: CommentLine) {
        press(line, extending: false)
        release()
    }

    /// CMT-02's Edit: the composer in the card's place, on the comment's lines.
    func edit(_ comment: DiffCommentRecord) {
        selection = Selection(side: comment.side, anchor: comment.startLine, start: comment.startLine, end: comment.endLine)
        draft = Draft(side: comment.side, start: comment.startLine, end: comment.endLine, editing: comment.id)
        text = comment.body
    }

    /// Cancel, Esc, or after saving: no range and no composer.
    func cancel() {
        selection = nil
        draft = nil
        text = ""
        asksToDiscard = false
        pressedSide = nil
    }

    /// Esc in the composer: an empty one closes, one with text asks first (CMT-02).
    func escape() {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cancel()
        } else {
            asksToDiscard = true
        }
    }

    func record(_ line: CommentLine, rowId: String, frame: CGRect) {
        frames[rowId] = (line: line, minY: frame.minY, maxY: frame.maxY)
    }

    /// A row the lazy stack let go of: its frame would go stale as comments open above it.
    func forget(rowId: String) {
        frames[rowId] = nil
    }

    private func nearestLine(to y: CGFloat, side: DiffCommentRecord.Side) -> Int? {
        var best: (number: Int, distance: CGFloat)?
        for entry in frames.values where entry.line.side == side {
            let distance = y < entry.minY ? entry.minY - y : y > entry.maxY ? y - entry.maxY : 0
            if let found = best, found.distance <= distance { continue }
            best = (number: entry.line.number, distance: distance)
        }
        return best?.number
    }
}

/// CMT-01's "+": 16 points on `accent`, radius 4, a dark plus, over the line's number while its row is hovered.
struct CommentAddGlyph: View {
    private static let glyph = Color(red: 0x0E / 255, green: 0x11 / 255, blue: 0x16 / 255)

    var body: some View {
        Image(systemName: "plus")
            .font(.rocky(10, weight: .bold))
            .foregroundStyle(Self.glyph)
            .frame(width: Zoom.shared(16), height: Zoom.shared(16))
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}

/// The comments under one diff row, or at the top of the diff (CMT-02, CMT-04): the collapsed outdated ones, the cards,
/// and the composer, aligned with the code (the gutter's width in) and at most 560 wide. They stay in view while long
/// lines scroll, like the number columns.
struct DiffCommentSlot: View {
    var outdated: [DiffCommentRecord] = []
    let comments: [DiffCommentRecord]
    let showsComposer: Bool
    let commenting: DiffCommentState
    let width: CGFloat
    let cardWidth: CGFloat
    let scroll: DiffScrollOffset
    let save: () -> Void
    let delete: (DiffCommentRecord) -> Void

    var body: some View {
        let editing = commenting.draft?.editing
        Sticky(scroll: scroll) {
            VStack(alignment: .leading, spacing: 6) {
                if !outdated.isEmpty {
                    OutdatedCommentsBox(comments: outdated, delete: delete)
                }
                ForEach(comments) { comment in
                    if comment.id == editing {
                        DiffCommentComposer(commenting: commenting, save: save)
                    } else {
                        DiffCommentCard(comment: comment, edit: { commenting.edit(comment) }, delete: { delete(comment) })
                    }
                }
                if showsComposer, editing == nil || !comments.contains(where: { $0.id == editing }) {
                    DiffCommentComposer(commenting: commenting, save: save)
                }
            }
            .frame(width: cardWidth, alignment: .leading)
            .padding(.leading, Zoom.shared(DiffMetrics.gutterWidth))
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// CMT-04: outdated comments at the top of a file's diff, collapsed under "2 outdated comments" (12 `textSecondary`),
/// their cards dimmed to 80 % when open. They can only be deleted: their lines are gone.
private struct OutdatedCommentsBox: View {
    let comments: [DiffCommentRecord]
    let delete: (DiffCommentRecord) -> Void
    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : Theme.Motion.state) { isOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.rocky(9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(verbatim: comments.count == 1 ? "1 outdated comment" : "\(comments.count) outdated comments")
                        .font(.rocky(12))
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(height: Zoom.shared(24))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickable()
            .accessibilityValue(isOpen ? "expanded" : "collapsed")
            if isOpen {
                ForEach(comments) { comment in
                    DiffCommentCard(comment: comment, edit: nil, delete: { delete(comment) })
                        .opacity(0.8)
                }
            }
        }
    }
}

/// CMT-02's card: "You", when, the state chip, and on hover Edit and Delete, then the text (13). `Theme.composer` with
/// its border, radius 8.
struct DiffCommentCard: View {
    let comment: DiffCommentRecord
    /// nil hides Edit (an outdated comment).
    let edit: (() -> Void)?
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("You")
                    .font(.rocky(12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(verbatim: Self.age(of: comment.createdAt, now: Date()))
                    .font(.rocky(11.5))
                    .foregroundStyle(Theme.textSecondary)
                CommentStateChip(state: comment.state)
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    if let edit {
                        Button("Edit comment", systemImage: "pencil", action: edit)
                            .buttonStyle(RockyIconButtonStyle(size: 18))
                            .help("Edit")
                    }
                    Button("Delete comment", systemImage: "trash", action: delete)
                        .buttonStyle(RockyIconButtonStyle(size: 18))
                        .help("Delete")
                }
                .font(.rocky(10))
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(minHeight: Zoom.shared(18))
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.top, 8)
            Text(verbatim: comment.body)
                .font(.rocky(13))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(Zoom.shared(4))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.composerBorder) }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }

    /// "just now" in the first minute, then `RelativeAge`'s "5m ago". Drawn when the card is, with no timer.
    static func age(of date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : RelativeAge.text(since: date, now: now)
    }
}

/// CMT-02's chips: Pending (`attention` outline), Sent (`textSecondary`, a check), Outdated (`textTertiary`, "The
/// commented lines changed"); 18 points, radius 9, 10.5.
struct CommentStateChip: View {
    let state: DiffCommentRecord.State

    var body: some View {
        HStack(spacing: 4) {
            if state == .sent {
                Image(systemName: "checkmark")
                    .font(.rocky(8, weight: .bold))
            }
            Text(verbatim: title)
                .font(.rocky(10.5))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: Zoom.shared(18))
        .overlay { Capsule().strokeBorder(border) }
        .fixedSize()
        .optionalHelp(state == .outdated ? "The commented lines changed" : nil)
    }

    private var title: String {
        switch state {
        case .pending: "Pending"
        case .sent: "Sent"
        case .outdated: "Outdated"
        }
    }

    private var color: Color {
        switch state {
        case .pending: Theme.attention
        case .sent: Theme.textSecondary
        case .outdated: Theme.textTertiary
        }
    }

    private var border: Color {
        switch state {
        case .pending: Theme.attention.opacity(0.45)
        case .sent: Color.white.opacity(0.14)
        case .outdated: Color.white.opacity(0.1)
        }
    }
}

/// Whether a diff comment's composer has the keyboard. `ChatView`'s key monitor reads it at the key's time, since a
/// monitor keeps the view as it was when it was added (`CLAUDE.md`), and then leaves Esc to the composer, which closes
/// it (CMT-02), instead of stopping the agent's turn (KBD-02).
@MainActor
enum CommentComposerFocus {
    /// The composer's own focus state, which it sets.
    static var isFocused = false

    /// The composer's focus, and the window typing in a text view that is not a field editor, as the composer's
    /// `TextEditor` does: a focus state left behind never keeps Esc from the agent once a field has the keyboard.
    static func hasKeyboard(in window: NSWindow) -> Bool {
        guard isFocused, let textView = window.firstResponder as? NSTextView else { return false }
        return !textView.isFieldEditor
    }
}

/// CMT-02's composer under the range: "Comment on line 14" or "lines 14–22" (11.5 `textSecondary`), a text box (13,
/// three lines at least), "⌘Return to comment", Cancel and Comment (white filled). Esc closes it when empty and asks
/// first with text.
struct DiffCommentComposer: View {
    @Bindable var commenting: DiffCommentState
    let save: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        let isEmpty = commenting.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: label)
                .font(.rocky(11.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 6)
            TextEditor(text: $commenting.text)
                .font(.rocky(13))
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(minHeight: Zoom.shared(64), maxHeight: Zoom.shared(240))
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isFocused ? Theme.accent.opacity(0.55) : Theme.hairline)
                }
                .overlay(alignment: .topLeading) {
                    if commenting.text.isEmpty {
                        Text("Leave a comment for the agent")
                            .font(.rocky(13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 10)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
                .onKeyPress(.escape) {
                    commenting.escape()
                    return .handled
                }
                .accessibilityLabel(label)
            HStack(spacing: 6) {
                Text("⌘Return to comment")
                    .font(.rocky(11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Button("Cancel") { commenting.cancel() }
                    .font(.rocky(12.5))
                    .buttonStyle(RockyTextButtonStyle(height: 26))
                Button("Comment", action: save)
                    .font(.rocky(12.5, weight: .medium))
                    .buttonStyle(RockyPrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isEmpty)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.composerBorder) }
        // After the composer is in the window, or the focus does not take.
        .task { isFocused = true }
        .onChange(of: isFocused, initial: true) { _, focused in CommentComposerFocus.isFocused = focused }
        .onDisappear { CommentComposerFocus.isFocused = false }
        .confirmationDialog("Discard this comment?", isPresented: $commenting.asksToDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { commenting.cancel() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private var label: String {
        guard let draft = commenting.draft else { return "Comment" }
        let lines = draft.start == draft.end ? "Comment on line \(draft.start)" : "Comment on lines \(draft.start)–\(draft.end)"
        return draft.side == .old ? lines + " (removed)" : lines
    }
}
