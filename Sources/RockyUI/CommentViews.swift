import AppKit
import RockyKit
import SwiftUI

/// A diff tab's selection (CMT-01) and the frames of the rows on screen, which a drag reads. The box itself is the
/// model's (`AppModel.commentDraft`), so it comes back after a tab switch or Diff | Edit (CMT-02). A class the rows
/// read, like `DiffScrollOffset`, so a drag redraws the rows and not the whole diff.
@MainActor
@Observable
final class DiffCommentState {
    /// The coordinate space of the diff's rows: a drag's location and the rows' frames are measured in it. Read by
    /// geometry closures, which run off the main actor.
    nonisolated static let space = "diff-comment-rows"

    /// CMT-01's range while it is being made: on one side only, from the line first pressed (`anchor`) to the line the
    /// drag or a Shift-click reached.
    struct Selection: Equatable {
        let side: CommentLine.Side
        let anchor: Int
        let start: Int
        let end: Int

        func contains(_ line: CommentLine) -> Bool {
            line.side == side && line.number >= start && line.number <= end
        }
    }

    /// The range of the press in progress; between presses the box's range is the selection.
    private(set) var selection: Selection?
    /// CMT-02: Esc in a box with text asks before dropping it.
    var asksToDiscard = false
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let workspaceId: String
    /// Worktree-relative: the diff tab's file.
    @ObservationIgnored private let path: String
    /// The side of the press in progress; nil between presses.
    @ObservationIgnored private var pressedSide: CommentLine.Side?
    /// The line the box's range was first pressed on, which a Shift-click extends from.
    @ObservationIgnored private var anchor: Int?
    /// The rows on screen, by row id: the line each one takes a comment on and its vertical extent.
    @ObservationIgnored private var frames: [String: (line: CommentLine, minY: CGFloat, maxY: CGFloat)] = [:]

    init(model: AppModel, workspaceId: String, path: String) {
        self.model = model
        self.workspaceId = workspaceId
        self.path = path
    }

    /// The tab's box, while it is open.
    var draft: CommentDraft? {
        model.commentDraft(workspaceId: workspaceId, path: path)
    }

    /// Lit with `commentRange`: the range being pressed, else the box's (CMT-02: the range keeps its fill while the
    /// box is open).
    func isSelected(_ line: CommentLine) -> Bool {
        if let selection { return selection.contains(line) }
        return draft?.contains(line) ?? false
    }

    /// A press on a line's "+" or number: a range of that line, or with Shift one from the last range's anchor, when
    /// that range is on the same side.
    func press(_ line: CommentLine, extending: Bool) {
        let current = selection ?? draft.map { Selection(side: $0.side, anchor: anchor ?? $0.start, start: $0.start, end: $0.end) }
        if extending, let current, current.side == line.side {
            selection = Selection(
                side: line.side,
                anchor: current.anchor,
                start: min(current.anchor, line.number),
                end: max(current.anchor, line.number)
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

    /// The press ended: the box opens under the range, or moves there with what was written in it.
    func release() {
        guard pressedSide != nil, let selection else { return }
        pressedSide = nil
        anchor = selection.anchor
        model.openCommentDraft(workspaceId: workspaceId, path: path, side: selection.side, lines: selection.start...selection.end)
        self.selection = nil
    }

    /// VoiceOver's Comment action on a row: that line, with the box open.
    func comment(on line: CommentLine) {
        press(line, extending: false)
        release()
    }

    /// Cancel, Esc, or once the comment is on its way: no range and no box.
    func cancel() {
        selection = nil
        pressedSide = nil
        anchor = nil
        asksToDiscard = false
        model.dropCommentDraft(workspaceId: workspaceId, path: path)
    }

    /// Esc in the box: an empty one closes, one with text asks first (CMT-02).
    func escape() {
        if (draft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cancel()
        } else {
            asksToDiscard = true
        }
    }

    func record(_ line: CommentLine, rowId: String, frame: CGRect) {
        frames[rowId] = (line: line, minY: frame.minY, maxY: frame.maxY)
    }

    /// A row the lazy stack let go of: its frame would go stale as the box opens above it.
    func forget(rowId: String) {
        frames[rowId] = nil
    }

    private func nearestLine(to y: CGFloat, side: CommentLine.Side) -> Int? {
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

/// Whether a comment box has the keyboard. `ChatView`'s key monitor reads it at the key's time, since a monitor keeps
/// the view as it was when it was added (`CLAUDE.md`), and then leaves Esc to the box, which closes it (CMT-02),
/// instead of stopping the agent's turn (KBD-02).
@MainActor
enum CommentComposerFocus {
    /// The box's own focus state, which it sets.
    static var isFocused = false

    /// The box's focus, and the window typing in a text view that is not a field editor, as the box's `TextEditor`
    /// does: a focus state left behind never keeps Esc from the agent once a field has the keyboard.
    static func hasKeyboard(in window: NSWindow) -> Bool {
        guard isFocused, let textView = window.firstResponder as? NSTextView else { return false }
        return !textView.isFieldEditor
    }
}

/// CMT-02's comment box under the range, on `Theme.composer` with its border, radius 10. A 34-point head over a
/// hairline: "Sending to" (12 `textTertiary`) and Rocky's menu of the workspace's open conversations, its button the
/// chosen one's agent icon, title (12.5 `textPrimary`) and `chevron.up.chevron.down`. Then the line chip (CMT-06),
/// fixed, and the text (13 on 22-point lines, two at least, growing), placeholder "Ask about these lines…". Then
/// "⌘Return to send" (11.5 `textTertiary`), Cancel and Send (white filled, disabled while the text is empty), which
/// reads "Queue" while the chosen conversation's turn runs. Return is a new line; Esc closes an empty box and asks
/// "Discard this comment?" first with text.
struct LineCommentBox: View {
    let model: AppModel
    let workspaceId: String
    /// The lines, as the chip and the message show them.
    let range: LineRangeAttachment
    @Bindable var draft: CommentDraft
    @Bindable var commenting: DiffCommentState
    let send: () -> Void
    @FocusState private var isFocused: Bool

    /// A text line of the box, at the zoom.
    private static var lineHeight: CGFloat { Zoom.shared(22) }

    /// What `lineSpacing` adds to 13-point lines to make them 22 points.
    private static var lineGap: CGFloat {
        let font = NSFont.systemFont(ofSize: Zoom.shared(13))
        return max(0, lineHeight - ceil(font.ascender - font.descender + font.leading))
    }

    var body: some View {
        let conversation = model.commentConversation(for: draft, workspaceId: workspaceId)
        let isEmpty = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            head(conversation)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(alignment: .top, spacing: 6) {
                LineChip(range: range)
                editor
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            actions(conversation, isEmpty: isEmpty)
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.bottom, 10)
        }
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.composerBorder) }
        // After the box is in the window, or the focus does not take.
        .task { isFocused = true }
        .onChange(of: isFocused, initial: true) { _, focused in CommentComposerFocus.isFocused = focused }
        .onDisappear { CommentComposerFocus.isFocused = false }
        .confirmationDialog("Discard this comment?", isPresented: $commenting.asksToDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { commenting.cancel() }
            Button("Keep Editing", role: .cancel) {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comment on \(range.rangeLabel)")
    }

    private func head(_ conversation: ChatSessionRecord?) -> some View {
        HStack(spacing: 6) {
            Text("Sending to")
                .font(.rocky(12))
                .foregroundStyle(Theme.textTertiary)
            MenuButton(id: "comment-to-\(workspaceId)-\(range.path)", placement: .belowLeading, width: 260) { isOpen in
                CommentConversationLabel(conversation: conversation, isOpen: isOpen)
            } content: {
                ForEach(model.conversations[workspaceId] ?? []) { record in
                    MenuItem(
                        title: record.title ?? "New conversation",
                        icon: .agent(AgentKind(rawValue: record.agent) ?? .claude),
                        isChecked: record.id == conversation?.id
                    ) {
                        draft.conversationId = record.id
                    }
                }
            }
            .help("The conversation this comment goes to")
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: Zoom.shared(34))
    }

    /// The text, sized by a hidden copy of it: a `TextEditor` does not grow with what it holds.
    private var editor: some View {
        Text(verbatim: Self.sizingText(draft.text))
            .font(.rocky(13))
            .lineSpacing(Self.lineGap)
            .padding(.horizontal, 5)
            .padding(.top, Self.firstLineInset)
            .frame(maxWidth: .infinity, minHeight: Self.lineHeight * 2, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .overlay(alignment: .topLeading) {
                TextEditor(text: $draft.text)
                    .font(.rocky(13))
                    .lineSpacing(Self.lineGap)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .padding(.top, Self.firstLineInset)
                    .focused($isFocused)
                    .onKeyPress(.escape) {
                        commenting.escape()
                        return .handled
                    }
                    .accessibilityLabel("Comment")
            }
            .overlay(alignment: .topLeading) {
                // The first line's height, so the placeholder sits where the caret is, beside the chip.
                Color.clear
                    .frame(height: Self.lineHeight)
                    .stablePlaceholder("Ask about these lines…", isVisible: draft.text.isEmpty)
                    .font(.rocky(13))
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
    }

    /// Centers the first line of text on the chip's 22 points.
    private static var firstLineInset: CGFloat {
        let font = NSFont.systemFont(ofSize: Zoom.shared(13))
        return max(0, (lineHeight - ceil(font.ascender - font.descender + font.leading)) / 2)
    }

    /// The editor's text for its hidden copy: a last empty line still counts, and an empty box shows one line.
    private static func sizingText(_ text: String) -> String {
        text.isEmpty || text.hasSuffix("\n") ? text + " " : text
    }

    private func actions(_ conversation: ChatSessionRecord?, isEmpty: Bool) -> some View {
        let agent = conversation.flatMap { AgentKind(rawValue: $0.agent) }
        let isWorking = conversation.flatMap { model.chat(conversationId: $0.id) }?.state == .running
        return HStack(spacing: 6) {
            Text("⌘Return to send")
                .font(.rocky(11.5))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            Button("Cancel") { commenting.cancel() }
                .font(.rocky(12.5))
                .buttonStyle(RockyTextButtonStyle(height: 26))
            Button(isWorking ? "Queue" : "Send", action: send)
                .font(.rocky(12.5, weight: .medium))
                .buttonStyle(RockyPrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isEmpty || conversation == nil)
                .optionalHelp(isWorking ? "\(agent?.displayName ?? "The agent") is working; this goes out when its turn ends" : nil)
        }
    }
}

/// The "Sending to" menu's button: the conversation's agent icon, its title (12.5 `textPrimary`) and
/// `chevron.up.chevron.down`; 24 points, padding 6, radius 5, `fillIconHover` on hover and `fillPressed` while its menu
/// is open. `MenuButton` wraps it in a plain button, so it draws its own hover.
private struct CommentConversationLabel: View {
    let conversation: ChatSessionRecord?
    let isOpen: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let agent = conversation.flatMap({ AgentKind(rawValue: $0.agent) }) {
                AgentIcon(agent: agent, size: 14)
            }
            Text(verbatim: conversation.map { $0.title ?? "New conversation" } ?? "No conversation")
                .font(.rocky(12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .font(.rocky(9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 6)
        .frame(height: Zoom.shared(24))
        .background(isOpen ? Theme.fillPressed : hovering ? Theme.fillIconHover : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}
