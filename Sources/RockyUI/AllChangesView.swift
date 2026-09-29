import AppKit
import RockyKit
import SwiftUI

/// ALL-01…ALL-09: every changed file of the workspace in one tab, Uncommitted then Committed, each under a pinned header
/// that folds it, with DIFF-02's rows, read only. One scroll view moves the whole list sideways together, as one diff
/// tab does; a file reads its worktree lines and tokens when its header first shows (`DiffFileLoader`), so a folded or
/// far file costs nothing.
struct AllChangesView: View {
    let model: AppModel
    let workspace: Workspace
    /// Each file's reading, by path, with the version of the file it was made for: a changed file reads again.
    @State private var loads: [String: FileLoad] = [:]
    @State private var scroll = DiffScrollOffset()
    @State private var viewportWidth: CGFloat = 0
    /// ALL-09: the row at the top, which an update keeps in place (`AllChangesLayout.anchor`).
    @State private var anchor: String?
    /// The files in the order the last layout had them, for an anchor whose file went.
    @State private var previousPaths: [String] = []
    @FocusState private var isFocused: Bool

    struct FileLoad {
        let file: FileDiff
        var lines: DiffFileLoader.Lines?
        var tokens = DiffTokens()
        var sizes: (old: Int?, new: Int?)?
    }

    var body: some View {
        let changes = model.changes[workspace.id]
        let state = model.allChangesState(workspaceId: workspace.id)
        let sections = changes.map { AllChangesLayout.sections(changes: $0, state: state, newLines: newLines(for: $0)) } ?? []
        VStack(spacing: 0) {
            AllChangesToolbar(
                changes: changes,
                allFolded: !sections.isEmpty && sections.allSatisfy { $0.isFolded || !$0.canFold },
                setFolded: { model.setAllChangesFolded(workspaceId: workspace.id, $0) }
            )
            if let changes, !changes.files.isEmpty {
                list(sections, state: state, changes: changes)
            } else if changes == nil {
                ProgressLabel(text: "Reading the changes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ChangesEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The loaded lines of each file whose reading is for its current version.
    private func newLines(for changes: WorkspaceChanges) -> [String: [String]] {
        var lines: [String: [String]] = [:]
        for file in changes.files {
            if let load = loads[file.path], load.file == file, let read = load.lines?.newLines { lines[file.path] = read }
        }
        return lines
    }

    /// The widest line among the unfolded files, so the sideways range covers every row that can show.
    private func width(of sections: [AllChangesSection]) -> CGFloat {
        let columns = sections.filter { !$0.isFolded && $0.canFold }.map { section in
            if let load = loads[section.file.path], load.file == section.file, let lines = load.lines { return lines.maxColumns }
            return DiffMetrics.maxColumns(file: section.file, lines: nil)
        }.max() ?? 0
        let content = Zoom.shared(DiffMetrics.gutterWidth + DiffMetrics.codeTrailingPadding) + CGFloat(columns) * DiffMetrics.characterWidth
        return max(content, viewportWidth)
    }

    private func list(_ sections: [AllChangesSection], state: AllChangesState, changes: WorkspaceChanges) -> some View {
        let width = width(of: sections)
        let scroll = self.scroll
        let viewport = viewportWidth
        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        if let caption = section.kindCaption {
                            Sticky(scroll: scroll) {
                                ChangesSectionHeader(title: caption.kind.title, count: caption.count)
                                    .frame(width: viewport)
                            }
                            .frame(width: width, alignment: .leading)
                            .id(caption.id)
                        }
                        Section {
                            ForEach(section.rows) { row in
                                rowView(row, file: section.file, width: width)
                            }
                        } header: {
                            AllChangesFileHeader(
                                section: section,
                                isCurrent: state.current == section.file.path,
                                width: width,
                                viewportWidth: viewport,
                                scroll: scroll,
                                toggle: { model.toggleAllChangesFold(workspaceId: workspace.id, path: section.file.path) },
                                open: { model.openDiff(workspaceId: workspace.id, path: section.file.path) }
                            )
                            .id(section.headerId)
                            .task(id: LoadKey(file: section.file, wantsRows: !section.isFolded && section.canFold)) {
                                await load(section)
                            }
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.bottom, 40)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .defaultScrollAnchor(.topLeading, for: .alignment)
            .scrollPosition(id: $anchor, anchor: .topLeading)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                scroll.x = x
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, width in
                viewportWidth = width
            }
            // ALL-06: scrolling by hand ends the keys' current file; the next press starts from the top one.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { model.setAllChangesCurrent(workspaceId: workspace.id, path: nil) }
            }
            .onChange(of: sections) { _, sections in
                keepAnchor(in: sections)
                previousPaths = sections.map(\.file.path)
            }
            .onChange(of: model.allChangesSteps[workspace.id]) { _, step in
                guard let step else { return }
                let from = state.current ?? topPath
                guard let target = changes.file(after: from, step: step.step) else { return }
                model.setAllChangesCurrent(workspaceId: workspace.id, path: target.path)
                proxy.scrollTo(AllChangesSection.headerId(of: target.path), anchor: .topLeading)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            // ALL-06: Return opens the current file's own diff tab.
            .onKeyPress(.return) {
                guard let path = state.current ?? topPath else { return .ignored }
                model.openDiff(workspaceId: workspace.id, path: path)
                return .handled
            }
            .onAppear {
                previousPaths = sections.map(\.file.path)
                anchor = model.allChangesAnchors[workspace.id].flatMap {
                    AllChangesLayout.anchor(in: sections, was: $0, previousPaths: previousPaths)
                }
                isFocused = true
            }
            .onDisappear { model.rememberAllChangesAnchor(workspaceId: workspace.id, id: anchor) }
        }
    }

    /// The file of the row at the top: the part of its id before the last "|".
    private var topPath: String? {
        guard let anchor, let bar = anchor.range(of: "|", options: .backwards), !anchor.hasPrefix("section|") else { return nil }
        return String(anchor[..<bar.lowerBound])
    }

    /// ALL-09: an anchor whose row is gone moves to the nearest one left, so the line being read stays on screen.
    private func keepAnchor(in sections: [AllChangesSection]) {
        guard let anchor else { return }
        let kept = AllChangesLayout.anchor(in: sections, was: anchor, previousPaths: previousPaths)
        if kept != anchor { self.anchor = kept }
    }

    @ViewBuilder
    private func rowView(_ row: AllChangesRow, file: FileDiff, width: CGFloat) -> some View {
        switch row {
        case .line(let path, let line):
            DiffLineRow(line: line, tokens: loads[path]?.tokens.tokens(for: line) ?? [], width: width, scroll: scroll)
        case .gap(let path, let gap, let count):
            DiffGapRow(count: count, width: width, scroll: scroll) {
                model.expandAllChangesGap(workspaceId: workspace.id, path: path, gap: gap)
            }
        case .caption(let path, let caption):
            AllChangesCaptionRow(caption: caption, sizes: loads[path]?.sizes, width: width, scroll: scroll) {
                model.showAllChangesLarge(workspaceId: workspace.id, path: path)
            }
        case .spacer:
            Color.clear.frame(width: width, height: 8)
        }
    }

    private struct LoadKey: Equatable {
        let file: FileDiff
        let wantsRows: Bool
    }

    /// Reads what a file's rows need once per version: a binary file's sizes, else its lines and tokens. Nothing for a
    /// folded file or a caption (ALL-05, ALL-07).
    private func load(_ section: AllChangesSection) async {
        let file = section.file
        if let existing = loads[file.path], existing.file == file, existing.lines != nil || existing.sizes != nil { return }
        if file.isBinary {
            let sizes = await model.binarySizes(workspaceId: workspace.id, path: file.path)
            guard !Task.isCancelled else { return }
            loads[file.path] = FileLoad(file: file, sizes: (sizes.old, sizes.new))
            return
        }
        guard !section.isFolded, section.canFold else { return }
        let lines = await DiffFileLoader.lines(of: file, worktree: workspace.path)
        guard !Task.isCancelled else { return }
        loads[file.path] = FileLoad(file: file, lines: lines)
        let tokens = await DiffFileLoader.tokens(of: file, newLines: lines.newLines)
        guard !Task.isCancelled, loads[file.path]?.file == file else { return }
        loads[file.path]?.tokens = tokens
    }
}

/// ALL-03's toolbar: "5 files", the total `+A −D`, and Collapse all, which reads Expand all once every file is folded.
private struct AllChangesToolbar: View {
    let changes: WorkspaceChanges?
    let allFolded: Bool
    let setFolded: (Bool) -> Void

    var body: some View {
        let count = changes?.files.count ?? 0
        HStack(spacing: 8) {
            Text(count == 0 ? "No files" : "\(count) \(count == 1 ? "file" : "files")")
                .font(.rocky(12))
                .foregroundStyle(Theme.textSecondary)
            if let changes, count > 0 { DiffStatLabel(stat: changes.stat) }
            Spacer(minLength: 0)
            Button(allFolded ? "Expand all" : "Collapse all", systemImage: allFolded ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left") {
                setFolded(!allFolded)
            }
            .font(.rocky(12))
            .buttonStyle(RockyTextButtonStyle(height: 24))
            .clickable()
            .disabled(count == 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: Zoom.shared(34))
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

/// ALL-03's header, pinned while its file's rows scroll under it: the chevron, the status letter, the file's icon, its
/// folder and name (the name opens its own diff tab), the note and `+a −d`; a click elsewhere folds it. It stays at the
/// left edge when the list scrolls sideways, and the current file of ALL-06's keys has a 3-point `accent` bar.
private struct AllChangesFileHeader: View {
    let section: AllChangesSection
    let isCurrent: Bool
    let width: CGFloat
    let viewportWidth: CGFloat
    let scroll: DiffScrollOffset
    let toggle: () -> Void
    let open: () -> Void
    @State private var nameHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let file = section.file
        let parent = (file.path as NSString).deletingLastPathComponent
        Sticky(scroll: scroll) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.rocky(9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(section.isFolded ? -90 : 0))
                    .animation(reduceMotion ? nil : Theme.Motion.state, value: section.isFolded)
                    .frame(width: Zoom.shared(18))
                    .opacity(section.canFold ? 1 : 0)
                ChangeStatusLetter(status: file.status)
                FileIcon(path: file.path, size: 14)
                Button(action: open) {
                    (Text(verbatim: parent.isEmpty ? "" : parent + "/").foregroundStyle(Theme.textTertiary)
                        + Text(verbatim: (file.path as NSString).lastPathComponent).foregroundStyle(Theme.textPrimary))
                        .font(.rocky(12.5))
                        .underline(nameHovered)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .buttonStyle(.plain)
                .clickable()
                .onHover { nameHovered = $0 }
                .help("Open in its own tab")
                if let note = section.note {
                    Text(verbatim: note)
                        .font(.rocky(11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                DiffStatLabel(stat: DiffStat(additions: file.additions, deletions: file.deletions, files: 1))
            }
            .padding(.horizontal, 12)
            .frame(width: viewportWidth, height: Zoom.shared(34))
            .overlay(alignment: .leading) {
                if isCurrent { Rectangle().fill(Theme.accent).frame(width: 3) }
            }
        }
        .frame(width: width, height: Zoom.shared(34), alignment: .leading)
        .background(Color.rockyBackground)
        .background(Theme.fillControl)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { if section.canFold { toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// ALL-07's line under a header in place of rows, where the code starts: a large diff's count with Show, a binary
/// file's sizes, a mode change, a rename without content changes.
private struct AllChangesCaptionRow: View {
    let caption: AllChangesCaption
    let sizes: (old: Int?, new: Int?)?
    let width: CGFloat
    let scroll: DiffScrollOffset
    let show: () -> Void

    var body: some View {
        Sticky(scroll: scroll) {
            HStack(spacing: 10) {
                Text(text)
                    .font(.rocky(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                if case .large = caption {
                    Button("Show", action: show)
                        .font(.rocky(12))
                        .buttonStyle(RockyTextButtonStyle(height: 22))
                        .clickable()
                }
            }
            .padding(.leading, Zoom.shared(DiffMetrics.gutterWidth))
        }
        .frame(width: width, height: Zoom.shared(DiffMetrics.barHeight), alignment: .leading)
    }

    private var text: String {
        switch caption {
        case .large(let lines): return "Large diff · \(lines.formatted()) lines"
        case .binary:
            let format = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
            switch (sizes?.old, sizes?.new) {
            case (let old?, let new?): return "Binary file · \(format(old)) → \(format(new))"
            case (let old?, nil): return "Binary file · \(format(old))"
            case (nil, let new?): return "Binary file · \(format(new))"
            case (nil, nil): return "Binary file"
            }
        case .modeOnly(let change): return "File mode changed \(change.old.suffix(3)) → \(change.new.suffix(3))"
        case .renamed: return "Renamed, no content changes"
        case .emptyFile: return "Empty file"
        }
    }
}
