import AppKit
import RockyKit
import SwiftUI

/// Whether the All files filter has the keyboard. `ChatView`'s key monitor reads it at the key's time, since a monitor
/// keeps the view as it was when it was added (`CLAUDE.md`), and then leaves Esc to the filter instead of stopping the
/// agent's turn (FIL-04).
@MainActor
enum FileFilterFocus {
    /// The tab's own focus state, which it sets.
    static var isFocused = false

    /// The filter's focus, and the window typing through a field editor, as a text field does: the message box and the
    /// code editor are text views of their own, so a focus state left behind never keeps Esc from the agent.
    static func hasKeyboard(in window: NSWindow) -> Bool {
        isFocused && (window.firstResponder as? NSTextView)?.isFieldEditor == true
    }
}

/// The All files tab of the right panel (FIL-01): a 38-point head with the filter and "⋯", then the worktree's tree
/// (FIL-02, FIL-03) or, while the filter has text, its ranked matches (FIL-04). Both are lazy stacks of fixed 26-point
/// rows in their own scroll view, under M2.7's footer. The model reads git's list and the expanded folders only while
/// this tab shows (FIL-07); the tree hides behind the matches rather than going away, so an empty filter brings it
/// back as it was, scroll position included.
struct FilesTab: View {
    let model: AppModel
    let workspace: Workspace
    @State private var query = ""
    /// The matches of the last ranking and the query they are for (`FileTree.rank`, off the main actor).
    @State private var ranked = RankedFiles()
    /// The keyboard's row in the tree, and in the matches.
    @State private var treeCursor: String?
    @State private var resultCursor = 0
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case filter, tree
    }

    private struct RankedFiles {
        var query = ""
        var paths: [String] = []
    }

    /// A new ranking for a new query or a new list; the latest wins (`.task(id:)` cancels the one before).
    private struct RankRequest: Equatable {
        let query: String
        let list: FileList?
    }

    /// FIL-05's Reveal: the row to scroll to, and whether the tree draws it yet (its folders' listings may still be
    /// on their way).
    private struct RevealKey: Equatable {
        let path: String?
        let isDrawn: Bool
    }

    var body: some View {
        let state = model.fileTrees[workspace.id]
        let showsIgnored = model.showsIgnoredFiles(workspaceId: workspace.id)
        let rows = state.flatMap { state in
            state.list.map { FileTree.rows(listings: state.listings, expanded: state.expanded, list: $0, showsIgnored: showsIgnored) }
        } ?? []
        let marks = FileMarks(changes: model.changes[workspace.id])
        VStack(spacing: 0) {
            head(showsIgnored: showsIgnored)
            ZStack(alignment: .top) {
                tree(state: state, rows: rows, marks: marks)
                    .opacity(query.isEmpty ? 1 : 0)
                    .allowsHitTesting(query.isEmpty)
                    .accessibilityHidden(!query.isEmpty)
                if !query.isEmpty {
                    results(marks: marks)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .task(id: RankRequest(query: query, list: state?.list)) {
            await rank(query, in: state?.list)
        }
        .onChange(of: focus == .filter, initial: true) { _, isFocused in FileFilterFocus.isFocused = isFocused }
        .onDisappear { FileFilterFocus.isFocused = false }
    }

    // MARK: Head (FIL-01, FIL-04)

    /// 38 points: the filter field, then "⋯" (Show Ignored Files, Collapse All Folders, Reveal Active File; no icons).
    private func head(showsIgnored: Bool) -> some View {
        let active = model.selectedDiffTabs[workspace.id]
        return HStack(spacing: 6) {
            filterField
            MenuButton(id: "files-more-\(workspace.id)", placement: .belowTrailing, width: 220) { isOpen in
                SidebarMenuIcon(systemImage: "ellipsis", label: "More", isOpen: isOpen)
            } content: {
                MenuItem(title: "Show Ignored Files", isChecked: showsIgnored) {
                    model.setShowsIgnoredFiles(!showsIgnored, repoId: workspace.repoId)
                }
                MenuItem(title: "Collapse All Folders") { model.collapseAllFolders(workspaceId: workspace.id) }
                MenuItem(title: "Reveal Active File", disabledReason: active == nil ? "No worktree file is showing" : nil) {
                    guard let active else { return }
                    query = ""
                    model.reveal(workspaceId: workspace.id, path: active)
                }
            }
            .font(.rocky(12))
            .help("More")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: Zoom.shared(38))
    }

    /// FIL-01's field: 26 points, radius 6, `fillControl`, "Filter files", no shortcut hint (⌘P is Quick Open, FIL-08);
    /// an `accent` border while it has the keyboard. ↓ / ↑ move through the matches, Return opens one as a preview, Esc
    /// clears the query and a second Esc leaves the field (FIL-04).
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.rocky(11.5))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            TextField("Filter files", text: $query, prompt: Text(verbatim: ""))
                .textFieldStyle(.plain)
                .font(.rocky(12.5))
                .stablePlaceholder("Filter files", isVisible: query.isEmpty)
                .foregroundStyle(Theme.textPrimary)
                .focused($focus, equals: .filter)
                .onKeyPress(.downArrow) { moveResult(by: 1) }
                .onKeyPress(.upArrow) { moveResult(by: -1) }
                .onSubmit(openResult)
                .onExitCommand(perform: escape)
        }
        .padding(.horizontal, 8)
        .frame(height: Zoom.shared(26))
        .background(Theme.fillControl, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1)
                .opacity(focus == .filter ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(Theme.Motion.hover, value: focus == .filter)
    }

    private func escape() {
        if query.isEmpty {
            focus = nil
        } else {
            query = ""
        }
    }

    /// ↓ / ↑ in the field: through the matches; with no query, ↓ gives the keyboard to the tree, as in the mock.
    private func moveResult(by step: Int) -> KeyPress.Result {
        guard !query.isEmpty else {
            guard step > 0 else { return .ignored }
            focus = .tree
            return .handled
        }
        guard !ranked.paths.isEmpty else { return .handled }
        resultCursor = min(max(resultCursor + step, 0), ranked.paths.count - 1)
        return .handled
    }

    /// Return in the field: the match under the cursor opens as the preview (FIL-05).
    private func openResult() {
        guard !query.isEmpty, ranked.paths.indices.contains(resultCursor) else { return }
        model.openFromTree(workspaceId: workspace.id, path: ranked.paths[resultCursor], keep: false)
    }

    /// FIL-04: the ranking runs off the main actor, as the list may hold 100,000 paths; a newer query or list cancels
    /// this one, whose result is then dropped.
    private func rank(_ query: String, in list: FileList?) async {
        guard !query.isEmpty, let list else {
            ranked = RankedFiles()
            resultCursor = 0
            return
        }
        let paths = await Task.detached(priority: .userInitiated) { FileTree.rank(query, in: list) }.value
        guard !Task.isCancelled else { return }
        // A new list for the same query (an event) keeps the cursor where it was, within the matches.
        if ranked.query != query { resultCursor = 0 }
        ranked = RankedFiles(query: query, paths: paths)
        resultCursor = min(resultCursor, max(paths.count - 1, 0))
    }

    // MARK: Tree (FIL-02, FIL-03, KBD-02)

    private func tree(state: FileTreeState?, rows: [FileTreeRow], marks: FileMarks) -> some View {
        let selected = model.selectedDiffTabs[workspace.id]
        let revealed = model.revealedPaths[workspace.id]
        let revealKey = RevealKey(path: revealed, isDrawn: revealed.map { path in rows.contains { $0.path == path } } ?? false)
        return ScrollViewReader { proxy in
            ScrollView {
                if let failure = state?.listFailure, state?.list == nil {
                    FilesMessage(text: failure, isError: true)
                } else if state?.list == nil || state?.listings[""] == nil {
                    ProgressLabel(text: "Reading the files…")
                        .font(.rocky(12.5))
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            FileTreeRowView(
                                row: row,
                                status: marks.statuses[row.path],
                                changedCount: row.isDirectory ? marks.folders[row.path] ?? 0 : 0,
                                isSelected: row.path == selected,
                                isCursor: focus == .tree && row.path == treeCursor
                            ) { count in click(row, count: count) }
                            .id(row.path)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }
            }
            .focusable()
            .focused($focus, equals: .tree)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { moveCursor(by: -1, rows: rows, proxy: proxy) }
            .onKeyPress(.downArrow) { moveCursor(by: 1, rows: rows, proxy: proxy) }
            .onKeyPress(.rightArrow) { expandCursor(rows: rows, proxy: proxy) }
            .onKeyPress(.leftArrow) { collapseCursor(rows: rows, proxy: proxy) }
            .onKeyPress(.return) { openCursor(rows: rows) }
            .onChange(of: focus == .tree) { _, hasKeyboard in
                // The keyboard starts on the file on screen, else on the first row.
                guard hasKeyboard, treeCursor.map({ path in !rows.contains { $0.path == path } }) ?? true else { return }
                treeCursor = rows.first { $0.path == selected }?.path ?? rows.first?.path
            }
            .onChange(of: revealKey, initial: true) { _, key in
                guard let path = key.path else { return }
                query = ""
                guard key.isDrawn else { return }
                treeCursor = path
                // On the next turn, once the rows the expansion added are laid out.
                Task { @MainActor in
                    proxy.scrollTo(path, anchor: .center)
                    model.revealHandled(workspaceId: workspace.id)
                }
            }
        }
    }

    /// A row's click, by its click count (`NSEvent.clickCount`), one handler per row: a count-2 gesture beside a count-1
    /// one would hold every single click for the double-click interval (FIL-05). A folder opens or closes on its first
    /// click only, so a double-click leaves it open. A file opens as the preview, and the second click of a
    /// double-click keeps it.
    private func click(_ row: FileTreeRow, count: Int) {
        treeCursor = row.path
        focus = .tree
        if row.isDirectory {
            guard count == 1 else { return }
            model.setFolder(row.path, expanded: !row.isExpanded, workspaceId: workspace.id)
        } else {
            model.openFromTree(workspaceId: workspace.id, path: row.path, keep: count >= 2)
        }
    }

    private func cursorRow(_ rows: [FileTreeRow]) -> FileTreeRow? {
        treeCursor.flatMap { path in rows.first { $0.path == path } }
    }

    /// ↑ / ↓: the previous or next row; from none, the first or last.
    private func moveCursor(by step: Int, rows: [FileTreeRow], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let current = treeCursor.flatMap { path in rows.firstIndex { $0.path == path } }
        let next = current.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        treeCursor = rows[next].path
        proxy.scrollTo(rows[next].path)
        return .handled
    }

    /// →: a closed folder opens; an open one gives the cursor to its first child.
    private func expandCursor(rows: [FileTreeRow], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let row = cursorRow(rows) else { return .ignored }
        guard row.isDirectory else { return .handled }
        if !row.isExpanded {
            model.setFolder(row.path, expanded: true, workspaceId: workspace.id)
        } else if let index = rows.firstIndex(of: row), index + 1 < rows.count, rows[index + 1].depth > row.depth {
            treeCursor = rows[index + 1].path
            proxy.scrollTo(rows[index + 1].path)
        }
        return .handled
    }

    /// ←: an open folder closes; anything else gives the cursor to its folder.
    private func collapseCursor(rows: [FileTreeRow], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let row = cursorRow(rows) else { return .ignored }
        if row.isDirectory, row.isExpanded {
            model.setFolder(row.path, expanded: false, workspaceId: workspace.id)
        } else if let parent = FileTree.ancestors(of: row.path).last {
            treeCursor = parent
            proxy.scrollTo(parent)
        }
        return .handled
    }

    /// Return: a file opens as the preview (FIL-05); a folder opens or closes.
    private func openCursor(rows: [FileTreeRow]) -> KeyPress.Result {
        guard let row = cursorRow(rows) else { return .ignored }
        if row.isDirectory {
            model.setFolder(row.path, expanded: !row.isExpanded, workspaceId: workspace.id)
        } else {
            model.openFromTree(workspaceId: workspace.id, path: row.path, keep: false)
        }
        return .handled
    }

    // MARK: Matches (FIL-04)

    /// The flat list of matches: icon, name, folder (11 `textTertiary`), status letter, the matched characters in
    /// `accent`; the cursor's row ringed. "No file matches “query”" once the ranking found none.
    private func results(marks: FileMarks) -> some View {
        let ranked = self.ranked
        let isCurrent = ranked.query == query
        return ScrollViewReader { proxy in
            ScrollView {
                if isCurrent, ranked.paths.isEmpty {
                    FilesMessage(text: "No file matches “\(query)”")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(ranked.paths.indices, id: \.self) { index in
                            let path = ranked.paths[index]
                            FileMatchRow(
                                path: path,
                                query: ranked.query,
                                status: marks.statuses[path],
                                isCursor: index == resultCursor
                            ) { count in
                                resultCursor = index
                                model.openFromTree(workspaceId: workspace.id, path: path, keep: count >= 2)
                            }
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: resultCursor) { _, cursor in proxy.scrollTo(cursor) }
        }
    }
}

/// FIL-02's marks from Changes: each changed file's status letter, and for each folder the number of changed files
/// it holds (its dot, and "2 changed files" for VoiceOver). A deleted file is not in the tree, so it marks nothing.
/// Quick Open's rows take their letters from it too (FIL-08).
struct FileMarks {
    var statuses: [String: FileDiff.Status] = [:]
    var folders: [String: Int] = [:]

    init(changes: WorkspaceChanges?) {
        for file in changes?.files ?? [] where file.status != .deleted {
            statuses[file.path] = file.status
            for folder in FileTree.ancestors(of: file.path) {
                folders[folder, default: 0] += 1
            }
        }
    }
}

/// FIL-02's row: 26 points, radius 6, indented 12 points per level from an 8-point inset. A folder's 12-point chevron
/// turns 90° in `Theme.Motion.hover` (at once with Reduce Motion); then the 14-point icon (`FileTreeIcon`: the blue
/// folder, or the file's Material icon, FIL-09), the name (13, cut at its end), and at the right end the file's status
/// letter or, for a folder holding changed files, a 5-point `textSecondary` dot. Hover `fillHover`; the file whose tab shows `fillSelected`; the keyboard's row ringed in
/// `accent`. An ignored entry is dimmed: its name in `textTertiary`, its icon at 50 % (FIL-03).
private struct FileTreeRowView: View {
    let row: FileTreeRow
    let status: FileDiff.Status?
    let changedCount: Int
    let isSelected: Bool
    let isCursor: Bool
    let click: (Int) -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Files line up with their folder's icon, past the chevron's 12 points and the 6 after it.
    private var indent: CGFloat {
        CGFloat(8 + row.depth * 12 + (row.isDirectory ? 0 : 18))
    }

    var body: some View {
        HStack(spacing: 6) {
            if row.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.rocky(9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .animation(reduceMotion ? nil : Theme.Motion.hover, value: row.isExpanded)
                    .frame(width: Zoom.shared(12))
            }
            FileTreeIcon(path: row.path, isDirectory: row.isDirectory)
                .opacity(row.isIgnored ? 0.5 : 1)
            Text(verbatim: row.name)
                .font(.rocky(13))
                .foregroundStyle(row.isIgnored ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let status {
                ChangeStatusLetter(status: status)
            } else if changedCount > 0 {
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: Zoom.shared(5), height: Zoom.shared(5))
                    .help("Holds changed files")
            }
        }
        .padding(.leading, Zoom.shared(indent))
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Zoom.shared(26))
        .background(
            isSelected ? Theme.fillSelected : hovering ? Theme.fillHover : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            if isCursor {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { click(NSApp.currentEvent?.clickCount ?? 1) }
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .clickable()
        .help(row.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { click(1) }
    }

    /// FIL-02's outline labels: "src, folder, expanded, 2 changed files"; "openapi.ts, modified".
    private var accessibilityLabel: String {
        var parts = [row.name]
        if row.isDirectory {
            parts.append("folder")
            parts.append(row.isExpanded ? "expanded" : "collapsed")
            if changedCount > 0 { parts.append(changedCount == 1 ? "1 changed file" : "\(changedCount) changed files") }
        } else if let status {
            parts.append(status.accessibilityName)
        }
        if row.isIgnored { parts.append("ignored") }
        return parts.joined(separator: ", ")
    }
}

/// FIL-04's match row: the icon, the name and the folder with the matched characters in `accent`, and the status
/// letter; the cursor's row ringed in `accent`. A click opens the preview, a double-click keeps it (FIL-05).
struct FileMatchRow: View {
    let path: String
    let query: String
    let status: FileDiff.Status?
    let isCursor: Bool
    let click: (Int) -> Void
    @State private var hovering = false

    var body: some View {
        let nameStart = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        let matches = FileTree.matches(query, in: path)
        HStack(spacing: 6) {
            FileTreeIcon(path: path, isDirectory: false)
            Text(Self.highlighted(path, nameStart..<path.endIndex, matches: matches))
                .font(.rocky(13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(Self.highlighted(path, path.startIndex..<nameStart, matches: matches))
                .font(.rocky(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let status {
                ChangeStatusLetter(status: status)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Zoom.shared(26))
        .background(hovering ? Theme.fillHover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isCursor {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { click(NSApp.currentEvent?.clickCount ?? 1) }
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .clickable()
        .help(path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.map { "\(path), \($0.accessibilityName)" } ?? path)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { click(1) }
    }

    /// `path[range]`, its characters inside `matches` in `accent`. Quick Open's rows draw theirs with it (FIL-08).
    static func highlighted(_ path: String, _ range: Range<String.Index>, matches: [Range<String.Index>]) -> AttributedString {
        var text = AttributedString()
        var position = range.lowerBound
        for match in matches {
            let lower = max(match.lowerBound, range.lowerBound)
            let upper = min(match.upperBound, range.upperBound)
            guard lower < upper, lower >= position else { continue }
            if position < lower { text += AttributedString(String(path[position..<lower])) }
            var hit = AttributedString(String(path[lower..<upper]))
            hit.swiftUI.foregroundColor = Theme.accent
            text += hit
            position = upper
        }
        if position < range.upperBound { text += AttributedString(String(path[position..<range.upperBound])) }
        return text
    }
}

/// A tree, match or Quick Open row's 14-point icon: `folder.fill` in the folder color (FIL-02), else the file's
/// Material icon (`FileIcon`, FIL-09), which takes the worktree-relative path for the theme's path tails and the
/// workflow rule. Neither reads the disk.
struct FileTreeIcon: View {
    /// Worktree-relative.
    let path: String
    let isDirectory: Bool

    var body: some View {
        if isDirectory {
            Image(systemName: FileKind.folder.symbol)
                .font(.rocky(11))
                .foregroundStyle(FileKind.folder.color)
                .frame(width: Zoom.shared(14))
                .accessibilityHidden(true)
        } else {
            FileIcon(path: path, size: 14)
        }
    }
}

/// A line in place of the rows: no match (12.5 `textTertiary`), or git's failure (12 `danger`, selectable; ERR-02).
private struct FilesMessage: View {
    let text: String
    var isError = false

    var body: some View {
        Text(verbatim: text)
            .font(.rocky(isError ? 12 : 12.5))
            .foregroundStyle(isError ? Theme.danger : Theme.textTertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
    }
}
