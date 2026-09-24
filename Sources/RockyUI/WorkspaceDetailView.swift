import AppKit
import RockyKit
import SwiftUI

struct WorkspaceDetailView: View {
    let model: AppModel
    let workspace: Workspace
    @State private var panelSelection: UUID?
    /// The terminal panel folded to its bar; its terminals and scripts keep running.
    @AppStorage("terminalPanelCollapsed") private var panelCollapsed = false
    /// The terminal panel's height while open, bar included (TERM-01), the same for every workspace.
    @AppStorage("terminalPanelHeight") private var panelHeight = 220.0
    @Environment(\.titleBarLeadingInset) private var titleBarLeadingInset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// TERM-01: the open panel is never shorter than this, bar included.
    private static let minPanelHeight = 140.0
    /// TERM-01: what the chat keeps however tall the panel is dragged.
    private static let minChatHeight = 200.0

    /// Read from the model, not kept here: a chat the model stops (for example after a settings change) must go away.
    private var chat: ChatSessionModel? {
        model.existingChat(workspaceId: workspace.id)
    }

    private var run: PTYSession? {
        model.existingProcesses(for: workspace.id)?.run
    }

    /// Open: something ran in the panel and it is not folded. Otherwise the panel is only its bar (TERM-04, TERM-05).
    private var isPanelOpen: Bool {
        let hasSessions = !(model.existingProcesses(for: workspace.id)?.all.isEmpty ?? true)
        return hasSessions && !panelCollapsed
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ConversationTabs(model: model, workspace: workspace)
            split
        }
        .task {
            await model.showConversations(workspace: workspace)
        }
        // A file badge anywhere in the workspace opens its file in a tab here.
        .environment(\.openFile, OpenFileAction { [model, workspace] path in
            model.openFile(workspaceId: workspace.id, path: path)
        })
    }

    /// One row as tall as the title bar (TB-01): repository / branch, then Open and Run. It replaces the two-line
    /// header: the path moved into the Open menu, the workspace name into the sidebar row's tooltip. The ports are
    /// not shown anywhere (user decision, 2026-09-23: they read as noise); scripts and terminals still get $PORT.
    private var topBar: some View {
        HStack(spacing: 10) {
            if let repo = model.repo(id: workspace.repoId) {
                Text(repo.name)
                    .font(.rocky(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                // 4 here plus the branch button's own padding of 6 is the row's gap of 10 up to the branch glyph.
                HStack(spacing: 4) {
                    Text(verbatim: "/")
                        .font(.rocky(13))
                        .foregroundStyle(Theme.separatorGlyph)
                        .accessibilityHidden(true)
                    BranchCopyButton(branch: workspace.branch)
                }
                .layoutPriority(1)
            } else {
                BranchCopyButton(branch: workspace.branch)
            }
            Spacer(minLength: 0)
            openMenu
            runButton
        }
        // With the sidebar hidden, the inset already holds the 16-point margin before the window buttons (WIN-02).
        .padding(.leading, titleBarLeadingInset > 0 ? titleBarLeadingInset : 16)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity)
        // H is AppKit's and does not follow the zoom; at the largest zooms Run outgrows it, and the row grows with it
        // rather than clip it.
        .frame(minHeight: WindowMetrics.titleBarHeight)
        // The row is where the title bar was: drag the window from its empty space.
        .windowDragBackground()
    }

    /// TB-03: the worktree path as the header, then Open in Finder, New Terminal and Copy Path.
    private var openMenu: some View {
        MenuButton(id: "open-\(workspace.id)", placement: .belowTrailing, width: 280) { isOpen in
            MenuIconButtonLabel(title: "Open", systemImage: "arrow.up.forward.square", isOpen: isOpen)
                .font(.rocky(14))
        } content: {
            OpenMenuPathHeader(path: workspace.path)
            MenuDivider()
            MenuItem(title: "Open in Finder", icon: .symbol("folder")) {
                _ = NSWorkspace.shared.open(URL(fileURLWithPath: workspace.path, isDirectory: true))
            }
            MenuItem(title: "New Terminal", icon: .symbol("terminal")) {
                // TERM-07: a new "Terminal N", selected, with the panel unfolded.
                panelSelection = model.openTerminal(workspaceId: workspace.id)?.id
                panelCollapsed = false
            }
            MenuItem(title: "Copy Path", icon: .symbol("doc.on.doc")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspace.path, forType: .string)
            }
        }
        .fixedSize()
        .help("Open in Finder or Terminal")
    }

    /// TB-04: Run starts the run script, selects its tab and unfolds the panel (TERM-07); Stop stops it.
    @ViewBuilder
    private var runButton: some View {
        if let run, run.state.isRunning {
            Button {
                Task { await model.stopRun(workspaceId: workspace.id) }
            } label: {
                runLabel("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(RockyFilledButtonStyle())
            .help("Stop the run script")
        } else {
            Button {
                Task {
                    await model.startRun(workspaceId: workspace.id)
                    // Nothing started (no run script: the model shows why), so there is nothing to show.
                    guard let started = run else { return }
                    panelSelection = started.id
                    panelCollapsed = false
                }
            } label: {
                runLabel("Run", systemImage: "play.fill")
            }
            .buttonStyle(RockyFilledButtonStyle())
            .help("Run the workspace's run script")
        }
    }

    private func runLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.rocky(11))
            Text(title)
                .font(.rocky(12.5, weight: .medium))
        }
    }

    /// Chat above, terminals and script output below (M2 layout decision), in one layout whatever the panel's state
    /// (TERM-01). `VSplitView` drew its own divider and was swapped for a `VStack` while the panel was folded or
    /// empty, which lost the height and could not animate. The chat takes what the panel leaves.
    private var split: some View {
        GeometryReader { proxy in
            let range = panelHeightRange(available: proxy.size.height)
            let openHeight = CGFloat(min(max(panelHeight, range.lowerBound), range.upperBound))
            VStack(spacing: 0) {
                chatArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PanelDivider(height: $panelHeight, range: range, isResizable: isPanelOpen)
                    // Its handle reaches 4 points into the panel bar, which would otherwise be drawn over it.
                    .zIndex(1)
                WorkspacePanelView(
                    model: model,
                    workspace: workspace,
                    selection: $panelSelection,
                    isCollapsed: $panelCollapsed,
                    openHeight: openHeight
                )
                .frame(height: isPanelOpen ? openHeight : WorkspacePanelView.barHeight, alignment: .top)
                .clipped()
            }
            // TERM-05: folding and unfolding animate the height, instantly with Reduce Motion. Switching workspaces
            // never animates it: each workspace gets a new view (`.id(workspace.id)` in RootView), and a drag changes
            // the height without changing this value.
            .animation(reduceMotion ? nil : Theme.Motion.state, value: isPanelOpen)
        }
    }

    /// The open panel's heights in a split `available` points tall: at least `minPanelHeight`, and at most what
    /// leaves the chat `minChatHeight` above the divider's line. The panel's minimum wins in a very short window.
    private func panelHeightRange(available: CGFloat) -> ClosedRange<Double> {
        let upper = Double(available) - Self.minChatHeight - 1
        return Self.minPanelHeight...max(Self.minPanelHeight, upper)
    }

    /// The selected conversation, or the file tab on top of it. The conversation stays underneath a file tab, so its
    /// draft and scroll position are there when you come back.
    private var chatArea: some View {
        let file = model.selectedFiles[workspace.id]
        return ZStack {
            if let chat {
                ChatView(
                    chat: chat,
                    isActive: file == nil,
                    commands: model.commands(for: chat),
                    terminal: EmbeddedTerminalHost(model: model, conversationId: model.selectedConversationIds[workspace.id])
                )
                    // A new view per conversation, so switching tabs does not carry a draft or a scroll position over.
                    .id(ObjectIdentifier(chat))
                    .opacity(file == nil ? 1 : 0)
                    .allowsHitTesting(file == nil)
            } else if file == nil {
                ProgressLabel(text: "Opening the conversation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let file {
                FileTabView(path: file)
                    .background(Color.rockyBackground)
            }
        }
    }
}

/// The workspace's tabs, like Conductor's (TAB-01): its conversations (agent logo and title), then the files opened
/// from a badge (type icon and name); the selected one underlined, and a + for a new Claude Code or OpenCode
/// conversation. A 34-point row with the hairline at its bottom, under the selected tab's underline.
struct ConversationTabs: View {
    let model: AppModel
    let workspace: Workspace

    var body: some View {
        let open = model.conversations[workspace.id] ?? []
        let selectedId = model.selectedConversationIds[workspace.id]
        let files = model.openFiles[workspace.id] ?? []
        let selectedFile = model.selectedFiles[workspace.id]
        TabStripLayout {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(open) { record in
                        let agent = AgentKind(rawValue: record.agent) ?? .claude
                        WorkspaceTab(
                            title: record.title ?? "New conversation",
                            isSelected: record.id == selectedId && selectedFile == nil,
                            onSelect: { Task { await model.showConversation(workspace: workspace, conversationId: record.id) } },
                            onClose: { Task { await model.closeConversation(workspace: workspace, conversationId: record.id) } }
                        ) {
                            // A running conversation shows the spinner in place of its logo (MOT-01, 12 points).
                            if model.chat(conversationId: record.id)?.state == .running {
                                CircularProgress(size: 12)
                            } else {
                                AgentIcon(agent: agent, size: 12)
                            }
                        }
                        .help(record.title ?? "New conversation")
                    }
                    ForEach(files, id: \.self) { path in
                        let kind = FileKind(path: path)
                        WorkspaceTab(
                            title: URL(fileURLWithPath: path).lastPathComponent,
                            isSelected: path == selectedFile,
                            onSelect: { model.showFile(workspaceId: workspace.id, path: path) },
                            onClose: { model.closeFile(workspaceId: workspace.id, path: path) }
                        ) {
                            Image(systemName: kind.symbol)
                                .font(.rocky(11))
                                .foregroundStyle(kind.color)
                        }
                        .help(path)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            MenuButton(id: "new-conversation-\(workspace.id)", placement: .belowLeading, width: 280) { isOpen in
                MenuIconButtonLabel(title: "New conversation", systemImage: "plus", isOpen: isOpen)
            } content: {
                ForEach(AgentKind.allCases) { agent in
                    MenuItem(title: "New \(agent.displayName) conversation", icon: .agent(agent)) {
                        Task { await model.newConversation(workspace: workspace, agent: agent) }
                    }
                }
            }
            .fixedSize()
            .help("New conversation")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Zoom.shared(34))
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

/// One tab of the workspace (TAB-01): an icon, the title (truncated past 240 points), and an × that always takes its
/// space, so hovering never shifts the tabs. `textSecondary` at rest, `textPrimary` on hover and while selected; the
/// selected tab has a 2-point underline on the row's hairline.
struct WorkspaceTab<Icon: View>: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false

    private var isLit: Bool {
        hovering || isSelected
    }

    var body: some View {
        HStack(spacing: 4) {
            TabWidthCap(maxWidth: Zoom.shared(240)) {
                HStack(spacing: 7) {
                    icon()
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 10)
            }
            Button("Close", systemImage: "xmark", action: onClose)
                .font(.rocky(10))
                .buttonStyle(RockyIconButtonStyle(size: 16))
                .opacity(isLit ? 1 : 0)
                .allowsHitTesting(isLit)
                .help("Close the tab")
        }
        .font(.rocky(12.5))
        .foregroundStyle(isLit ? Theme.textPrimary : Theme.textSecondary)
        // 6 after the ×: its 16-point box already leaves 3 around the glyph, as in the design's mock.
        .padding(.trailing, 6)
        .frame(height: Zoom.shared(34))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Theme.textPrimary : Color.clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .clickable()
    }
}

/// The tabs' scroll view, then the "+" right after the last tab. When the tabs do not fit, they scroll and the "+"
/// stays at the row's end. Two subviews, in that order. The scroll view gets exactly its tabs' width, capped by the
/// room the "+" leaves, which a stack cannot give a view that takes any width it is offered.
private struct TabStripLayout: Layout {
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        // Unlimited along its axis, a scroll view reports its content's width.
        let tabs = subviews[0].sizeThatFits(ProposedViewSize(width: nil, height: proposal.height))
        let plus = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? (tabs.width + spacing + plus.width)
        return CGSize(width: width, height: max(tabs.height, plus.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let plus = subviews[1].sizeThatFits(.unspecified)
        let idealTabs = subviews[0].sizeThatFits(ProposedViewSize(width: nil, height: bounds.height)).width
        let tabsWidth = max(0, min(idealTabs, bounds.width - spacing - plus.width))
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: tabsWidth, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + tabsWidth + spacing, y: bounds.midY),
            anchor: .leading,
            proposal: .unspecified
        )
    }
}

/// Caps its content's width even under an unlimited proposal, which is what a horizontal scroll view gives its
/// content, so a long title truncates (TAB-01). `frame(maxWidth:)` there only clamps the size it reports, and the
/// text would still draw at full width over the next tab.
private struct TabWidthCap: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(proposal.width ?? .infinity, maxWidth)
        return content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The label of an icon button that opens a Rocky menu, drawn like `RockyIconButtonStyle` (CUR-02) and lit while
/// its menu is open. `MenuButton` wraps its label in a plain button, so the style itself cannot be applied.
private struct MenuIconButtonLabel: View {
    let title: String
    let systemImage: String
    let isOpen: Bool
    var size: CGFloat = 28
    @State private var hovering = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .foregroundStyle(hovering || isOpen ? Theme.textPrimary : Theme.textSecondary)
            .frame(width: Zoom.shared(size), height: Zoom.shared(size))
            .background(isOpen ? Theme.fillPressed : hovering ? Theme.fillIconHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// The branch in the top bar (TB-02): its glyph and name; a click copies the name and the label reads "Copied" in
/// the accent for 1.2 seconds.
private struct BranchCopyButton: View {
    let branch: String
    @State private var copied = false
    @State private var endCopied: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.rocky(13))
                    .foregroundStyle(Theme.textTertiary)
                Text(copied ? "Copied" : branch)
                    .font(.rocky(12, design: .monospaced))
                    .foregroundStyle(copied ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(BranchCopyButtonStyle())
        .help("Copy the branch name")
        .accessibilityLabel("Branch \(branch)")
        .accessibilityHint("Copies the branch name")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(branch, forType: .string)
        copied = true
        endCopied?.cancel()
        endCopied = Task {
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// TB-02: 24 points high, padding 6, radius 5; no fill at rest, `fillIconHover` on hover, `fillPressed` pressed.
private struct BranchCopyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BranchCopyButtonBody(configuration: configuration)
    }

    private struct BranchCopyButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .frame(height: Zoom.shared(24))
                .background(
                    configuration.isPressed ? Theme.fillPressed : hovering ? Theme.fillIconHover : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
                .clickable()
        }
    }
}

/// The Open menu's header (TB-03): the worktree path, 11 mono in `textTertiary`, wrapping when long. The home folder
/// shows as "~".
private struct OpenMenuPathHeader: View {
    let path: String

    var body: some View {
        Text((path as NSString).abbreviatingWithTildeInPath)
            .fixedSize(horizontal: false, vertical: true)
            .font(.rocky(11, design: .monospaced))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
