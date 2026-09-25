import AppKit
import RockyKit
import SwiftUI

/// Opens and closes Quick Open (FIL-08) and holds what its panel shows: the query, the last ranking and the selected
/// row. File ▸ Go to File… (⌘P) calls `toggle(for:model:)`. While it shows, a local key monitor takes ↑ / ↓ (moving
/// and wrapping), Return (open to keep), ⌥Return (open as a preview) and Esc (close) before the field and before
/// `ChatView`'s monitor, which lets every key through meanwhile; an open Rocky menu keeps its own keys. Kept here, a
/// reference, so the monitor reads the state at the key's time (`CLAUDE.md`).
@MainActor
@Observable
public final class QuickOpenPresenter {
    public static let shared = QuickOpenPresenter()

    /// The workspace Quick Open shows, nil while it is closed. The panel's entrance is keyed on it (`QuickOpenHost`),
    /// so it runs once per opening and never while typing.
    public private(set) var workspaceId: String?
    /// The search field's text.
    var query = ""
    /// The last ranking and the query it ranks: a newer query's ranking may still run (`QuickOpenPanel`).
    private(set) var results = QuickOpenResults()
    /// An index of `results.paths`: the first row after each new query.
    private(set) var selection = 0
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private weak var window: NSWindow?
    /// What had the keyboard before Quick Open, given it back when it closes without opening a file. A field editor is
    /// not kept: its text field is SwiftUI's, whose focus state would not follow.
    @ObservationIgnored private weak var previousResponder: NSView?
    @ObservationIgnored private var keyMonitor: Any?

    public var isShown: Bool { workspaceId != nil }

    /// ⌘P: Quick Open for the selected workspace, or, while it shows, closed.
    public func toggle(for workspaceId: String, model: AppModel) {
        if isShown {
            dismiss()
        } else {
            show(workspaceId, model: model)
        }
    }

    /// Esc, a click outside, ⌘P again, another workspace or a settings panel: the keyboard goes back where it was.
    public func dismiss() {
        close(restoringFocus: true)
    }

    private func show(_ workspaceId: String, model: AppModel) {
        self.model = model
        query = ""
        results = QuickOpenResults()
        selection = 0
        window = NSApp.keyWindow ?? NSApp.mainWindow
        if let responder = window?.firstResponder as? NSView, (responder as? NSTextView)?.isFieldEditor != true {
            previousResponder = responder
        }
        self.workspaceId = workspaceId
        model.quickOpenWillShow(workspaceId: workspaceId)
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    private func close(restoringFocus: Bool) {
        guard isShown else { return }
        workspaceId = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model?.quickOpenDidHide()
        query = ""
        results = QuickOpenResults()
        selection = 0
        if restoringFocus, let window, let responder = previousResponder {
            // On the next turn, once SwiftUI has removed the field, whose field editor hands the keyboard to the window.
            Task { @MainActor in
                guard responder.window === window else { return }
                window.makeFirstResponder(responder)
            }
        }
        previousResponder = nil
    }

    /// The keys Quick Open takes, in its window: whether the event was used. A composition in progress (an input
    /// method's marked text) keeps Return and Esc.
    private func handle(_ event: NSEvent) -> Bool {
        guard isShown, event.window === window, !MenuPresenter.isAnyMenuOpen else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isComposing = (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
        switch event.keyCode {
        case 53:   // Esc
            guard modifiers.isEmpty, !isComposing else { return false }
            dismiss()
            return true
        case 125, 126:   // ↓, ↑
            guard modifiers.isEmpty else { return false }
            moveSelection(event.keyCode == 125 ? 1 : -1)
            return true
        case 36, 76:   // Return, and Enter on the keypad
            guard modifiers.isEmpty || modifiers == .option, !isComposing else { return false }
            openSelection(asPreview: modifiers == .option)
            return true
        default:
            return false
        }
    }

    /// ↓ and ↑, wrapping at both ends.
    private func moveSelection(_ step: Int) {
        let count = results.paths.count
        guard count > 0 else { return }
        selection = ((selection + step) % count + count) % count
    }

    /// The row under the pointer (hover selects).
    func select(_ index: Int) {
        guard results.paths.indices.contains(index), index != selection else { return }
        selection = index
    }

    /// A ranking came back. A new query selects the first row; a new list for the same query (the list was read
    /// while Quick Open showed) keeps the selected file when it is still there.
    func showResults(_ paths: [String], for query: String) {
        let isNewQuery = !results.isRanked || results.query != query
        let selected = results.paths.indices.contains(selection) ? results.paths[selection] : nil
        results = QuickOpenResults(query: query, paths: paths, isRanked: true)
        selection = isNewQuery ? 0 : selected.flatMap { paths.firstIndex(of: $0) } ?? 0
    }

    /// Return, ⌥Return and the footer's buttons: the selected row.
    func openSelection(asPreview: Bool) {
        open(at: selection, asPreview: asPreview)
    }

    /// FIL-05 through `AppModel.openFromTree`: to keep, or as the preview tab. Quick Open closes first, leaving the
    /// keyboard to the tab.
    func open(at index: Int, asPreview: Bool) {
        guard let workspaceId, let model, results.paths.indices.contains(index) else { return }
        let path = results.paths[index]
        close(restoringFocus: false)
        model.openFromTree(workspaceId: workspaceId, path: path, keep: !asPreview)
    }
}

/// A ranking of Quick Open's list (`QuickOpen.results`) and the query it is for.
struct QuickOpenResults: Equatable {
    var query = ""
    var paths: [String] = []
    /// Whether a ranking has come back since Quick Open opened: before one, git's list is still being read.
    var isRanked = false
}

/// Quick Open over the whole window (FIL-08), from `RootView`, under the menus: a transparent layer that closes it on
/// a click outside (no dimming), and the panel, centered, 12 points under the title bar row. The 120 ms entrance (a
/// fade and a 4-point drop, a fade alone with Reduce Motion) is the transition of the `if` that shows the panel, keyed
/// on the presenter's workspace: typing, the arrows and hover change only the list and the selection, with no
/// animation, and the panel and its field keep their identity, so the field keeps the keyboard (user report,
/// 2026-09-24: in the mock every keystroke hid and reopened the panel). It closes at once.
struct QuickOpenHost: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presenter: QuickOpenPresenter { .shared }

    var body: some View {
        ZStack(alignment: .top) {
            if let workspaceId = presenter.workspaceId {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { presenter.dismiss() }
                QuickOpenPanel(model: model, workspaceId: workspaceId)
                    .padding(.top, WindowMetrics.titleRowHeight + 12)
                    .transition(.asymmetric(
                        insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)),
                        removal: .identity
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // With Quick Open closed, clicks reach the window under it.
        .allowsHitTesting(presenter.isShown)
        .animation(Theme.Motion.hover, value: presenter.workspaceId)
        // Closing the window (⌘W) closes Quick Open, whose key monitor listens to that window alone.
        .onDisappear { presenter.dismiss() }
    }
}

/// FIL-08's panel, 440 points wide in the menus' style (`MenuPanel`: `panel`, radius 12, a `hairline` ring, their
/// shadow): the 40-point search field over a hairline, the list, and the 32-point footer. The ranking runs off the
/// main actor, as in `FilesTab`, and the next keystroke cancels it; git's list is read by the model, never per
/// keystroke (`AppModel.quickOpenWillShow`).
struct QuickOpenPanel: View {
    let model: AppModel
    let workspaceId: String
    @FocusState private var fieldHasKeyboard: Bool

    private var presenter: QuickOpenPresenter { .shared }

    /// A new ranking for a new query, list, recent files or changes; the latest wins (`.task(id:)` cancels the one
    /// before).
    private struct RankRequest: Equatable {
        let query: String
        let list: FileList?
        let recent: [String]
        let changed: [String]
    }

    var body: some View {
        let state = model.fileTrees[workspaceId]
        let changes = model.changes[workspaceId]
        let recent = model.recentFiles[workspaceId] ?? []
        // FIL-08's empty query lists the changed files after the recent ones; a deleted file is not in the list.
        let changed = changes?.files.filter { $0.status != .deleted }.map(\.path) ?? []
        let request = RankRequest(query: presenter.query, list: state?.list, recent: recent, changed: changed)
        VStack(spacing: 0) {
            searchField
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content(state: state, marks: FileMarks(changes: changes), recent: Set(recent))
            footer
        }
        .frame(width: Zoom.shared(440))
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
        .task(id: request) { await rank(request) }
        .onAppear {
            // On the next turn, once the field is in the window.
            Task { @MainActor in fieldHasKeyboard = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Open")
        .accessibilityAddTraits(.isModal)
    }

    /// 40 points: the magnifying glass and the field, 14 points, with a placeholder that does not move on focus.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.rocky(13))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            TextField("Search project files", text: Bindable(presenter).query, prompt: Text(verbatim: ""))
                .textFieldStyle(.plain)
                .font(.rocky(14))
                .stablePlaceholder("Search project files…", isVisible: presenter.query.isEmpty)
                .foregroundStyle(Theme.textPrimary)
                .focused($fieldHasKeyboard)
        }
        .padding(.horizontal, 12)
        .frame(height: Zoom.shared(40))
    }

    /// The rows, or in their place: git's list on its way ("Reading files…"), its failure, or no match.
    @ViewBuilder
    private func content(state: FileTreeState?, marks: FileMarks, recent: Set<String>) -> some View {
        let results = presenter.results
        if results.isRanked, !results.paths.isEmpty {
            QuickOpenList(results: results, selection: presenter.selection, marks: marks, recent: recent)
        } else if let failure = state?.listFailure, state?.list == nil {
            Text(verbatim: failure)
                .font(.rocky(12))
                .foregroundStyle(Theme.danger)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(20)
                .frame(maxWidth: .infinity)
        } else if !results.isRanked {
            ProgressLabel(text: "Reading files…")
                .font(.rocky(12.5))
                .padding(20)
                .frame(maxWidth: .infinity)
        } else {
            Text(verbatim: presenter.query.isEmpty ? "No files" : "No file matches “\(presenter.query)”")
                .font(.rocky(12.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(20)
                .frame(maxWidth: .infinity)
        }
    }

    /// 32 points under a hairline: "Open ↩" and "Open as preview ⌥↩", acting on the selected row, off with no rows.
    private var footer: some View {
        let hasRows = !presenter.results.paths.isEmpty
        return HStack(spacing: 0) {
            Button { presenter.openSelection(asPreview: false) } label: {
                FooterLabel(title: "Open", keys: "↩")
            }
            Spacer(minLength: 8)
            Button { presenter.openSelection(asPreview: true) } label: {
                FooterLabel(title: "Open as preview", keys: "⌥↩")
            }
        }
        .buttonStyle(RockyTextButtonStyle(height: 22))
        .font(.rocky(11.5))
        .disabled(!hasRows)
        .padding(.horizontal, 4)
        .frame(height: Zoom.shared(32))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// FIL-04's ranking with FIL-08's order, off the main actor: 100,000 paths take a few milliseconds, which the main
    /// actor does not wait for. A cancelled ranking's result is dropped.
    private func rank(_ request: RankRequest) async {
        guard let list = request.list else { return }
        let paths = await Task.detached(priority: .userInitiated) {
            QuickOpen.results(query: request.query, list: list, recent: request.recent, changed: request.changed)
        }.value
        guard !Task.isCancelled else { return }
        presenter.showResults(paths, for: request.query)
    }
}

/// A footer button's label: its title, then its keys in 11-point mono `textTertiary`.
private struct FooterLabel: View {
    let title: String
    let keys: String

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
            Text(verbatim: keys)
                .font(.rocky(11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
    }
}

/// Quick Open's rows: 28 points each in a 4-point inset, 11 visible, then the list scrolls, keeping the selected row
/// in view. Lazy, of fixed-height rows, so a list of 100,000 files builds only the rows on screen. Hover selects, but
/// rows sliding under a pointer that did not move (the list scrolled to the selection, or opened under it) do not
/// take the selection, as in the slash command popup.
private struct QuickOpenList: View {
    let results: QuickOpenResults
    let selection: Int
    let marks: FileMarks
    let recent: Set<String>
    /// Where the pointer last was.
    @State private var pointer: CGPoint?

    private static let visibleRows = 11
    private static let inset: CGFloat = 4

    private var presenter: QuickOpenPresenter { .shared }

    var body: some View {
        let rowHeight = Zoom.shared(28)
        let paths = results.paths
        let height = CGFloat(min(paths.count, Self.visibleRows)) * rowHeight + Self.inset * 2
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(paths.indices, id: \.self) { index in
                        QuickOpenRow(
                            path: paths[index],
                            query: results.query,
                            status: marks.statuses[paths[index]],
                            isRecent: recent.contains(paths[index]),
                            isSelected: index == selection,
                            height: rowHeight
                        )
                        .id(index)
                        .onContinuousHover(coordinateSpace: .global) { hover($0, index: index) }
                        // A click opens to keep, ⌥-click as the preview (FIL-05).
                        .onTapGesture { presenter.open(at: index, asPreview: NSEvent.modifierFlags.contains(.option)) }
                    }
                }
                .padding(Self.inset)
            }
            .scrollIndicators(paths.count > Self.visibleRows ? .automatic : .never)
            .defaultScrollAnchor(.top)
            .frame(height: height)
            .onChange(of: selection) { proxy.scrollTo(selection) }
            .onChange(of: results.query) { proxy.scrollTo(selection) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files")
    }

    private func hover(_ phase: HoverPhase, index: Int) {
        guard case .active(let location) = phase else { return }
        defer { pointer = location }
        guard let pointer, pointer != location else { return }
        presenter.select(index)
    }
}

/// One file (FIL-08): its Material icon (FIL-09, 14 points), the name 13 semibold, its folder 12 `textTertiary` cut
/// from the head, the matched characters of both in `accent` (`FileTree.matches`, drawn as the All files filter draws
/// them), and at the right end its Changes status letter and a `clock` on a recently opened file. Selected:
/// `fillSelected`.
private struct QuickOpenRow: View {
    let path: String
    let query: String
    let status: FileDiff.Status?
    let isRecent: Bool
    let isSelected: Bool
    let height: CGFloat

    var body: some View {
        let slash = path.lastIndex(of: "/")
        let nameStart = slash.map { path.index(after: $0) } ?? path.startIndex
        let matches = FileTree.matches(query, in: path)
        HStack(spacing: 8) {
            FileTreeIcon(path: path, isDirectory: false)
            Text(FileMatchRow.highlighted(path, nameStart..<path.endIndex, matches: matches))
                .font(.rocky(13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(FileMatchRow.highlighted(path, path.startIndex..<(slash ?? path.startIndex), matches: matches))
                .font(.rocky(12))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            if status != nil || isRecent {
                HStack(spacing: 6) {
                    if let status { ChangeStatusLetter(status: status) }
                    if isRecent {
                        Image(systemName: "clock")
                            .font(.rocky(11))
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(isSelected ? Theme.fillSelected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .clickable()
        .help(path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(folderEnd: slash))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// FIL-08: "openapi.ts, src, modified, recent".
    private func accessibilityLabel(folderEnd: String.Index?) -> String {
        var parts = [String(path[(folderEnd.map { path.index(after: $0) } ?? path.startIndex)...])]
        if let folderEnd { parts.append(String(path[..<folderEnd])) }
        if let status { parts.append(status.accessibilityName) }
        if isRecent { parts.append("recent") }
        return parts.joined(separator: ", ")
    }
}
