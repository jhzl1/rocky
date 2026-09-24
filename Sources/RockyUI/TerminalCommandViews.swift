import AppKit
import RockyKit
import SwiftUI

/// Where one of Claude Code's terminal commands is (CMD-08): offered in the strip, running in the embedded terminal,
/// or finished. It lives in the conversation's view, as in Conductor: nothing is stored, and a relaunch forgets it.
struct TerminalCommandState: Equatable {
    enum Stage: Equatable {
        /// "Run /mcp in the embedded terminal", with Open terminal.
        case pending
        /// The terminal is open and the command runs in it.
        case running
        /// "Terminal command finished", with Refresh.
        case done
    }

    var command: TerminalOnlyCommand
    var stage: Stage
}

/// What a conversation's view needs from `AppModel` for its embedded terminal (CMD-08). ChatView has no `AppModel`:
/// `WorkspaceDetailView` builds this for the conversation it shows.
@MainActor
struct EmbeddedTerminalHost {
    /// The conversation's terminal, running or finished; nil while none is open.
    var session: PTYSession?
    var open: @MainActor (TerminalOnlyCommand) async -> PTYSession?
    var close: @MainActor () async -> Void

    init(model: AppModel, conversationId: String?) {
        guard let conversationId else {
            session = nil
            open = { _ in nil }
            close = {}
            return
        }
        session = model.embeddedTerminal(conversationId: conversationId)
        open = { await model.openEmbeddedTerminal(conversationId: conversationId, command: $0) }
        close = { await model.closeEmbeddedTerminal(conversationId: conversationId) }
    }
}

extension NSUserInterfaceItemIdentifier {
    /// The embedded terminal's view: while it has the keyboard, ChatView's key monitor leaves every key to it.
    static let embeddedTerminal = NSUserInterfaceItemIdentifier("rocky.embedded-terminal")
}

/// The strip at the top of the message box (CMD-08): 12.5-point `textSecondary` text with the command in 12-point
/// monospaced `textPrimary`, the stage's button, and × to dismiss. The message box draws the fill, the border and the
/// hairline under it, so the two read as one box.
struct TerminalCommandStrip: View {
    let state: TerminalCommandState
    /// Refresh waits for the turn in progress.
    let canRefresh: Bool
    let onOpen: () -> Void
    let onRefresh: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            message
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch state.stage {
            case .pending:
                Button(action: onOpen) {
                    Label("Open terminal", systemImage: "apple.terminal")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(RockyFilledButtonStyle(height: 24))
                .font(.rocky(12))
                .help("Run \(state.command.label) in a terminal above the message box")
            case .running:
                EmptyView()
            case .done:
                Button("Refresh", action: onRefresh)
                    .buttonStyle(RockyFilledButtonStyle(height: 24))
                    .font(.rocky(12))
                    .disabled(!canRefresh)
                    .help(canRefresh
                        ? "Restart Claude Code in this conversation, so it reads the new configuration"
                        : "Refresh restarts Claude Code once the turn in progress ends")
            }
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .buttonStyle(RockyIconButtonStyle(size: 24))
                .font(.rocky(10, weight: .semibold))
                .help(state.stage == .running ? "Stop the terminal and dismiss" : "Dismiss")
        }
        .font(.rocky(12.5))
        .foregroundStyle(Theme.textSecondary)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: Zoom.shared(38))
    }

    private var message: Text {
        let command = Text(verbatim: state.command.label)
            .font(.rocky(12, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
        return switch state.stage {
        case .pending: Text(verbatim: "Run ") + command + Text(verbatim: " in the embedded terminal")
        case .running: Text(verbatim: "Complete ") + command + Text(verbatim: " below, then click Done")
        case .done: Text(verbatim: "Terminal command finished. Refresh to use the updated config here")
        }
    }
}

/// The embedded terminal above the strip (CMD-08): 224 points tall, radius 10, a 1-point border, on the terminal's
/// background. Its 28-point header says how the command is doing, then Done and ×.
struct EmbeddedTerminalView: View {
    let session: PTYSession
    let command: TerminalOnlyCommand
    let onDone: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(verbatim: status)
                    .font(.rocky(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Done", action: onDone)
                    .buttonStyle(RockyTextButtonStyle(height: 24))
                    .font(.rocky(12))
                    .help(session.state.isRunning ? "Stop \(command.label) and close the terminal" : "Close the terminal")
                Button("Stop and close", systemImage: "xmark", action: onClose)
                    .buttonStyle(RockyIconButtonStyle(size: 24))
                    .font(.rocky(10, weight: .semibold))
                    .help("Stop \(command.label) and close the terminal")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: Zoom.shared(28))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            TerminalHostView(session: session, zoom: Zoom.shared.scale, identifier: .embeddedTerminal, focusesOnAppear: true)
                .id(session.id)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: Zoom.shared(224))
        .background(Color.rockyBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.composerBorder))
    }

    /// "Starting /mcp…" until Claude Code draws something, "Running /mcp." while it runs, "Finished /mcp." after.
    private var status: String {
        guard session.state.isRunning else { return "Finished \(command.label)." }
        return session.hasOutput ? "Running \(command.label)." : "Starting \(command.label)…"
    }
}
