import RockyKit
import SwiftUI

/// A message waiting for the agent's turn to end, at the end of the conversation where it will be sent (user
/// decision, 2026-09-23: not floating over the message box). Drawn like the user's messages but dimmer, with a
/// dashed edge. Under each one, always visible and in the same place (user decision, 2026-09-29, replacing the
/// actions that showed on hover to the bubble's left): why it waits, then Send now (which stops the turn in progress
/// first), Edit (back into the message box, when the box is empty) and Delete. A line comment (CMT-05) shows its chip
/// over the comment and offers Send now, Edit and Remove; its Edit brings the chip back into the box with the text, as ↑
/// does, and the code it was queued with goes.
struct QueuedMessageRow: View {
    let message: QueuedMessage
    let isAgentWorking: Bool
    /// WSC-03: sent while the workspace's worktree was being made; it goes once the agent is ready.
    var isWaitingForAgent = false
    /// The queue waits for the user's next message (a stopped turn, M2.5).
    var isHeld = false
    let canEdit: Bool
    let onSendNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            bubble
            footer
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var bubble: some View {
        Group {
            if let comment = message.lineComment {
                LineCommentText(range: comment.range, text: comment.text, files: message.attachments.map(\.path), selectable: false)
            } else if message.attachments.isEmpty {
                Text(message.text)
            } else {
                InlineFilesText(text: message.text, files: message.attachments.map(\.path))
            }
        }
        .lineSpacing(3)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .frame(maxWidth: Zoom.shared(620), alignment: .trailing)
    }

    /// "◷ Queued · ↑ Send now · ✎ Edit · ✕", 11.5 `textTertiary`, the actions lit on hover.
    private var footer: some View {
        HStack(spacing: 6) {
            Label(status, systemImage: "clock")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Theme.textTertiary)
            separator
            QueueActionButton(title: "Send now", systemImage: "arrow.up", action: onSendNow)
                .help(isAgentWorking ? "Stop the agent's turn and send this now" : "Send this now")
            separator
            QueueActionButton(title: "Edit", systemImage: "pencil", action: onEdit)
                .disabled(!canEdit)
                .help(canEdit ? "Edit in the message box" : "Send or clear the message box first")
            separator
            QueueActionButton(title: message.lineComment == nil ? "Delete" : "Remove", systemImage: "xmark", showsTitle: false, action: onDelete)
                .help(message.lineComment == nil ? "Delete this queued message" : "Remove this queued comment")
        }
        .font(.rocky(11.5))
    }

    private var status: String {
        if isWaitingForAgent { return "Goes when the agent is ready" }
        if isHeld { return "On hold until your next message" }
        return "Queued"
    }

    private var separator: some View {
        Text(verbatim: "·").foregroundStyle(Theme.textTertiary)
    }
}

/// One of a queued message's actions (QUE-01): its icon and title in `textTertiary`, `textPrimary` on hover over a
/// `fillHover` pill (radius 5, padding 2 by 6), so the target is larger than the text.
private struct QueueActionButton: View {
    let title: String
    let systemImage: String
    var showsTitle = true
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.rocky(10, weight: .semibold))
                if showsTitle { Text(title) }
            }
            .foregroundStyle(hovering && isEnabled ? Theme.textPrimary : Theme.textTertiary)
            .opacity(isEnabled ? 1 : 0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(hovering && isEnabled ? Theme.fillHover : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .accessibilityLabel(title)
    }
}
