import RockyKit
import SwiftUI

/// The bottom panel of a workspace: one tab per script that ran (Setup, Run, Archive) and per terminal. It folds to
/// its bar (⌘J) without stopping anything; choosing a tab or opening a terminal unfolds it. `WorkspaceDetailView`
/// sets its height and draws the line above it (`PanelDivider`).
struct WorkspacePanelView: View {
    let model: AppModel
    let workspace: Workspace
    @Binding var selection: UUID?
    @Binding var isCollapsed: Bool
    /// The panel's height while open, bar included (TERM-01). The terminal keeps its open height while the panel
    /// folds or unfolds, so the animation slides it instead of resizing it on every frame, which the shell would get
    /// as a stream of window size changes.
    let openHeight: CGFloat

    /// The bar's height (TERM-02); folded or empty, the panel is only this. The same as the sidebar's footer.
    static var barHeight: CGFloat {
        Zoom.shared(WindowMetrics.bottomBarHeight)
    }

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

    var body: some View {
        VStack(spacing: 0) {
            bar
            if let selected, !isCollapsed {
                terminal(for: selected)
                    .frame(height: max(0, openHeight - Self.barHeight))
            }
        }
    }

    /// TERM-02: the tabs, "+", and at the right only the fold chevron. No state text: it sat far from the tab it
    /// described and read as the whole panel's state (user feedback, 2026-09-23); the dots and tooltips carry it.
    private var bar: some View {
        HStack(spacing: 4) {
            if sessions.isEmpty {
                // TERM-04: one control instead of a "Terminal" label that did nothing next to a "+".
                Button(action: openTerminal) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                        Text("New terminal")
                    }
                }
                .buttonStyle(RockyTextButtonStyle(height: 24))
                .help("Open a terminal in this workspace")
            } else {
                ForEach(sessions) { session in
                    tab(for: session)
                }
                Button("New terminal", systemImage: "plus", action: openTerminal)
                    .buttonStyle(RockyIconButtonStyle(size: 22))
                    .help("New terminal")
                Spacer(minLength: 0)
                Button(isCollapsed ? "Show panel" : "Hide panel", systemImage: isCollapsed ? "chevron.up" : "chevron.down") {
                    isCollapsed.toggle()
                }
                .buttonStyle(RockyIconButtonStyle(size: 22))
                .keyboardShortcut("j", modifiers: .command)
                .help(isCollapsed ? "Show the terminal panel (⌘J)" : "Hide the terminal panel; its terminals keep running (⌘J)")
            }
        }
        .font(.rocky(12))
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.barHeight)
        .background(Theme.panelBar)
    }

    /// TERM-06: the terminal on `background`, 12 points from the sides, 6 above and 8 below. Once its process has
    /// ended, the end line sits under the output (TERM-03), drawn here instead of written into the PTY.
    private func terminal(for session: PTYSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TerminalHostView(session: session, zoom: Zoom.shared.scale)
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let end = ProcessOutcome(session).endLine {
                Text(end.text)
                    .font(.rocky(12, design: .monospaced))
                    .foregroundStyle(end.isFailure ? Theme.danger : Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.rockyBackground)
    }

    /// A new "Terminal N", selected, with the panel unfolded (TERM-07).
    private func openTerminal() {
        selection = model.openTerminal(workspaceId: workspace.id)?.id
        isCollapsed = false
    }

    /// "Terminal 1", "Terminal 2"… by position, so the numbers always run from 1 to the number of terminals.
    /// Scripts keep their own names (Setup, Run, Archive).
    private func title(for session: PTYSession) -> String {
        guard let position = processes?.terminals.firstIndex(where: { $0.id == session.id }) else { return session.title }
        return "Terminal \(position + 1)"
    }

    private func tab(for session: PTYSession) -> some View {
        let isTerminal = processes?.terminals.contains(where: { $0.id == session.id }) ?? false
        // Only terminals close; scripts cannot (TERM-02).
        var onClose: (() -> Void)?
        if isTerminal {
            onClose = { Task { await model.closeTerminal(workspaceId: workspace.id, sessionId: session.id) } }
        }
        return PanelTab(
            title: title(for: session),
            outcome: ProcessOutcome(session),
            // Folded, no tab shows as selected (TERM-05).
            isSelected: session.id == selected?.id && !isCollapsed,
            onSelect: {
                selection = session.id
                isCollapsed = false
            },
            onClose: onClose
        )
    }
}

/// One tab of the panel bar (TERM-02): the process's dot and its name, lit on hover and while selected with the
/// neutral fills (the accent is for unread and focus only). A terminal's close button, like a conversation tab's,
/// always takes its space and shows on hover or while selected.
private struct PanelTab: View {
    let title: String
    let outcome: ProcessOutcome
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: (() -> Void)?
    @State private var hovering = false

    private var isLit: Bool {
        hovering || isSelected
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(outcome.dotColor)
                        .frame(width: Zoom.shared(6), height: Zoom.shared(6))
                    Text(title)
                        .lineLimit(1)
                }
                .padding(.leading, 8)
                .padding(.trailing, onClose == nil ? 8 : 2)
                .frame(height: Zoom.shared(24))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickable()
            .accessibilityLabel("\(title), \(outcome.tooltipText)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if let onClose {
                Button("Close terminal", systemImage: "xmark", action: onClose)
                    .font(.rocky(10))
                    .buttonStyle(RockyIconButtonStyle(size: 16))
                    .opacity(isLit ? 1 : 0)
                    .allowsHitTesting(isLit)
                    .help("Close the terminal")
                    .padding(.trailing, 4)
            }
        }
        .foregroundStyle(isLit ? Theme.textPrimary : Theme.textSecondary)
        .background(isSelected ? Theme.fillSelected : hovering ? Theme.fillHover : .clear, in: RoundedRectangle(cornerRadius: 6))
        // TERM-03: "Setup: failed, exit code 1".
        .help("\(title): \(outcome.tooltipText)")
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// How the panel words a process's state (TERM-03): the dot, the tooltip after the tab's name, and the line under a
/// finished process's output. Here in RockyUI; `PTYState.description` stays as it is, for logs. What Rocky stopped
/// reads "stopped" however it ended; a signal Rocky did not send is a failure (a crash, a kill from elsewhere).
enum ProcessOutcome: Equatable {
    case running, succeeded, stopped, couldNotStart
    case failed(Int32)
    case killed(Int32)

    @MainActor
    init(_ session: PTYSession) {
        switch session.state {
        case .running: self = .running
        case _ where session.stopRequested: self = .stopped
        case .exited(0): self = .succeeded
        case .exited(let code): self = .failed(code)
        case .signaled(let signal): self = .killed(signal)
        case .failedToStart: self = .couldNotStart
        }
    }

    var dotColor: Color {
        switch self {
        case .running: Theme.success
        case .succeeded, .stopped: Theme.textTertiary
        case .failed, .killed, .couldNotStart: Theme.danger
        }
    }

    var tooltipText: String {
        switch self {
        case .running: "running"
        case .succeeded: "exited with code 0"
        case .stopped: "stopped"
        case .failed(let code): "failed, exit code \(code)"
        case .killed(let signal): "failed, ended by signal \(signal)"
        case .couldNotStart: "could not start"
        }
    }

    /// Nil while the process runs.
    var endLine: (text: String, isFailure: Bool)? {
        switch self {
        case .running: nil
        case .succeeded: ("Process exited with code 0", false)
        case .stopped: ("Process stopped", false)
        case .failed(let code): ("Process exited with code \(code)", true)
        case .killed(let signal): ("Process ended by signal \(signal)", true)
        case .couldNotStart: ("Process could not start", true)
        }
    }
}
