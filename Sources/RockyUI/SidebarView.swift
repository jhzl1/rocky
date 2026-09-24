import AppKit
import RockyKit
import SwiftUI

extension EnvironmentValues {
    /// The sidebar list has keyboard focus (KBD-01: ↑ and ↓ are moving through its rows). A workspace that opens
    /// meanwhile should leave the focus there instead of taking it for its message box, or the next arrow would go
    /// to the message box.
    @Entry var sidebarHasKeyboardFocus: Bool = false
}

/// The sidebar under its top row: the search field (SB-02), the repositories and their workspaces (SB-03…SB-05,
/// ROW-*), and the footer (SB-06, SB-08). A custom list instead of `List(selection:)`, whose selection paints the
/// system accent (ROW-06); so the arrow keys, the selected trait and scrolling the selection into view are here.
struct SidebarView: View {
    let model: AppModel
    /// Mirrors the list's keyboard focus for `RootView`, which hands it to the workspace (`sidebarHasKeyboardFocus`).
    @Binding var hasKeyboardFocus: Bool
    /// Today's folder picker (`RootView.addRepository()`).
    let onAddRepository: () -> Void

    @State private var workspaceToRemove: Workspace?
    @State private var query = ""
    @FocusState private var focus: Focus?
    /// The list got its focus from the keyboard (Tab, the arrows, ↓ or Esc in the search field), not from a click:
    /// the focus ring and the row's actions show only then (KBD-01, ROW-05).
    @State private var keyboardNavigating = false
    /// ⌘ held for 400 ms: the rows show "⌘1"…"⌘9" (KBD-01).
    @State private var showsShortcutHints = false
    @State private var hintTask: Task<Void, Never>?
    @State private var flagsMonitor: Any?
    /// SB-04: the folded repositories' ids, comma-separated (`@AppStorage` cannot hold a set).
    @AppStorage("foldedRepoIds") private var foldedRepoIdsValue = ""
    @Environment(\.appearsActive) private var appearsActive

    private enum Focus: Hashable {
        case search, list
    }

    /// A repository in the list with the workspaces it shows.
    private struct RepoSection: Identifiable {
        let repo: Repo
        let workspaces: [Workspace]
        let isFolded: Bool
        var id: String { repo.id }
    }

    var body: some View {
        let sections = shownSections
        let order = Self.order(of: sections)
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 6)
            list(sections: sections, order: order)
            footer
        }
        .onChange(of: order, initial: true) { _, order in publish(order) }
        .onChange(of: listHasKeyboardFocus, initial: true) { _, focused in hasKeyboardFocus = focused }
        .onChange(of: focus) { _, newFocus in
            // Tab or a key handler moved the focus here; a click did not. The ring is for keyboard focus only.
            if newFocus == .list { keyboardNavigating = NSApp.currentEvent?.type == .keyDown }
        }
        .onChange(of: model.isSearchFocusRequested, initial: true) { _, requested in
            guard requested else { return }
            model.isSearchFocusRequested = false
            // On the next turn of the main actor, once the field is in the window: ⌘K with the sidebar hidden shows
            // it first (RootView).
            Task { focus = .search }
        }
        .onChange(of: appearsActive) { _, active in
            // The ⌘ key-up never arrives while another app is in front.
            if !active { hideShortcutHints() }
        }
        .onAppear {
            watchCommandKey()
            // AppKit makes the first text field of a new window its first responder: the search would open focused,
            // ringed, and take the keys meant for the message box. Only ⌘K or a click focuses it.
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                if focus == .search, !model.isSearchFocusRequested { focus = nil }
            }
        }
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
            hideShortcutHints()
            hasKeyboardFocus = false
            // The search goes away with the sidebar, so ⌘1…⌘9 keep the order without it.
            publish(Self.order(of: repoSections(matching: "")))
        }
        .confirmationDialog(
            "Remove \(workspaceToRemove?.name ?? "")?",
            isPresented: Binding(get: { workspaceToRemove != nil }, set: { if !$0 { workspaceToRemove = nil } }),
            presenting: workspaceToRemove
        ) { workspace in
            Button("Remove Worktree", role: .destructive) {
                Task { await model.removeWorkspace(id: workspace.id) }
            }
        } message: { workspace in
            Text("Stops its agent, terminals and scripts, runs the archive script, then deletes the folder \(workspace.path). The branch \(workspace.branch) is kept. Git refuses while there are uncommitted changes.")
        }
        .alert(
            "Archive script failed",
            isPresented: Binding(get: { model.archiveFailure != nil }, set: { if !$0 { model.archiveFailure = nil } }),
            presenting: model.archiveFailure
        ) { failure in
            Button("Remove Anyway", role: .destructive) {
                Task { await model.removeWorkspace(id: failure.workspaceId, skipArchive: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { failure in
            Text("\(failure.message) \(failure.workspaceName) was not removed; the Archive tab shows its output.")
        }
    }

    // MARK: Search (SB-02)

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.rocky(13))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            TextField("Search workspaces", text: $query, prompt: Text("Search").foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(.rocky(13))
                .foregroundStyle(Theme.textPrimary)
                .focused($focus, equals: .search)
                .onKeyPress(.downArrow) { focusFirstRow() }
                .onExitCommand(perform: clearSearch)
            if query.isEmpty {
                Text("⌘K")
                    .font(.rocky(11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.trailing, 2)
                    .accessibilityHidden(true)
            } else {
                Button {
                    query = ""
                    focus = .search
                } label: {
                    Label("Clear search", systemImage: "xmark")
                }
                .buttonStyle(RockyIconButtonStyle(size: 18))
                .font(.rocky(9, weight: .semibold))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: Zoom.shared(28))
        .background(Theme.fillControl, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 2)
                .opacity(focus == .search ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(Theme.Motion.hover, value: focus == .search)
    }

    /// ↓ in the search field selects the first row and moves the focus to the list.
    private func focusFirstRow() -> KeyPress.Result {
        guard let first = visibleOrder.first else { return .ignored }
        keyboardNavigating = true
        model.selectedWorkspaceId = first
        focus = .list
        return .handled
    }

    /// Esc clears the search and returns the focus to the list.
    private func clearSearch() {
        query = ""
        keyboardNavigating = true
        focus = .list
    }

    // MARK: List (SB-03…SB-05, ROW-06)

    private func list(sections: [RepoSection], order: [String]) -> some View {
        let hints = showsShortcutHints ? Self.shortcutHints(for: order) : [:]
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.repos.isEmpty {
                        emptyState
                    } else if sections.isEmpty {
                        noMatch
                    } else {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            header(for: section)
                                // SB-03: 10 above each header (2 of them the stack's spacing), 4 above the first.
                                .padding(.top, index == 0 ? 4 : 8)
                            if !section.isFolded {
                                ForEach(section.workspaces) { workspace in
                                    row(for: workspace, hint: hints[workspace.id])
                                        .id(workspace.id)
                                        .transition(.opacity)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .focusable()
            .focused($focus, equals: .list)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { moveSelection(by: -1) }
            .onKeyPress(.downArrow) { moveSelection(by: 1) }
            .onChange(of: model.selectedWorkspaceId) { _, id in
                guard let id, let workspace = model.workspace(id: id) else { return }
                // A workspace made in a folded repository ("+", ⌘N) unfolds it, as the mock does.
                if foldedRepoIds.contains(workspace.repoId) {
                    withAnimation(Theme.Motion.state) { setFolded(workspace.repoId, false) }
                }
                // On the next turn of the main actor, once the unfolded rows exist.
                Task {
                    withAnimation(Theme.Motion.state) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func header(for section: RepoSection) -> some View {
        let repo = section.repo
        let statuses = section.isFolded ? section.workspaces.map { model.status(workspaceId: $0.id) } : []
        return RepoHeader(
            repo: repo,
            workspaceCount: section.workspaces.count,
            isFolded: section.isFolded,
            foldedStatus: WorkspaceStatus.mostUrgent(statuses),
            onToggleFold: {
                withAnimation(Theme.Motion.state) { setFolded(repo.id, !foldedRepoIds.contains(repo.id)) }
            },
            onNewWorkspace: { Task { await model.createWorkspace(repoId: repo.id) } },
            // A panel over the window, like Settings (`RepoSettingsModal` in `RootView`).
            onSettings: { RepoSettingsPresenter.shared.show(repoId: repo.id) },
            onRemove: { Task { await model.removeRepo(id: repo.id) } }
        )
    }

    private func row(for workspace: Workspace, hint: String?) -> some View {
        let title = model.title(for: workspace)
        let isSelected = model.selectedWorkspaceId == workspace.id
        return SidebarRow(
            workspace: workspace,
            title: title.text,
            titleIsFallback: title.isFallback,
            status: model.status(workspaceId: workspace.id),
            isSelected: isSelected,
            hasKeyboardFocus: isSelected && listHasKeyboardFocus,
            shortcutHint: hint,
            onSelect: {
                keyboardNavigating = false
                model.selectedWorkspaceId = workspace.id
            },
            onRemove: { workspaceToRemove = workspace }
        )
    }

    /// SB-07: the detail area keeps its own empty state, with the Rocky logo.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No repositories yet")
                .font(.rocky(13))
                .foregroundStyle(Theme.textSecondary)
            Button(action: onAddRepository) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.rocky(15))
                        .accessibilityHidden(true)
                    Text("Add repository")
                        .font(.rocky(13))
                }
                .padding(.horizontal, 2)
            }
            .buttonStyle(RockyFilledButtonStyle(height: 28))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var noMatch: some View {
        Text("No workspaces match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
            .font(.rocky(12.5))
            .foregroundStyle(Theme.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }

    /// ↑ and ↓ with the list focused move the selection through the visible rows (KBD-01).
    private func moveSelection(by step: Int) -> KeyPress.Result {
        let order = visibleOrder
        guard !order.isEmpty else { return .ignored }
        keyboardNavigating = true
        let next: Int
        if let current = order.firstIndex(where: { $0 == model.selectedWorkspaceId }) {
            next = min(max(current + step, 0), order.count - 1)
        } else {
            next = step > 0 ? 0 : order.count - 1
        }
        model.selectedWorkspaceId = order[next]
        return .handled
    }

    private var listHasKeyboardFocus: Bool {
        focus == .list && keyboardNavigating
    }

    // MARK: Footer (SB-06, SB-08)

    private var footer: some View {
        HStack(spacing: 0) {
            Button(action: onAddRepository) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.rocky(15))
                        .accessibilityHidden(true)
                    Text("Add repository")
                        .font(.rocky(13))
                }
            }
            .buttonStyle(RockyTextButtonStyle())
            Spacer(minLength: 8)
            // The settings panel over the window, as Rocky ▸ Settings… and ⌘, open it (SB-08).
            Button {
                SettingsPresenter.shared.show()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(RockyIconButtonStyle())
            .font(.rocky(15))
            .help("Settings ⌘,")
        }
        .padding(.horizontal, 10)
        // The panel bar's height plus the 1 point of the line above it (`PanelDivider`), so this footer's line and the
        // panel's line are one line across the window, in the same color.
        .frame(height: Zoom.shared(WindowMetrics.bottomBarHeight) + 1)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    // MARK: Order, folding and filtering

    private var shownSections: [RepoSection] {
        repoSections(matching: query)
    }

    /// Repositories in `model.repos` order and workspaces in `model.workspaces` order (SB-05). While searching,
    /// repositories without a match hide and folded ones show their matches (SB-02).
    private func repoSections(matching query: String) -> [RepoSection] {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let folded = foldedRepoIds
        return model.repos.compactMap { repo in
            let all = model.workspaces[repo.id] ?? []
            let shown = searching ? all.filter { matches($0, in: repo, query: query) } : all
            if searching && shown.isEmpty { return nil }
            return RepoSection(repo: repo, workspaces: shown, isFolded: !searching && folded.contains(repo.id))
        }
    }

    private func matches(_ workspace: Workspace, in repo: Repo, query: String) -> Bool {
        WorkspaceFilter.matches(
            query: query,
            title: model.title(for: workspace).text,
            branch: workspace.branch,
            name: workspace.name,
            repo: repo.name
        )
    }

    private var visibleOrder: [String] {
        Self.order(of: shownSections)
    }

    private static func order(of sections: [RepoSection]) -> [String] {
        sections.filter { !$0.isFolded }.flatMap { $0.workspaces.map(\.id) }
    }

    private static func shortcutHints(for order: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: order.prefix(9).enumerated().map { ($0.element, "⌘\($0.offset + 1)") })
    }

    /// ⌘1…⌘9 select from this order (`AppModel.selectVisibleWorkspace`).
    private func publish(_ order: [String]) {
        if model.visibleWorkspaceIds != order { model.visibleWorkspaceIds = order }
    }

    private var foldedRepoIds: Set<String> {
        Set(foldedRepoIdsValue.split(separator: ",").map(String.init))
    }

    private func setFolded(_ repoId: String, _ isFolded: Bool) {
        var ids = foldedRepoIds
        if isFolded { ids.insert(repoId) } else { ids.remove(repoId) }
        foldedRepoIdsValue = ids.sorted().joined(separator: ",")
    }

    // MARK: ⌘ hints (KBD-01)

    /// A local monitor for the modifier keys while the sidebar is on screen; holding ⌘ alone for 400 ms shows the
    /// hints, and any other change hides them. One sleep per press, no timer.
    private func watchCommandKey() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { commandKeyChanged(flags) }
            return event
        }
    }

    private func commandKeyChanged(_ flags: NSEvent.ModifierFlags) {
        hideShortcutHints()
        guard flags.intersection([.command, .shift, .option, .control]) == .command else { return }
        hintTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            showsShortcutHints = true
        }
    }

    private func hideShortcutHints() {
        hintTask?.cancel()
        hintTask = nil
        showsShortcutHints = false
    }
}

/// The line between the sidebar and the workspace: a light hairline (the system split view draws a black one),
/// with a wider invisible handle to drag the sidebar's width.
struct SidebarDivider: View {
    @Binding var width: Double
    @State private var widthAtDragStart: Double?
    static let widthRange: ClosedRange<Double> = 200...420

    var body: some View {
        // The hairline is translucent: on the window's own background it came out lighter and warmer than every
        // other line (rgb 70,67,64 against 51,53,58), so it sits on the sidebar's color like the others do.
        Rectangle()
            .fill(Theme.hairline)
            .background(Color.rockySidebar)
            .frame(width: 1)
            .ignoresSafeArea()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = widthAtDragStart ?? width
                                widthAtDragStart = start
                                width = min(max(start + drag.translation.width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
            }
    }
}
