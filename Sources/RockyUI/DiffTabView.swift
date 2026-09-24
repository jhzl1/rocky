import AppKit
import RockyKit
import SwiftUI

/// A diff tab's icon in the tab row (DIFF-01): the status letter of a file in Changes, else the file's kind, as an
/// unchanged file shows (FIL-05). A worktree tab always holds a file, so its kind comes from the name alone.
struct DiffTabIcon: View {
    let status: FileDiff.Status?
    let path: String

    var body: some View {
        if let status {
            ChangeStatusLetter(status: status)
        } else {
            let kind = FileKind(path: path, isDirectory: false)
            Image(systemName: kind.symbol)
                .font(.rocky(11))
                .foregroundStyle(kind.color)
        }
    }
}

/// A worktree file's tab next to the conversations (DIFF-01): a 34-point header, the editor's banners (EDIT-02,
/// EDIT-03), then the unified diff (DIFF-02, DIFF-03) or, in Edit mode, the code editor (EDIT-01) with its change bars
/// against the base (EDIT-04). A path that is not in Changes shows the editor with "Unchanged" in place of Diff | Edit
/// (FIL-05). Its tab keeps the workspace's changes computed while it is on screen (`AppModel.showsChanges`).
struct DiffTabView: View {
    let model: AppModel
    let workspace: Workspace
    /// Worktree-relative.
    let path: String
    /// Whether the editor takes the keyboard when it appears: not for the tree's preview (FIL-05), so the tree's arrows
    /// keep browsing.
    var takesFocus = true
    @State private var asksToDiscard = false

    private var url: URL {
        URL(fileURLWithPath: workspace.path).appendingPathComponent(path)
    }

    /// The file's key in `AppModel.editors`.
    private var editorPath: String {
        AppModel.editorPath(worktree: workspace.path, relativePath: path)
    }

    var body: some View {
        let changes = model.changes[workspace.id]
        let file = changes?.file(at: path)
        let picked = model.diffMode(workspaceId: workspace.id, path: path)
        // A deleted or binary file has no editor, whatever the tab picked (DIFF-03); a file known unchanged has only Edit
        // (FIL-05); before the changes are read, the tab shows what it picked.
        let mode: DiffTabMode = file.map { $0.isEditable ? picked : .diff } ?? (changes == nil ? picked : .edit)
        VStack(spacing: 0) {
            DiffTabHeader(
                model: model,
                workspaceId: workspace.id,
                path: path,
                editorPath: editorPath,
                url: url,
                file: file,
                isRead: changes != nil,
                mode: mode,
                select: { model.setDiffMode($0, workspaceId: workspace.id, path: path) },
                discard: { asksToDiscard = true }
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)
            EditorBanners(model: model, workspaceId: workspace.id, path: editorPath, isEditing: mode == .edit)
            content(isRead: changes != nil, file: file, mode: mode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // FIL-05's "Becoming changed": a tab shown unchanged, in Edit, stays in Edit when its file joins Changes (a
        // save, or the agent), rather than falling back to the diff.
        .onChange(of: changes != nil && file == nil, initial: true) { _, isUnchanged in
            guard isUnchanged, model.diffMode(workspaceId: workspace.id, path: path) != .edit else { return }
            model.setDiffMode(.edit, workspaceId: workspace.id, path: path)
        }
        .confirmationDialog(
            "Discard changes to \((path as NSString).lastPathComponent)?",
            isPresented: $asksToDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                let model = self.model
                let workspaceId = workspace.id
                let path = self.path
                Task { await model.discardChanges(workspaceId: workspaceId, paths: [path]) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    @ViewBuilder
    private func content(isRead: Bool, file: FileDiff?, mode: DiffTabMode) -> some View {
        if mode == .edit {
            editor
        } else if let file {
            UnifiedDiffView(model: model, workspace: workspace, file: file)
        } else if let failure = model.changesFailures[workspace.id], failure.action == .diff {
            // ERR-02: a diff that failed says so where the user looks, not only in the Changes tab.
            DiffMessage(title: failure.message, isError: true)
        } else {
            ProgressLabel(text: "Reading the changes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// EDIT-01: code, data and text files in the editor, with EDIT-04's bars against the file at the base (read once
    /// per base, `AppModel.loadEditorBase`); images and other media as their file tab shows them.
    @ViewBuilder
    private var editor: some View {
        if FileKind(path: url.path, isDirectory: false).opensInEditor {
            EditorPane(
                model: model,
                workspaceId: workspace.id,
                path: editorPath,
                baseText: model.editorBaseText(workspaceId: workspace.id, relativePath: path),
                takesFocus: takesFocus
            )
            .task(id: model.editorBaseKey(workspaceId: workspace.id, relativePath: path)) {
                await model.loadEditorBase(workspaceId: workspace.id, relativePath: path)
            }
        } else {
            FileTabView(model: model, workspaceId: workspace.id, path: url.path, showsHeader: false)
        }
    }
}

/// DIFF-01's header: the folder (`textTertiary`) and name (12.5), for a rename "old/path → new/path" (DIFF-03), the
/// file's `+a −d` and "New file", then "Edited" and Save while the editor has unsaved edits, or "Reloaded" (EDIT-02,
/// EDIT-03), then Diff | Edit, or "Unchanged" for a file not in Changes, and "⋯" (Reveal in All Files, Open in Finder,
/// Copy Path, and Discard Changes… for uncommitted files; no icons).
private struct DiffTabHeader: View {
    let model: AppModel
    let workspaceId: String
    let path: String
    /// The file's key in `AppModel.editors`.
    let editorPath: String
    let url: URL
    let file: FileDiff?
    /// The workspace's changes are read, so a missing `file` means the file is unchanged.
    let isRead: Bool
    let mode: DiffTabMode
    let select: (DiffTabMode) -> Void
    let discard: () -> Void
    /// FIL-05's Reveal shows the panel, whose open state ⌥⌘B and the panel toggle share.
    @AppStorage(RightPanelStorage.openKey) private var rightPanelOpen = true

    var body: some View {
        HStack(spacing: 10) {
            pathLabel
                .font(.rocky(12.5))
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(1)
                .help(file?.oldPath.map { "\($0) → \(path)" } ?? path)
            if let file {
                DiffStatLabel(stat: DiffStat(additions: file.additions, deletions: file.deletions))
                if file.status == .added {
                    Text("New file")
                        .font(.rocky(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
            EditorStatusControls(model: model, workspaceId: workspaceId, path: editorPath)
            if let file {
                ModePicker<DiffTabMode>(
                    options: [
                        .init(mode: .diff, title: "Diff"),
                        .init(mode: .edit, title: "Edit", disabledReason: Self.editDisabledReason(file)),
                    ],
                    selection: mode,
                    select: select
                )
            } else if isRead {
                Text("Unchanged")
                    .font(.rocky(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
            MenuButton(id: "diff-tab-more-\(workspaceId)-\(path)", placement: .belowTrailing, width: 220) { isOpen in
                SidebarMenuIcon(systemImage: "ellipsis", label: "More", isOpen: isOpen)
            } content: {
                // FIL-05: the panel on All files, the file's folders expanded and its row scrolled into view. A deleted
                // file has no row.
                if file?.status != .deleted {
                    MenuItem(title: "Reveal in All Files") {
                        rightPanelOpen = true
                        model.reveal(workspaceId: workspaceId, path: path)
                    }
                }
                MenuItem(title: "Open in Finder") { Self.revealInFinder(url) }
                MenuItem(title: "Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
                // GIT-05: only uncommitted changes can be discarded from Rocky.
                if file?.isUncommitted == true {
                    MenuDivider()
                    MenuItem(title: "Discard Changes…", isDestructive: true, action: discard)
                }
            }
            .font(.rocky(13))
            .help("More")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: Zoom.shared(34))
    }

    /// "src/api/" in `textTertiary`, then the name; a rename puts its old path and an arrow first.
    private var pathLabel: Text {
        let parent = (path as NSString).deletingLastPathComponent
        let folder = Text(verbatim: parent.isEmpty ? "" : parent + "/").foregroundStyle(Theme.textTertiary)
        let name = Text(verbatim: (path as NSString).lastPathComponent).foregroundStyle(Theme.textPrimary)
        if let oldPath = file?.oldPath {
            let old = Text(verbatim: "\(oldPath) → ").foregroundStyle(Theme.textTertiary)
            return Text("\(old)\(folder)\(name)")
        }
        return Text("\(folder)\(name)")
    }

    private static func editDisabledReason(_ file: FileDiff) -> String? {
        if file.status == .deleted { return "A deleted file cannot be edited" }
        if file.isBinary { return "A binary file cannot be edited" }
        return nil
    }

    /// The file selected in Finder; a deleted file's folder, as the file is gone.
    private static func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

/// DIFF-01's Diff | Edit, and a Markdown file tab's Preview | Edit (EDIT-01): 24 points on `fillControl`, radius 6, 2
/// points around 20-point segments (12, radius 4); the selected one on `fillSelected` in `textPrimary`.
struct ModePicker<Mode: Hashable>: View {
    struct Option {
        let mode: Mode
        let title: String
        /// Dims the segment and becomes its tooltip.
        var disabledReason: String?
    }

    let options: [Option]
    let selection: Mode
    let select: (Mode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.mode) { option in
                DiffModeSegment(title: option.title, isSelected: option.mode == selection, disabledReason: option.disabledReason) {
                    select(option.mode)
                }
            }
        }
        .padding(Zoom.shared(2))
        .background(Theme.fillControl, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
    }
}

private struct DiffModeSegment: View {
    let title: String
    let isSelected: Bool
    let disabledReason: String?
    let action: () -> Void
    @State private var hovering = false

    private var isEnabled: Bool { disabledReason == nil }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.rocky(12))
                .foregroundStyle(isSelected || (hovering && isEnabled) ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: Zoom.shared(20))
                .background(isSelected ? Theme.fillSelected : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .clickable()
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .optionalHelp(disabledReason)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// DIFF-02 and DIFF-03: a changed file's unified diff, or the line that stands in for it (binary, large, mode only).
/// The worktree file is read off the main actor for the unchanged runs (`DiffLayout`), and the tokens come from the
/// highlighter's queue; rows show plain text until they arrive (DIFF-04).
struct UnifiedDiffView: View {
    let model: AppModel
    let workspace: Workspace
    let file: FileDiff
    @State private var expanded: Set<DiffGap> = []
    /// The worktree file, read when the diff needs it (`DiffLayout.needsNewLines`); nil until then or when unreadable.
    @State private var newLines: [String]?
    @State private var isLoaded = false
    @State private var maxColumns = 0
    @State private var tokens = DiffTokens()
    /// DIFF-03's Show on a large diff.
    @State private var showsLarge = false
    @State private var sizes: FileSizes?
    /// The hunks' new starts the rows were laid out for: when they move, the expanded runs no longer mean the same lines.
    @State private var layout: [Int] = []
    @State private var scroll = DiffScrollOffset()
    @State private var viewportWidth: CGFloat = 0
    /// CMT-01's range and CMT-02's composer, for this tab only.
    @State private var commenting = DiffCommentState()

    private struct FileSizes {
        let old: Int?
        let new: Int?
    }

    private struct LoadKey: Equatable {
        let file: FileDiff
        let showsLarge: Bool
    }

    private var isCollapsed: Bool {
        file.isLarge && !showsLarge
    }

    var body: some View {
        content
            .task(id: LoadKey(file: file, showsLarge: showsLarge)) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if file.isBinary {
            DiffMessage(title: binaryTitle)
        } else if isCollapsed {
            DiffMessage(title: "Large diff · \(file.changedLineCount.formatted()) lines", action: (title: "Show", run: { showsLarge = true }))
        } else if file.hunks.isEmpty, !(file.status == .added && file.isLarge) {
            DiffMessage(title: emptyTitle)
        } else if file.hunks.isEmpty, isLoaded, newLines == nil {
            // An untracked file past what Rocky reads (DiffLayout.maxReadBytes).
            DiffMessage(title: "This file is too large to show in Rocky.")
        } else {
            rowsView
        }
    }

    /// "Binary file · 24 KB → 31 KB"; one size for an added or deleted file, none until they are read.
    private var binaryTitle: String {
        let format = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        switch (sizes?.old, sizes?.new) {
        case (let old?, let new?): return "Binary file · \(format(old)) → \(format(new))"
        case (let old?, nil): return "Binary file · \(format(old))"
        case (nil, let new?): return "Binary file · \(format(new))"
        case (nil, nil): return "Binary file"
        }
    }

    /// A file without rows: a mode change, a rename without content changes, an empty file.
    private var emptyTitle: String {
        if let modeChange = file.modeChange { return Self.modeText(modeChange) }
        if file.oldPath != nil { return "Renamed without changes" }
        if file.status == .added { return "Empty file" }
        return "No changes to show"
    }

    /// DIFF-03's "File mode changed 644 → 755", from git's "100644" and "100755".
    private static func modeText(_ change: ModeChange) -> String {
        "File mode changed \(change.old.suffix(3)) → \(change.new.suffix(3))"
    }

    /// DIFF-05: a badge asked this tab for its first hunk; the serial of the request, when it is this file's.
    private var scrollRequest: Int? {
        guard let request = model.diffScrollRequests[workspace.id], request.path == file.path else { return nil }
        return request.serial
    }

    private var rowsView: some View {
        let comments = model.comments(onFile: file.path, workspaceId: workspace.id)
        let draft = commenting.draft
        // A run holding a commented line opens, so the comment shows under its line (CMT-02).
        let commented = Set(comments.filter { $0.state != .outdated }.map { CommentLine(side: $0.side, number: $0.endLine) })
        let open = expanded.union(DiffLayout.gaps(holding: commented, in: file, lineCount: newLines?.count))
        let rows = DiffLayout.rows(for: file, newLines: newLines, expanded: open)
        let placement = CommentAnchor.placement(of: comments, draft: draft?.lastLine, in: rows)
        let contentWidth = Zoom.shared(DiffMetrics.gutterWidth + DiffMetrics.codeTrailingPadding)
            + CGFloat(maxColumns) * DiffMetrics.characterWidth
        let width = max(contentWidth, viewportWidth)
        // CMT-02's cards: at most 560 wide, and within the viewport past the gutter.
        let cardWidth = min(Zoom.shared(560), max(Zoom.shared(240), viewportWidth - Zoom.shared(DiffMetrics.gutterWidth) - 24))
        let tokens = self.tokens
        let scroll = self.scroll
        let commenting = self.commenting
        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !placement.outdated.isEmpty || !placement.unplaced.isEmpty {
                        commentSlot(outdated: placement.outdated, comments: placement.unplaced, showsComposer: false, rows: rows, width: width, cardWidth: cardWidth)
                    }
                    if let modeChange = file.modeChange {
                        DiffCaptionRow(text: Self.modeText(modeChange), width: width, scroll: scroll)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .hunk(_, let header):
                            DiffHunkRow(header: header, width: width, scroll: scroll)
                        case .line(let line):
                            DiffLineRow(line: line, tokens: tokens.tokens(for: line), width: width, scroll: scroll, commenting: commenting)
                        case .gap(let gap, let count):
                            DiffGapRow(count: count, width: width, scroll: scroll) { expanded.insert(gap) }
                        }
                        let under = placement.underRows[row.id] ?? []
                        let showsComposer = placement.draftRowId == row.id
                        if !under.isEmpty || showsComposer {
                            commentSlot(comments: under, showsComposer: showsComposer, rows: rows, width: width, cardWidth: cardWidth)
                        }
                    }
                }
                .coordinateSpace(.named(DiffCommentState.space))
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                scroll.x = x
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, width in
                viewportWidth = width
            }
            .onChange(of: scrollRequest) { _, request in
                // A tab that opens for the badge starts at its top, where the first hunk is; this is for a tab that was
                // already on screen, scrolled elsewhere.
                guard request != nil else { return }
                proxy.scrollTo(DiffRow.firstHunkId, anchor: .topLeading)
            }
        }
    }

    private func commentSlot(
        outdated: [DiffCommentRecord] = [],
        comments: [DiffCommentRecord],
        showsComposer: Bool,
        rows: [DiffRow],
        width: CGFloat,
        cardWidth: CGFloat
    ) -> some View {
        DiffCommentSlot(
            outdated: outdated,
            comments: comments,
            showsComposer: showsComposer,
            commenting: commenting,
            width: width,
            cardWidth: cardWidth,
            scroll: scroll,
            save: { saveDraft(rows: rows) },
            delete: { deleteComment($0) }
        )
    }

    /// CMT-02's Comment: a new comment keeps the text of its lines (`CommentAnchor.capture`) from the rows it was made
    /// on, or its edit gets the new body. The range and the composer go.
    private func saveDraft(rows: [DiffRow]) {
        guard let draft = commenting.draft else { return }
        let body = commenting.text
        if let id = draft.editing {
            model.editDiffComment(id: id, workspaceId: workspace.id, body: body)
        } else {
            let capture = CommentAnchor.capture(draft.range, side: draft.side, rows: rows, newLines: newLines)
            model.addDiffComment(workspaceId: workspace.id, path: file.path, side: draft.side, lines: draft.range, capture: capture, body: body)
        }
        commenting.cancel()
    }

    private func deleteComment(_ comment: DiffCommentRecord) {
        if commenting.draft?.editing == comment.id { commenting.cancel() }
        model.deleteDiffComment(id: comment.id, workspaceId: workspace.id)
    }

    /// Reads what the rows need for this version of the file: the worktree file for its unchanged runs, the widest
    /// line, the binary sizes and the tokens. Nothing for a large diff until Show.
    private func load() async {
        let file = self.file
        let hunkStarts = file.hunks.map(\.newStart)
        if hunkStarts != layout {
            if !layout.isEmpty { expanded = [] }
            layout = hunkStarts
        }
        if file.isBinary {
            let found = await model.binarySizes(workspaceId: workspace.id, path: file.path)
            guard !Task.isCancelled else { return }
            sizes = FileSizes(old: found.old, new: found.new)
            return
        }
        guard !isCollapsed else { return }
        let wantsLines = DiffLayout.needsNewLines(file)
        let url = URL(fileURLWithPath: workspace.path).appendingPathComponent(file.path)
        let reading = await Task.blocking { () -> (lines: [String]?, columns: Int) in
            let lines = wantsLines ? DiffLayout.readLines(of: url) : nil
            return (lines, DiffMetrics.maxColumns(file: file, lines: lines))
        }.value
        guard !Task.isCancelled else { return }
        newLines = reading.lines
        maxColumns = reading.columns
        isLoaded = true
        guard let language = SyntaxHighlighter.language(forPath: file.path) else {
            tokens = DiffTokens()
            return
        }
        let found = await SyntaxHighlighter.shared.diffTokens(file: file, newLines: reading.lines, language: language)
        guard !Task.isCancelled else { return }
        tokens = found
    }
}

/// DIFF-03's line in place of rows: 13 `textSecondary`, centered 40 points down, at most 420 wide; with a filled
/// button under it when there is something to do (Show). An error reads in `danger` and can be selected.
struct DiffMessage: View {
    let title: String
    var isError = false
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.rocky(isError ? 12 : 13))
                .foregroundStyle(isError ? Theme.danger : Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let action {
                Button(action.title, action: action.run)
                    .font(.rocky(12.5, weight: .medium))
                    .buttonStyle(RockyFilledButtonStyle())
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 20)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
