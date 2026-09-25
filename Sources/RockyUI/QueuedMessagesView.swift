import RockyKit
import SwiftUI

/// A message waiting for the agent's turn to end, at the end of the conversation where it will be sent (user
/// decision, 2026-09-23: not floating over the message box). Drawn like the user's messages but dimmer, with a
/// dashed edge; the queue shares one `QueueCaption` under its last message. On hover, like Conductor's queue: send
/// it now (which stops the turn in progress first), take it back into the message box to edit it when the box is
/// empty, or delete it. A line comment (CMT-05) shows its chip over the comment and offers Send now, Edit and Remove;
/// its Edit brings the chip back into the box with the text, as ↑ does, and the code it was queued with goes (Edit was
/// left out while the box could not hold a chip; the designer's update, 2026-09-25, puts it back).
struct QueuedMessageRow: View {
    let message: QueuedMessage
    let isAgentWorking: Bool
    let canEdit: Bool
    let onSendNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            actions
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            bubble
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
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

    private var actions: some View {
        HStack(spacing: 2) {
            Button("Send now", action: onSendNow)
                .buttonStyle(RockyTextButtonStyle(height: 22))
                .help(isAgentWorking ? "Stop the agent's turn and send this now" : "Send this now")
            Button("Edit", systemImage: "pencil", action: onEdit)
                .buttonStyle(RockyIconButtonStyle(size: 22))
                .disabled(!canEdit)
                .help(canEdit ? "Edit in the message box" : "Send or clear the message box first")
            if message.lineComment == nil {
                Button("Delete", systemImage: "xmark", action: onDelete)
                    .buttonStyle(RockyIconButtonStyle(size: 22))
                    .help("Delete this queued message")
            } else {
                Button("Remove", systemImage: "xmark", action: onDelete)
                    .buttonStyle(RockyIconButtonStyle(size: 22))
                    .help("Remove this queued comment")
            }
        }
        .font(.rocky(12))
    }
}

/// Under the last queued message, once for the whole queue: "Queued", "3 queued", or why it is waiting.
struct QueueCaption: View {
    let count: Int
    let isHeld: Bool

    private var text: String {
        if isHeld { return "On hold until your next message" }
        return count == 1 ? "Queued" : "\(count) queued"
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock")
            Text(text)
        }
        .font(.rocky(11))
        .foregroundStyle(Theme.textTertiary)
    }
}
