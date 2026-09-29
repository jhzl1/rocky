import RockyKit
import SwiftUI

/// TERM-05's fold of the terminal panel, global and kept across launches, which ⌘J, ⌃` (KBD-04), New Terminal and the
/// settings share.
enum TerminalPanelStorage {
    static let collapsedKey = "terminalPanelCollapsed"
}

/// KBD-04: the panel terminal that is to take the keyboard, for the ⌃` press whose serial this is. The terminal takes
/// it once, whether it is on screen already or appears with the panel, and the request is then dropped.
struct TerminalFocusRequest: Equatable {
    let sessionId: UUID
    let serial: Int
}

/// TSK-02: repository id → the item last run from the Run menu, as `RunItem.encodeAll` writes it; kept across launches.
enum RunMenuStorage {
    static let lastItemsKey = "lastRunItemByRepo"
}

/// The bottom panel of a workspace: Run, then one tab per script that ran (Setup, Run, Archive), per VS Code task and
/// per terminal. It folds to its bar (⌘J) without stopping anything; choosing a tab, opening a terminal or Run unfolds
/// it. `WorkspaceDetailView` sets its height and draws the line above it (`PanelDivider`).
struct WorkspacePanelView: View {
    let model: AppModel
    let workspace: Workspace
    @Binding var selection: UUID?
    @Binding var isCollapsed: Bool
    /// The panel's height while open, bar included (TERM-01). The terminal keeps its open height while the panel
    /// folds or unfolds, so the animation slides it instead of resizing it on every frame, which the shell would get
    /// as a stream of window size changes.
    let openHeight: CGFloat
    /// KBD-04: the terminal ⌃` gives the keyboard to, set by `WorkspaceDetailView` and cleared once it has it.
    @Binding var focusRequest: TerminalFocusRequest?
    @AppStorage(RunMenuStorage.lastItemsKey) private var lastRunItems = ""
    /// The Run split button's frame in window coordinates: its menu and the input pickers open above it.
    @State private var runFrame: CGRect = .zero
    @Environment(MenuPresenter.self) private var menus: MenuPresenter?
    @Environment(ToastPresenter.self) private var toasts: ToastPresenter?

    /// The tab the panel shows: the chosen one, else the newest.
    static func shownSession(among sessions: [PTYSession], selection: UUID?) -> PTYSession? {
        sessions.first { $0.id == selection } ?? sessions.last
    }

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

    /// The chosen tab, else the newest one. A task tab reused by a new run is still the chosen one (Decision 7 of
    /// M2.9).
    private var selected: PTYSession? {
        Self.shownSession(among: sessions, selection: processes?.current(selection) ?? selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            if let selected, !isCollapsed {
                terminal(for: selected)
                    .frame(height: max(0, openHeight - Self.barHeight))
            }
        }
        // TSK-02: whether Run is the split button. One look for the file when the panel appears, nothing read.
        .task { await model.lookForTasks(workspaceId: workspace.id) }
    }

    /// WSC-03: "Creating lima…" while the worktree does not exist: Run, New terminal and the tasks wait for it.
    private var creatingHint: String? {
        model.creatingHint(workspaceId: workspace.id)
    }

    /// TERM-02: Run (LAY-01), the tabs, "+", and at the right only the fold chevron. No state text: it sat far from the
    /// tab it described and read as the whole panel's state (user feedback, 2026-09-23); the dots and tooltips carry it.
    private var bar: some View {
        HStack(spacing: 4) {
            runButton
            // The mock's 1 × 14 hairline, 4 points more on each side than the row's gap.
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1, height: Zoom.shared(14))
                .padding(.horizontal, 4)
                .accessibilityHidden(true)
            if sessions.isEmpty {
                // TERM-04: one control instead of a "Terminal" label that did nothing next to a "+".
                Button(action: openTerminal) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                        Text("New terminal")
                    }
                }
                .buttonStyle(RockyTextButtonStyle(height: 24))
                .disabled(creatingHint != nil)
                .help(creatingHint ?? "Open a terminal in this workspace")
            } else {
                ForEach(sessions) { session in
                    tab(for: session)
                }
                Button("New terminal", systemImage: "plus", action: openTerminal)
                    .buttonStyle(RockyIconButtonStyle(size: 22))
                    .disabled(creatingHint != nil)
                    .help(creatingHint ?? "New terminal")
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

    /// Run: TSK-02's split button when the repository has a `tasks.json`, else today's plain button; a plain Run, off,
    /// until the worktree exists (WSC-03).
    @ViewBuilder
    private var runButton: some View {
        if let creatingHint {
            Button {} label: {
                runLabel("Run", systemImage: "play.fill")
            }
            .buttonStyle(Self.runStyle)
            .disabled(true)
            .help(creatingHint)
        } else if let runMenu = model.runMenus[workspace.id], runMenu.hasTasksFile {
            runSplit(runMenu)
        } else {
            plainRunButton
        }
    }

    /// LAY-01: Run moved here from the top bar (TB-04), before the tabs, where its output shows: "▶ Run" 24 points in
    /// Rocky's filled style starts the run script, selects its tab and unfolds the panel (TERM-07); "■ Stop" stops it.
    @ViewBuilder
    private var plainRunButton: some View {
        if let run = processes?.run, run.state.isRunning {
            Button {
                Task { await model.stopRun(workspaceId: workspace.id) }
            } label: {
                runLabel("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(Self.runStyle)
            .help("Stop the run script")
        } else {
            Button {
                Task {
                    await model.startRun(workspaceId: workspace.id)
                    // Nothing started (no run script: the model shows why), so there is nothing to show.
                    guard let started = model.existingProcesses(for: workspace.id)?.run else { return }
                    selection = started.id
                    isCollapsed = false
                }
            } label: {
                runLabel("Run", systemImage: "play.fill")
            }
            .buttonStyle(Self.runStyle)
            .help("Run the workspace's run script")
        }
    }

    /// The mock's `.run-mini`: 24 high, padding 8, radius 5.
    private static let runStyle = RockyFilledButtonStyle(height: 24, horizontalPadding: 8, cornerRadius: 5)

    // MARK: TSK-02's split button

    private var runMenuId: String {
        "run-\(workspace.id)"
    }

    private var lastRunItem: RunItem? {
        RunItem.decodeAll(lastRunItems)[workspace.repoId]
    }

    /// TSK-02: 24 high, radius 5, on `fillButton`. The main part runs the default ("▶ Run" for the Run script, "▶ label"
    /// for a task, cut at 180 points), or reads "■ Stop" while the default runs; a 1-point black 35 % line; the chevron,
    /// 20 wide, opens the menu above, and keeps white 6 % while it is open. The default is worked out from the last
    /// look: the click that runs it reads the file first.
    private func runSplit(_ state: RunMenuState) -> some View {
        let item = state.defaultItem(last: lastRunItem)
        let running = item.map(isRunning) ?? false
        return HStack(spacing: 0) {
            Button {
                if running, let item { stop(item) } else { runDefault() }
            } label: {
                runLabel(running ? "Stop" : title(of: item), systemImage: running ? "stop.fill" : "play.fill")
                    .lineLimit(1)
                    .frame(maxWidth: Zoom.shared(180), alignment: .leading)
            }
            .buttonStyle(RunSplitPartStyle(horizontalPadding: 8))
            .help(running ? stopHelp(for: item) : runHelp(for: item))
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: 1)
            Button(action: toggleRunMenu) {
                Image(systemName: "chevron.down")
                    .font(.rocky(9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Zoom.shared(20))
            }
            .buttonStyle(RunSplitPartStyle(isLit: menus?.isOpen(runMenuId) ?? false))
            .help("Run a task")
            .accessibilityLabel("Choose what Run runs")
        }
        .frame(height: Zoom.shared(24))
        .background(Theme.fillButton)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .fixedSize()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            runFrame = frame
            menus?.move(runMenuId, to: frame)
        }
    }

    private func title(of item: RunItem?) -> String {
        if case .task(let label)? = item { return label }
        return "Run"
    }

    private func runHelp(for item: RunItem?) -> String {
        switch item {
        case .runScript?: "Run the run script"
        case .task(let label)?: "Run the task “\(label)”"
        case nil: "Choose what to run"
        }
    }

    private func stopHelp(for item: RunItem?) -> String {
        if case .task(let label)? = item { return "Stop the task “\(label)” and what it started" }
        return "Stop the run script"
    }

    private func isRunning(_ item: RunItem) -> Bool {
        switch item {
        case .runScript: processes?.run?.state.isRunning == true
        case .task(let label): model.taskSession(workspaceId: workspace.id, label: label) != nil
        }
    }

    /// TSK-02's main part: reads the file and the Run script, then runs the default, or opens the menu when there is
    /// none. A file that went away meanwhile leaves today's Run.
    private func runDefault() {
        Task {
            guard let state = await model.readRunMenu(workspaceId: workspace.id) else { return }
            guard state.hasTasksFile else {
                await run(.runScript)
                return
            }
            if let item = state.defaultItem(last: lastRunItem) {
                await run(item)
            } else {
                showRunMenu()
            }
        }
    }

    /// TSK-01: the file is read each time the menu opens; the menu shows what it had meanwhile.
    private func toggleRunMenu() {
        if menus?.isOpen(runMenuId) == true {
            menus?.dismiss()
            return
        }
        showRunMenu()
        Task { await model.readRunMenu(workspaceId: workspace.id) }
    }

    private func showRunMenu() {
        menus?.show(.init(
            id: runMenuId,
            anchor: runFrame,
            placement: .aboveLeading,
            width: Zoom.shared(300),
            content: AnyView(RunMenuContent(model: model, workspace: workspace, lastItem: lastRunItem, choose: choose))
        ))
    }

    /// TSK-02: a choice runs and becomes the repository's default, kept across launches.
    private func choose(_ item: RunItem) {
        var items = RunItem.decodeAll(lastRunItems)
        items[workspace.repoId] = item
        lastRunItems = RunItem.encodeAll(items)
        Task { await run(item) }
    }

    private func run(_ item: RunItem) async {
        switch item {
        case .runScript: await runScript()
        case .task(let label): await runTask(label)
        }
    }

    /// The Run script, as the plain button runs it; running already, its tab shows (TSK-02).
    private func runScript() async {
        if let run = processes?.run, run.state.isRunning {
            selection = run.id
            isCollapsed = false
            return
        }
        await model.startRun(workspaceId: workspace.id)
        // Nothing started (no run script: the model shows why), so there is nothing to show.
        guard let started = model.existingProcesses(for: workspace.id)?.run else { return }
        selection = started.id
        isCollapsed = false
    }

    /// TSK-03…TSK-05, TSK-07: the model asks the inputs through the pickers above Run and starts the chain, whose tabs
    /// show through its reveal requests (Decision 12). What stopped it is a toast; a failed dependency's has Show, which
    /// selects its tab, from any workspace.
    private func runTask(_ label: String) async {
        let prompter = TaskInputPrompter(menus: menus, anchor: { runFrame })
        let outcome = await model.runTask(workspaceId: workspace.id, label: label, ask: prompter.ask)
        switch outcome {
        case .started, .alreadyRunning, .cancelled, .stopped:
            break
        case .invalid(let error):
            toasts?.show(error.description)
        case .failed(let dependency, let process):
            let model = self.model
            let workspaceId = workspace.id
            let show = process.map { sessionId in
                ToastAction(title: "Show") {
                    if model.selectedWorkspaceId != workspaceId { model.selectedWorkspaceId = workspaceId }
                    model.revealTerminal(workspaceId: workspaceId, sessionId: sessionId)
                }
            }
            toasts?.show("“\(dependency)” failed, so “\(label)” didn't start", action: show)
        }
    }

    /// TSK-06: the Run script's Stop, or the task's with what its run started.
    private func stop(_ item: RunItem) {
        Task {
            switch item {
            case .runScript: await model.stopRun(workspaceId: workspace.id)
            case .task(let label): await model.stopTask(workspaceId: workspace.id, label: label)
            }
        }
    }

    private func runLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.rocky(10))
            Text(title)
                .font(.rocky(12, weight: .medium))
        }
    }

    /// TERM-06: the terminal on `background`, 12 points from the sides, 6 above and 8 below. Once its process has
    /// ended, the end line sits under the output (TERM-03), drawn here instead of written into the PTY.
    private func terminal(for session: PTYSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TerminalHostView(
                session: session,
                zoom: Zoom.shared.scale,
                focusRequest: focusRequest?.sessionId == session.id ? focusRequest?.serial : nil,
                onFocused: { serial in
                    if focusRequest?.serial == serial { focusRequest = nil }
                }
            )
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
        Task {
            selection = await model.openTerminal(workspaceId: workspace.id)?.id
            isCollapsed = false
        }
    }

    /// "Terminal 1", "Terminal 2"… by position, so the numbers always run from 1 to the number of terminals.
    /// Scripts keep their own names (Setup, Run, Archive).
    private func title(for session: PTYSession) -> String {
        guard let position = processes?.terminals.firstIndex(where: { $0.id == session.id }) else { return session.title }
        return "Terminal \(position + 1)"
    }

    private func tab(for session: PTYSession) -> some View {
        let isTerminal = processes?.terminals.contains(where: { $0.id == session.id }) ?? false
        let isTask = processes?.tasks.contains(where: { $0.id == session.id }) ?? false
        let isSetup = processes?.setup?.id == session.id
        // Terminals and tasks close, a task's stopping its process (TSK-06); so does Setup, so a hook that hangs never
        // holds WSC-01's guard until Rocky quits. Run and Archive cannot (TERM-02).
        var onClose: (() -> Void)?
        if isTerminal {
            onClose = { Task { await model.closeTerminal(workspaceId: workspace.id, sessionId: session.id) } }
        } else if isTask {
            onClose = { Task { await model.closeTask(workspaceId: workspace.id, sessionId: session.id) } }
        } else if isSetup {
            onClose = { Task { await model.closeSetup(workspaceId: workspace.id) } }
        }
        let closeHelp = if isTask {
            "Close the task; its process stops"
        } else if isSetup {
            session.state.isRunning ? "Stop and close Setup" : "Close Setup"
        } else {
            "Close the terminal"
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
            closeHelp: closeHelp,
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
    let closeHelp: String
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
                Button(closeHelp, systemImage: "xmark", action: onClose)
                    .font(.rocky(10))
                    .buttonStyle(RockyIconButtonStyle(size: 16))
                    .opacity(isLit ? 1 : 0)
                    .allowsHitTesting(isLit)
                    .help(closeHelp)
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

/// TSK-02's two parts, under the split button's clip: white 6 % on hover, 10 % pressed, and 6 % kept while `isLit`
/// (the chevron while its menu is open), over the button's `fillButton`.
private struct RunSplitPartStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 0
    var isLit = false

    func makeBody(configuration: Configuration) -> some View {
        RunSplitPart(configuration: configuration, horizontalPadding: horizontalPadding, isLit: isLit)
    }

    private struct RunSplitPart: View {
        let configuration: Configuration
        let horizontalPadding: CGFloat
        let isLit: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, horizontalPadding)
                .frame(maxHeight: .infinity)
                .background(Color.white.opacity(configuration.isPressed ? 0.10 : hovering || isLit ? 0.06 : 0))
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
                .clickable()
        }
    }
}

/// TSK-02's menu, 300 wide above Run: "Run script" with the script as its second line, when there is one; a divider;
/// the caption "Tasks" and the listed tasks, each with its `detail` (TSK-01). The default item has the check at its
/// right end, a running one the `success` dot. TSK-07: a file that cannot be read is one disabled item with the
/// decoder's message; a task of another type is disabled with the reason as its tooltip. Until the read the menu opened
/// has answered, a spinner stands for the tasks.
private struct RunMenuContent: View {
    let model: AppModel
    let workspace: Workspace
    let lastItem: RunItem?
    let choose: (RunItem) -> Void

    var body: some View {
        let state = model.runMenus[workspace.id] ?? RunMenuState(tasks: .unread)
        let current = state.defaultItem(last: lastItem)
        if state.runScript != nil || state.runScriptFailure != nil {
            MenuItem(
                title: "Run script",
                detail: state.runScript ?? state.runScriptFailure,
                isChecked: current == .runScript,
                detailSize: 11.5,
                disabledReason: state.runScriptFailure,
                isRunning: model.existingProcesses(for: workspace.id)?.run?.state.isRunning == true
            ) {
                choose(.runScript)
            }
            MenuDivider()
        }
        switch state.tasks {
        case .loaded(let file):
            MenuSectionTitle(title: "Tasks", size: 10.5)
            let listed = VSCodeTasks.listed(file)
            if listed.isEmpty {
                MenuItem(title: "No tasks to run", disabledReason: "Every task of tasks.json is hidden: its label starts with “_” or it has \"hide\": true") {}
            }
            ForEach(Array(listed.enumerated()), id: \.offset) { _, task in
                MenuItem(
                    title: task.label,
                    detail: task.detail,
                    isChecked: current == .task(task.label),
                    detailSize: 11.5,
                    disabledReason: task.unsupportedReason,
                    isRunning: model.taskSession(workspaceId: workspace.id, label: task.label) != nil
                ) {
                    choose(.task(task.label))
                }
            }
        case .invalid(let message):
            MenuItem(title: "tasks.json can't be read", detail: message, detailSize: 11.5, disabledReason: message) {}
        case .unread:
            CircularProgress(size: 14)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        case .missing:
            // The file went away since the panel looked: Run is the plain button again.
            EmptyView()
        }
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
