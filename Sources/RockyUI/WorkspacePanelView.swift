import RockyKit
import SwiftUI

/// The bottom panel of a workspace: one tab per script that ran (Setup, Run, Archive) and per terminal.
struct WorkspacePanelView: View {
    let model: AppModel
    let workspace: Workspace
    @Binding var selection: UUID?

    private var processes: WorkspaceProcesses? {
        model.existingProcesses(for: workspace.id)
    }

    private var sessions: [PTYSession] {
        processes?.all ?? []
    }

    /// The chosen tab, else the newest one.
    private var selected: PTYSession? {
        sessions.first { $0.id == selection } ?? sessions.last
    }

    /// With no terminal or script yet, the panel is only its bar, so the chat keeps the window.
    var isEmpty: Bool {
        sessions.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 4) {
                if isEmpty {
                    Label("Terminal", systemImage: "terminal")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                ForEach(sessions) { session in
                    tab(for: session)
                }
                Button("New Terminal", systemImage: "plus") {
                    selection = model.openTerminal(workspaceId: workspace.id)?.id
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("New Terminal")
                Spacer()
                if let selected {
                    Text(selected.state.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            // A fixed tint: the system bar material picks up the wallpaper's color.
            .background(Color.white.opacity(0.03))
            if let selected {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                TerminalHostView(session: selected)
                    .id(selected.id)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.rockyBackground)
            }
        }
    }

    private func tab(for session: PTYSession) -> some View {
        let isTerminal = processes?.terminals.contains(where: { $0.id == session.id }) ?? false
        return HStack(spacing: 4) {
            Button {
                selection = session.id
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(session.state.isRunning ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(session.title)
                }
            }
            .buttonStyle(.plain)
            if isTerminal {
                Button("Close Terminal", systemImage: "xmark") {
                    Task { await model.closeTerminal(workspaceId: workspace.id, sessionId: session.id) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            session.id == selected?.id ? Color.accentColor.opacity(0.2) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
    }
}
