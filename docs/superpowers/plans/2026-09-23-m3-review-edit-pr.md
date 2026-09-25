# M3 Review and Edit Implementation Plan

**Status: done**, merged into `development` on 2026-09-24; 547 tests pass. The manual checklist is still open: `docs/superpowers/m3-verification.md`. The All files tab joined M3 (user decision, 2026-09-24): Tasks 11–15 (`FIL-01`…`FIL-07`).

> **Execution:** task by task. Tests are written with each change and run once, in Task 18 (global rule `## Tests` in `~/.claude/CLAUDE.md`). Build once, at the end of the tasks, and commit only when the user asks (`CLAUDE.md`); each task's commit line is the message to use then. This plan gives decisions, files, public interfaces, required behavior and the tests to write. It does not carry the code: the implementer writes it.

> **Revised 2026-09-23:** the pull request part (GitHub account, create, checks, merge, sidebar glyphs: `ACC-01`, `PR-01`…`PR-07`, `ROW-07`, former Tasks 12–14) moved to M2.7 (`docs/superpowers/plans/2026-09-23-m2.7-github.md`), and the Changes panel became the Changes tab of M2.7's right panel. The user asked for Conductor's right panel (relayed by dev-1). The file keeps its name so existing links still work.

> **Revised 2026-09-24:** the All files tab joins M3 (user decision): `FIL-01`…`FIL-07`, Tasks 11–15. The designer also changed `CHG-01` (three pills: All files · Changes N · Checks), `KBD-02` (⌘P and the tree's keys; M2.7's panel is ⌥⌘B, and ⌘⇧G is gone) and `OUT-10` (no creating, renaming or deleting files from the tree), and the mock now follows M2.7's final layout (`LAY-01`). The former Tasks 11–13 are now Tasks 16–18.

**Goal:** Inside a workspace, browse the worktree's files and open any of them, see what changed against its base, review it file by file, comment on line ranges and send the comments to the agent, edit files in Rocky, and commit. It all lives in the All files and Changes tabs of M2.7's right panel and in tabs next to the conversations.

**Visual and behavioral source of truth:** `docs/superpowers/design/2026-09-23-m3-review-edit-pr.html`. Open it in a browser. Every requirement has an id (`FIL-02`, `CHG-02`, `DIFF-02`, `CMT-04`, `EDIT-03`…); the same id is on the element of the mock (button "Requirement pins"), in the requirement list on the right of that page, and in the task below that implements it. Values are at 100 % zoom. When the mock and a requirement's text disagree, the text wins. The mock follows M2.7's final layout (`LAY-01`). Its tree, diff, highlighter and git are JavaScript stand-ins: do not port them.

**Architecture:** Same package. RockyKit gains the git layer (`GitChangesService`, `DiffParser`, `FileWatcher`), the worktree's files (`FileTree`, `WorktreeFiles`, `FileContent`), comment logic (`CommentAnchor`, `ReviewPrompt`), buffer rules (`EditBuffer`) and two store migrations. RockyUI gains the All files and Changes tabs of M2.7's right panel, diff and file tabs, comment views, a syntax highlighter on a vendored Prism bundle, the `CodeEditor` and the commit sheet.

**Spec:** `docs/superpowers/specs/2026-09-22-rocky-design.md`, milestone M3, Sections 1 (energy), 4 (diff and comments) and 5 (errors). M2.5 (the shell this builds on): `docs/superpowers/design/2026-09-23-sidebar-topbar.html` and `docs/superpowers/plans/2026-09-23-m2.5-sidebar-topbar.md`. M2.7 (the right panel this adds two tabs to): `docs/superpowers/design/2026-09-23-m2.7-github.html` and `docs/superpowers/plans/2026-09-23-m2.7-github.md`. Read each plan's "Changes during implementation".

## Preconditions

- M2.5, M2.6 and M2.7 are finished and merged into `development`. Create `feat/m3-review-edit-files` from `development` after that. Never commit on `development` or `main`. The remote is `origin`; push only when the user asks.
- Re-read these symbols before Task 1. The names below were checked with `rg` in M2.7's working tree on 2026-09-24 and may still move before it merges. **Symbols are authoritative, line numbers are not.**
  - M2.5: `Theme` tokens and `Theme.Motion` (`hover` is 120 ms), `RockyIconButtonStyle` (`isOn:`, M2.7), `RockyFilledButtonStyle` (`height:horizontalPadding:cornerRadius:`, M2.7), `RockyTextButtonStyle`, `RockyOutlineButtonStyle` (M2.7), `.clickable()`, `WindowMetrics.titleBarHeight` and `titleRowHeight` (M2.7), `PanelDivider`, `WorkspaceStatus` (with `mostUrgent(_:)`), `AppModel.status(workspaceId:)`, `WorkingRow`, `ShimmerText`, `CircularProgress`.
  - `WorkspaceDetailView`: after `LAY-01`, one full-height row of the conversation column (top bar, `ConversationTabs`, the chat/terminal split) | `ColumnDivider` | `RightPanel`; `chatArea` lays a file tab over the conversation; the private `openWorktree(in:app:)` opens the worktree in an editor (`OPN-01`). `ConversationTabs`, `WorkspaceTab` (one `onTapGesture`, a plain `title`), `FileTabView` (text up to its 2 MB `maxTextBytes`, images drawn by itself, anything else in Quick Look), `FileKind` (RockyUI, in `FileBadge.swift`; `init(path:)` checks the disk for a name without an extension, to spot folders), `FileBadge`, `OpenFileAction` (`\.openFile`), `ActivityRows` (`ToolCallRow`).
  - `AppModel`: `selectedWorkspaceId`, `openFiles` / `selectedFiles` / `openFile(workspaceId:path:)` / `showFile` / `closeFile` (absolute paths, in memory), `rightPanelTabs`, `isWindowVisible`, `onToast`, the chats and `ChatSessionModel`'s way to send a prompt, `removeWorkspace(id:skipArchive:stashingChanges:)`, `environment(for:)`, `prepareEnvironment(for:)`, `existingProcesses(for:)`.
  - M2.7:
    - `RightPanelTab` lives in RockyKit (`App/PullRequestActions.swift`), with `title`, and has only `.checks`. M3 adds `.files` and `.changes` before it. `AppModel.rightPanelTabs` keeps the selected tab per workspace, in memory.
    - `RightPanel` falls back to `.checks`, wraps every tab in one `ScrollView`, and makes `REV-01`'s comments visible in `onAppear`, because Checks is its only tab. `RightPanelTabRow` shows a lone tab as a title and draws pills for two or more. `RightPanelTabButton` takes a title only.
    - Around the panel: `RightPanelStorage.openKey` / `widthKey`, `RightPanelToggle`, `RightPanelFooter`, `PullRequestHeaderBar` (its `PullRequestPill` selects `.checks`), `PullRequestPanelCommand` (View ▸ Show Pull Request Panel, ⌥⌘B), `SidebarCommand` (⌃⌘S), `PanelToggleText`.
    - Shared pieces: `ColumnDivider` (in `PanelDivider.swift`), `Theme.merged`, `ToastPresenter` (`Toast.swift`), `WindowVisibilityReader` and `\.windowIsVisible` (`WindowVisibility.swift`), `GitGlyph` (`SidebarRow.swift`), `ExternalEditor` (`installed(lookup:)`), `WorkspaceStatus.pullRequest` / `merged`.
    - Git: `GitBranchService` (a synchronous `Sendable` struct with `init(environment:)`; `git --no-optional-locks status`), `BlockingWorkExecutor` and `Task.blocking` (`ProcessRunner.swift`; every blocking call since M2.7's record of 2026-09-24), `WorktreeService.nonInteractive(_:)`.
  - `RockyStore` migrations (read the latest name in `RockyStore.migrator`; M2.7 added two), `update(_: Workspace)` and `update(_: Repo)` (whole-row), `savePullRequest` (M2.7's column-only update), `Repo`, `Workspace`, `ProcessRunner.run` (an enum's static function, not an injectable instance), `WorktreeService.baseRef(repo:)`.
  - `RepoSettingsModal`, `MenuButton` (`growsToFit:`), `MenuItem` (`isChecked`, `shortcut`, `disabledReason`, `trailingSymbol`; `MenuIcon.none` takes no icon column, and no menu mixes rows with and without icons), `MenuDivider`, `rockyContextMenu`, `MenuPresenter` (`isAnyMenuOpen`), `Zoom.shared`, `Font.rocky`.
  - `ChatView.handleKey`: its key monitor takes Esc anywhere in the key window while a turn runs, except while a menu, the settings panels or a sheet is open.
  - Tests: `GitFixture` (`localRepo`, `clonedRepo`, the `…OffMain` helpers) and the `.blockingWork` suite trait, which every synchronous git suite uses (M2.7 record).
- The chat is a plain `VStack` with `ChatItemRow.equatable()` (M2 record), not a `LazyVStack`.

## Decisions

Taken with the user on 2026-09-23:

- **Layout:** the Changes tab of the right panel (M2.7's `PNL-01`); each file's diff opens as a tab next to the conversations. The chat stays visible. (Originally a Changes panel of its own; changed 2026-09-23 when the right panel moved to M2.7.)
- **Unified diff** only. Side by side is out.
- **Editing inside Rocky** with a real code editor, not by jumping to an external editor.
- **All of M3 in one plan:** review, comments, sending comments to the agent, editing and committing. The pull request part moved to M2.7 on 2026-09-23.

Taken with the user on 2026-09-24:

- **M3 goes right after M2.7**, then M2.8.
- **The All files tab is in M3** ("falta el editor y visualizador de archivos"): the worktree's file tree, first in the right panel's tab row, where any file opens with the same viewer and editor as the diff tabs (`FIL-01`).
- **Git-ignored entries are hidden by default** (`FIL-03`). The designer proposed it and the user confirmed it. "Show Ignored Files" shows them dimmed and is remembered per repository.
- **A single click in the tree opens a preview tab** (`FIL-05`). The designer proposed it and the user confirmed it. The title is in italics, and the next single click replaces it. A double-click on the row, a double-click on the tab or the first edit keeps it. The Changes tab keeps opening regular tabs.

Taken in this plan. Change them here, not during implementation:

- **The diff is read-only; editing is a separate mode** (Diff | Edit) of the same tab. Comments live in the diff, typing lives in the editor, and neither has to handle the other's case.
- **Rocky commits** (GIT-04), without the agent, typically your own edits from the editor. M2.7's "Commit and push" (`AGT-02`) asks the agent instead.
- **Discard only uncommitted changes**, and untracked files go to the Trash (GIT-05).
- **Syntax highlighting with Prism vendored in RockyUI and run in JavaScriptCore** (DIFF-04). Textual's own tokenizer is internal and cannot be reused; tree-sitter would add a C dependency per language.
- **The diff and the tree are `LazyVStack`s of fixed-height rows** (DIFF-02, FIL-01), so comment cards can sit between diff rows and a folder of thousands of entries is never laid out whole. Fixed heights avoid the scroll bar jumps that pushed the chat to a `VStack`. Fallback in Known risks.
- **The editor is an `NSTextView`** in an `NSViewRepresentable` with a ruler for the gutter (EDIT-01).
- **Git and file reads are synchronous `Sendable` structs** (`GitChangesService`, `WorktreeFiles`), like M2.7's `GitBranchService`, and callers run them through `Task.blocking`. They are not actors: in M2.7, blocking git on the cooperative pool starved the terminals' reads (its record, 2026-09-24). This overrules GIT-01's "actor".
- **`changes` follows what is on screen.** It is computed for the selected workspace while that workspace shows its Changes tab, its All files tab or one of its diff tabs. GIT-01 names only the Changes tab. FIL-02's letters and FIL-05's "Becoming changed" need the other two.
- **One tab per worktree file.** Diff tabs hold worktree-relative paths, changed or not. A path that is not in `changes` shows as an unchanged file tab (`FIL-05`), so a file that joins Changes keeps its tab. A badge's file inside the worktree opens that same tab; files outside the worktree keep today's file tab (`openFiles`). This departs from DIFF-05's "as today" inside the worktree, because two tabs on one file would be two buffers overwriting each other's saves.
- **The filter's list is kept in Finder's order.** It is sorted once when `ls-files` returns, so each keystroke is one pass that sorts matches into FIL-04's ranks, with no locale-aware comparison (`FIL-04`'s ties, `FIL-07`'s 50 ms).
- **Files deleted from disk leave the list.** `git ls-files --cached` still lists a file deleted but not staged, so `git ls-files --deleted -z` runs with it (`FIL-02`, "Deleted"). The HTML names only the first command.
- **Large read-only files are plain text** (2–20 MB, `FIL-06`): Prism in JavaScriptCore over megabytes would stall the tab.
- **A workspace that never picked a tab shows Changes**, the mock's default. M2.7 falls back to Checks. The pull request pill still selects Checks.
- **Two store migrations, each the next free one when its task is written:** comments (Task 6), then the tree's state (Task 12). The expanded folders live in a table that goes with its workspace, and "Show Ignored Files" in a `repo` column written by a column-only update.

## Global constraints

- macOS 15 minimum, Swift 6 language mode. No new Swift package. Prism's JavaScript bundle is a resource file of RockyUI; record its version and MIT license in `README.md`.
- **Zoom:** text through `Font.rocky`, text- and icon-holding sizes through `Zoom.shared(_:)`, as in M2.5.
- **Energy (spec Section 1):**
  - No timers that poll the disk. One FSEvents stream per workspace (no process at rest); `git` runs only after a change, debounced.
  - The full diff only for the selected workspace while it shows it (Decisions).
  - The All files tab reads only expanded folders, and runs `ls-files` only while it shows, after an event (`FIL-07`).
  - Blocking git and file reads run on `BlockingWorkExecutor` (`Task.blocking`), never on the cooperative pool.
- Menus: Rocky's own (`MenuButton`, `MenuItem`, `rockyContextMenu`); no SwiftUI `Menu` or `.contextMenu`. M3's "⋯" menus have no icons, so they take no icon column.
- Git runs in the worktree with the workspace environment (`environment(for:)`), through `ProcessRunner`. Reads use `git --no-optional-locks`, so Rocky never holds the index lock an agent's git needs. Never `--no-verify`.
- All code, comments, identifiers and UI copy in English. The user guide, `docs/README.md`, is in Spanish and follows every change the user sees (`CLAUDE.md`). Commits: Conventional Commits, no AI attribution line.
- Shell: `bat`, `eza`, `rg`, `fd`, `sd`.
- Manual tests on personal repositories only, never a work repository.

## Review Focus

1. At rest, with several workspaces open and the All files tab showing, Rocky spawns no process (FSEvents only). Checked with Activity Monitor / `CurrentPowerlog.PLSQL` in Task 18.
2. A comment stays on its lines when lines are inserted above it, and turns Outdated when its lines change. Pinned by `CommentAnchorTests`.
3. Saving never overwrites a file the agent changed after it was loaded, unless the user chose Keep Mine. Pinned by `EditBufferTests`.
4. The review prompt has exactly the format of CMT-05. Pinned by `ReviewPromptTests`.
5. Discard never touches committed changes, and untracked files go to the Trash. Pinned by `GitChangesServiceTests.discard…`.
6. The tree reads only expanded folders, re-reads only the folder an event names, and runs `ls-files` only while it shows. Pinned by `AppModelTests.hiddenFilesTabRunsNoGit`, `anEventReReadsOnlyTheExpandedFolderItNames` and Task 18's process count.
7. The filter ranks in FIL-04's order, keeps Finder's order in ties, and ranks 100,000 paths in under 50 ms. Pinned by `FileTreeTests`.
8. Browsing the tree never piles up tabs and never drops an edit: a single click replaces only the preview tab, and the first edit keeps it. Pinned by `AppModelTests.aSingleClickReplacesThePreviewTab`, `theFirstEditKeepsThePreview`.

## File structure

```
Sources/RockyKit/Git/DiffParser.swift              new: FileDiff, Hunk, DiffLine, parse
Sources/RockyKit/Git/GitChangesService.swift       new: base, changes, shortstat, commit, discard
Sources/RockyKit/Git/FileWatcher.swift             new: FSEventStream wrapper, the folders of its events
Sources/RockyKit/Files/FileTree.swift              new: FileList, FileEntry, FileTreeRow, rows, rank, matches
Sources/RockyKit/Files/WorktreeFiles.swift         new: ls-files, folder listings
Sources/RockyKit/Files/FileContent.swift           new: text, large text, too large, binary
Sources/RockyKit/Review/CommentAnchor.swift        new
Sources/RockyKit/Review/ReviewPrompt.swift         new
Sources/RockyKit/Edit/EditBuffer.swift             new: clean / dirty / conflict rules
Sources/RockyKit/App/PullRequestActions.swift      RightPanelTab.files, .changes
Sources/RockyKit/Store/Records.swift               DiffCommentRecord, Repo.showsIgnoredFiles
Sources/RockyKit/Store/RockyStore.swift            two migrations (comments, the tree's state), their reads and writes
Sources/RockyKit/App/AppModel.swift                changes, stats, file trees, tabs and previews, comments, review, commit
Sources/RockyUI/Resources/prism-bundle.js          new (vendored)
Sources/RockyUI/SyntaxHighlighter.swift            new
Sources/RockyUI/ChangesTab.swift                   new: the right panel's Changes tab
Sources/RockyUI/FilesTab.swift                     new: the right panel's All files tab
Sources/RockyUI/DiffTabView.swift                  new: diff tabs and unchanged file tabs
Sources/RockyUI/DiffRows.swift                     new: rows, hunk headers, gaps
Sources/RockyUI/CommentViews.swift                 new: composer, cards
Sources/RockyUI/CodeEditor.swift                   new
Sources/RockyUI/CommitSheet.swift                  new
Sources/RockyUI/RightPanel.swift                   three pills with Changes' count, a scroll view per tab
Sources/RockyUI/ChecksTab.swift                    its own scroll view and login note
Sources/RockyUI/FileBadge.swift                    FileKind(path:isDirectory:)
Sources/RockyUI/WorkspaceDetailView.swift          diff tabs, preview tabs, a file opened in an editor
Sources/RockyUI/FileTabView.swift                  editor for code and text, large and binary files
Sources/RockyUI/ChatView.swift                     Esc left to the filter and the composer
Sources/RockyUI/ActivityRows.swift                 badges open diffs and worktree tabs
Sources/RockyUI/SidebarRow.swift                   diff stats
Sources/Rocky/RockyApp.swift                       commands
Tests/RockyKitTests/DiffParserTests.swift          new
Tests/RockyKitTests/GitChangesServiceTests.swift   new
Tests/RockyKitTests/FileWatcherTests.swift         new
Tests/RockyKitTests/FileTreeTests.swift            new
Tests/RockyKitTests/WorktreeFilesTests.swift       new
Tests/RockyKitTests/FileContentTests.swift         new
Tests/RockyKitTests/CommentAnchorTests.swift       new
Tests/RockyKitTests/ReviewPromptTests.swift        new
Tests/RockyKitTests/EditBufferTests.swift          new
Tests/RockyKitTests/RockyStoreTests.swift          both migrations, comments, expanded folders
Tests/RockyKitTests/AppModelTests.swift            changes, file trees, previews, comments, review
docs/README.md                                     the user guide (Spanish)
```

---

### Task 1: Git changes, the diff parser and the watcher

**Requirements:** `GIT-01`, `GIT-02`; the event folders `FIL-07` reads.
**Files:** `Sources/RockyKit/Git/DiffParser.swift`, `Sources/RockyKit/Git/GitChangesService.swift`, `Sources/RockyKit/Git/FileWatcher.swift`, `Tests/RockyKitTests/DiffParserTests.swift`, `Tests/RockyKitTests/GitChangesServiceTests.swift`, `Tests/RockyKitTests/FileWatcherTests.swift`.

```
public struct DiffLine: Equatable, Sendable { enum Kind { context, added, removed }; kind; oldNumber: Int?; newNumber: Int?; text: String }
public struct Hunk: Equatable, Sendable { header: String; oldStart, oldCount, newStart, newCount: Int; lines: [DiffLine]; noNewlineAtEnd: (old: Bool, new: Bool) }
public struct FileDiff: Equatable, Sendable {
  enum Status { added, modified, deleted, renamed(from: String) }
  path: String; status; isBinary: Bool; modeChange: (old: String, new: String)?; hunks: [Hunk]
  additions: Int; deletions: Int; isUncommitted: Bool; isLarge: Bool
}
public struct WorkspaceChanges: Equatable, Sendable { base: String; files: [FileDiff]; additions: Int; deletions: Int }
public enum DiffParser { public static func parse(_ output: String) -> [FileDiff] }
public struct GitChangesService: Sendable {                      // synchronous; callers use Task.blocking
  public init(environment: [String: String])
  public func base(worktree: URL, baseRef: String?) throws -> String
  public func shortstat(worktree: URL, base: String) throws -> (additions: Int, deletions: Int)
  public func changes(worktree: URL, base: String) throws -> WorkspaceChanges
}
public struct FolderEvents: Equatable, Sendable { folders: Set<String>; subtrees: Set<String> }   // absolute paths
public final class FileWatcher: Sendable {
  init(paths: [URL], excluding: [String], debounce: Duration, onChange: @escaping @Sendable (FolderEvents) -> Void)
  func stop()
}
```

It must:
- Follow `GIT-01` exactly: merge-base, `git diff … <base>`, untracked files read and shown as added, uncommitted flags from `git status --porcelain=v1 -z`, the nil-`baseRef` fallback, and the busy check. Reads run as `git --no-optional-locks`.
- `FileWatcher` watches the worktree and its git directory (resolved from the worktree's `.git` file), excludes `node_modules` and `.git/objects`, and debounces 500 ms.
- Report the folders of the events coalesced over the debounce (FSEvents' directory-level paths), for `FIL-07`. An event flagged `MustScanSubDirs`, or dropped events, reports its folder in `subtrees`. The watched paths are resolved once (`/var/…` arrives as `/private/var/…`), so consumers compare like with like.
- Mark a file `isLarge` over 1,500 changed lines or 1 MB (DIFF-03).

Tests:
- `DiffParserTests`: modified with two hunks; added; deleted; renamed with similarity; binary; mode only; `\ No newline at end of file` on each side.
- `GitChangesServiceTests` (`.blockingWork`) on temporary repositories: committed + staged + unstaged + untracked all appear; the base is the merge-base after the base branch moves; nil `baseRef` falls back to `origin/HEAD`'s branch; shortstat matches the parsed totals.
- `FileWatcherTests.reportsTheFolderOfANewFile`: a file created in a subfolder of a temporary directory reports that folder, resolved, within 3 s.

Commit `feat(kit): compute workspace changes against their base`.

### Task 2: Sidebar stats and the Changes tab

**Requirements:** `GIT-03`, `CHG-01`, `CHG-02`.
**Files:** `Sources/RockyKit/App/AppModel.swift`, `Sources/RockyKit/App/PullRequestActions.swift`, `Sources/RockyUI/ChangesTab.swift` (new), `Sources/RockyUI/RightPanel.swift`, `Sources/RockyUI/ChecksTab.swift`, `Sources/RockyUI/SidebarRow.swift`, `Tests/RockyKitTests/AppModelTests.swift`.

```
RightPanelTab: case changes, checks                                               // Task 12 adds .files before .changes
AppModel
  public private(set) var diffStats: [String: (additions: Int, deletions: Int)]   // every workspace, from shortstat
  public private(set) var changes: [String: WorkspaceChanges]                     // selected workspace, while it shows them
  public var visibleRightPanelTab: RightPanelTab?                                 // set by RightPanel: its tab while the panel shows, else nil
  public func refreshChanges(workspaceId: String) async
```

It must:
- Start one `FileWatcher` per workspace when the model loads and stop it when the workspace is removed. A change refreshes that workspace's `diffStats`. It refreshes `changes` too when that workspace is selected and shows them: here while `visibleRightPanelTab` is `.changes`; Task 4 adds its diff tabs on screen, Task 12 the All files tab.
- The sidebar row shows the stats per `GIT-03` (M2.5's reserved trailing slot).
- Add `RightPanelTab.changes` ("Changes") before `.checks` (`CHG-01`), and ⌘⇧C: show the panel on this tab, or hide the panel if this tab already shows. No top bar control and no panel of its own: width, divider and open state are M2.7's. With two cases, M2.7's `RightPanelTabRow` draws its pills again and its one-tab title goes away. `RightPanelTabButton` gains the count: 11 mono `textTertiary`, hidden at 0.
- Adapt `RightPanel` to more than one tab:
  - Its one `ScrollView` moves into each tab, so CHG-02's comments bar (and Task 12's filter head) stay put while the list scrolls.
  - `GitHubLoginNote` shows on Checks only.
  - REV-01's comments are read while `visibleRightPanelTab == .checks`, not whenever the panel appears. `AppModel` forwards the change to `pullRequests.setCommentsVisible`.
  - A workspace that never picked a tab shows Changes (Decisions).
- The tab's content per `CHG-02`: the 30 pt row with the file count, totals and "⋯", the file list, and the comments bar pinned at the bottom.

Tests: `AppModelTests.fileChangeRefreshesTheSidebarStats` (inject the watcher), `hiddenChangesTabDoesNotComputeTheFullDiff`, `commentsAreReadOnlyWhileTheChecksTabShows`.

Commit `feat(ui): add the changes tab and sidebar diff stats`.

### Task 3: File list and discard

**Requirements:** `CHG-03`, `GIT-05`.
**Files:** `Sources/RockyUI/ChangesTab.swift`, `Sources/RockyKit/Git/GitChangesService.swift`, `Tests/RockyKitTests/GitChangesServiceTests.swift`.

```
GitChangesService
  public func discard(worktree: URL, path: String, isUntracked: Bool) throws   // restore, or recycle to the Trash
```

It must:
- Build the Uncommitted and Committed sections, rows, hover actions and empty state from `CHG-03`; ⌥⌘↓ / ⌥⌘↑ move between files.
- Discard per `GIT-05`, with its confirmation, closing the file's diff tab.

Tests: `GitChangesServiceTests.discardRestoresATrackedFile`, `discardMovesAnUntrackedFileToTheTrash` (inject the recycle step), `discardRefusesACommittedOnlyFile`.

Commit `feat(ui): list changed files and discard uncommitted ones`.

### Task 4: Diff tabs and the unified diff

**Requirements:** `DIFF-01`, `DIFF-02`, `DIFF-03`, `DIFF-05`.
**Files:** `Sources/RockyUI/DiffTabView.swift` (new), `Sources/RockyUI/DiffRows.swift` (new), `Sources/RockyUI/WorkspaceDetailView.swift`, `Sources/RockyUI/ActivityRows.swift`, `Sources/RockyKit/App/AppModel.swift`.

```
AppModel
  public private(set) var diffTabs: [String: [String]]          // workspace id → worktree-relative paths, in tab order
  public func openDiff(workspaceId: String, path: String, mode: DiffTabMode = .diff)
  public func closeDiff(workspaceId: String, path: String)
enum DiffTabMode { case diff, edit }
```

It must:
- Add diff tabs after conversations and file tabs, with the status letter, dirty dot and close rules of `DIFF-01`; the header with the Diff | Edit control and "⋯" menu.
- Render `DIFF-02`: fixed 20 pt rows in a `LazyVStack`, both number columns, markers, the diff tokens, hunk headers, collapsed unchanged runs that expand, horizontal scrolling with sticky number columns.
- Handle every case of `DIFF-03`.
- Tool call badges of files present in `changes` open their diff tab (`DIFF-05`).
- Keep `changes` computed while one of the selected workspace's diff tabs is on screen (Task 2's rule), so an open diff follows the agent with the panel on Checks or closed.
- Keep M2.5's rules for tabs (`TAB-01`), zoom and the pointing hand. Task 13 opens unchanged files in these same tabs.

Commit `feat(ui): show a workspace's changes as unified diffs in tabs`.

### Task 5: Syntax highlighting

**Requirements:** `DIFF-04`, `TOK-10`.
**Files:** `Sources/RockyUI/Resources/prism-bundle.js` (new), `Sources/RockyUI/SyntaxHighlighter.swift` (new), `Sources/RockyUI/Theme.swift`, `Package.swift` (resource), `README.md`.

```
actor SyntaxHighlighter {
  static let shared: SyntaxHighlighter
  func tokens(for text: String, language: String) -> [SyntaxToken]      // cached by content hash
  static func language(forPath: String) -> String?
}
struct SyntaxToken: Sendable { range: Range<Int>; kind: SyntaxKind }    // keyword, string, number, comment, function, type, plain
```

It must:
- Vendor a Prism build with at least: TypeScript, JavaScript, TSX, JSX, JSON, Swift, Python, Go, Rust, CSS, HTML, YAML, TOML, Bash, Markdown, SQL. Record its version and license.
- Run it in a `JSContext` off the main thread; plain text until tokens arrive; unknown language → plain.
- Add the `TOK-10` tokens to `Theme` (diff fills, `commentRange`, `currentLine`, `syntax`); `merged` is M2.7's already.

Commit `feat(ui): highlight code with a vendored prism bundle`.

### Task 6: Comment storage and anchoring

**Requirements:** `CMT-03`, `CMT-04`.
**Files:** `Sources/RockyKit/Store/Records.swift`, `Sources/RockyKit/Store/RockyStore.swift`, `Sources/RockyKit/Review/CommentAnchor.swift` (new), `Tests/RockyKitTests/RockyStoreTests.swift`, `Tests/RockyKitTests/CommentAnchorTests.swift` (new).

```
public struct DiffCommentRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  id, workspaceId, path, side ("new" | "old"), startLine, endLine, snippet, contextBefore, contextAfter, body,
  state ("pending" | "sent" | "outdated"), createdAt, sentAt?
}
// In the next free migration (read the latest name in RockyStore.migrator first).
RockyStore: comments(workspaceId:), saveComment(_:), deleteComment(id:); removing a workspace deletes its comments
public enum CommentAnchor { public static func relocate(snippet: [String], start: Int, in lines: [String]) -> ClosedRange<Int>? }
```

It must: run `relocate` on every refresh of a file's changes (`CMT-04`), moving comments or marking them Outdated, and persist the result.

Tests:
- `CommentAnchorTests`: unchanged → same range; lines inserted above → shifted; a commented line edited → nil; the snippet twice → the nearest match; the snippet at the end of the file.
- `RockyStoreTests.commentsMigrationCreatesTheTable`, `removingAWorkspaceRemovesItsComments`.

Commit `feat(kit): store review comments and keep them on their lines`.

### Task 7: Comment UI

**Requirements:** `CMT-01`, `CMT-02`.
**Files:** `Sources/RockyUI/CommentViews.swift` (new), `Sources/RockyUI/DiffRows.swift`, `Sources/RockyUI/ChangesTab.swift`.

It must:
- The hover "+", click, drag across rows or numbers, Shift-click ranges, one side per range, Esc, and the range fill (`CMT-01`).
- The composer under the range with ⌘Return, and cards with state chips, edit and delete (`CMT-02`). Outdated comments collapsed at the top of the file's diff.
- Comment counts on the Changes tab's file rows.

Commit `feat(ui): comment on diff line ranges`.

### Task 8: Send comments to the agent

**Requirements:** `CMT-05`.
**Files:** `Sources/RockyKit/Review/ReviewPrompt.swift` (new), `Sources/RockyKit/App/AppModel.swift`, `Sources/RockyUI/ChangesTab.swift`, `Tests/RockyKitTests/ReviewPromptTests.swift` (new), `Tests/RockyKitTests/AppModelTests.swift`.

```
public enum ReviewPrompt { public static func build(branch: String, comments: [DiffCommentRecord], language: (String) -> String?) -> String }
AppModel: public func sendReview(workspaceId: String) async      // selected conversation; starts its agent if needed
```

It must: build the exact text of `CMT-05`, send it as one prompt to the workspace's selected conversation, switch the workspace to that conversation's tab, and mark the comments Sent. The button is disabled while a turn runs.

Tests: `ReviewPromptTests.formatForOneAndSeveralComments` (exact text, including a removed-side comment); `AppModelTests.sendReviewMarksCommentsSent` (fake agent).

Commit `feat(app): send review comments to the agent`.

### Task 9: Code editor

**Requirements:** `EDIT-01`, `EDIT-04`.
**Files:** `Sources/RockyUI/CodeEditor.swift` (new), `Sources/RockyUI/DiffTabView.swift`, `Sources/RockyUI/FileTabView.swift`.

```
struct CodeEditor: NSViewRepresentable {
  @Binding var text: String
  let language: String?
  let baseText: String?          // for the change bars; nil hides them
  var goToLine: Int?
  var isEditable: Bool = true    // false for FIL-06's large files
}
```

It must:
- `NSTextView` in an `NSScrollView` with an `NSRulerView` subclass for line numbers and change bars; current-line fill; highlighting from Task 5, re-tokenized 150 ms after typing, visible range first; system find bar; ⌘L go to line; Tab inserts the detected indentation; substitutions and spell check off; no wrap.
- Be the Edit mode of diff tabs and the view of code, data and text file tabs; Markdown file tabs get Preview | Edit; files over 2 MB stay read-only (Task 15 refines it per `FIL-06`).
- Change bars against the base (`EDIT-04`), updated as the text changes.

Commit `feat(ui): edit files in a code editor`.

### Task 10: Saving and changes on disk

**Requirements:** `EDIT-02`, `EDIT-03`.
**Files:** `Sources/RockyKit/Edit/EditBuffer.swift` (new), `Sources/RockyUI/DiffTabView.swift`, `Sources/RockyUI/FileTabView.swift`, `Tests/RockyKitTests/EditBufferTests.swift` (new).

```
public struct EditBuffer: Equatable, Sendable {
  public var text: String
  public private(set) var loaded: String            // what was on disk when loaded or last saved
  public private(set) var loadedStamp: FileStamp     // modification date + content hash
  public private(set) var conflict: Bool
  public private(set) var keepMine: Bool
  public var isDirty: Bool
  public mutating func diskChanged(to: String, stamp: FileStamp) -> DiskChangeOutcome   // .reloaded | .conflict | .none
  public mutating func reload(), keepMine()
  public func canSave(current: FileStamp) -> Bool
  public mutating func saved(stamp: FileStamp)
}
```

It must:
- ⌘S / Save writes atomically, keeping line endings and the final newline (`EDIT-02`); the tab dot, "Edited", the unsaved banner in Diff mode, the Save / Don't Save / Cancel prompt on close.
- Save a symlink at its target, so the atomic write never replaces the link with a copy. `WorktreeLinker`'s `.env` links are symlinks, and the tree opens them with Show Ignored Files (Task 12).
- React to disk changes per `EDIT-03` (FSEvents from Task 1): silent reload with "Reloaded", or the conflict banner; saving checks the stamp; the agent-working banner.

Tests in `EditBufferTests`: clean buffer reloads; dirty buffer conflicts; Reload drops edits; Keep Mine lets the next save through; a stale stamp blocks the save without Keep Mine; saving clears the dirty state.

Commit `feat(ui): save edits safely while the agent works`.

### Task 11: The worktree's file list and tree

**Requirements:** `FIL-07` (Kit); from `FIL-02` the order and deleted files, from `FIL-03` the ignored rule, from `FIL-04` the source and the ranking.
**Files:** `Sources/RockyKit/Files/FileTree.swift` (new), `Sources/RockyKit/Files/WorktreeFiles.swift` (new), `Tests/RockyKitTests/FileTreeTests.swift` (new), `Tests/RockyKitTests/WorktreeFilesTests.swift` (new).

```
public struct FileEntry: Equatable, Sendable { public let name: String; public let isDirectory: Bool }   // one item of a folder's listing
public struct FileList: Equatable, Sendable {                  // FIL-04's source
  public init(listed: [String], deleted: [String])             // worktree-relative paths from ls-files
  public let paths: [String]                                   // listed minus deleted, in Finder's order, sorted once
  public func isIgnored(_ path: String) -> Bool                // neither listed nor the parent of a listed path
}
public struct FileTreeRow: Equatable, Sendable, Identifiable {  // id: path
  public let path: String; name: String; depth: Int; isDirectory: Bool; isExpanded: Bool; isIgnored: Bool
}
public enum FileTree {
  public static func rows(listings: [String: [FileEntry]], expanded: Set<String>, list: FileList, showsIgnored: Bool) -> [FileTreeRow]   // "" is the root
  public static func rank(_ query: String, in list: FileList) -> [String]
  public static func matches(_ query: String, in path: String) -> [Range<String.Index>]   // the accent, per drawn row
  public static func invalidated(by events: FolderEvents, worktree: String) -> (folders: Set<String>, subtrees: Set<String>)   // relative
  public static func ancestors(of path: String) -> [String]                                // "src/a/b.ts" → ["src", "src/a"]
}
public struct WorktreeFiles: Sendable {                         // synchronous; callers use Task.blocking
  public init(environment: [String: String])
  public func list(worktree: URL) throws -> FileList            // ls-files --cached --others --exclude-standard -z, and --deleted -z
  public func listing(worktree: URL, folder: String) throws -> [FileEntry]   // contentsOfDirectory; never .git
}
```

It must:
- `rows`: folders first, then files, each by `localizedStandardCompare` ("file2" before "file10"). A folder's children show only when it is expanded and its listing is loaded. Ignored entries (`list.isIgnored`) are left out, unless `showsIgnored` keeps them flagged. `.git` never shows, and tracked dotfiles show like any file (`FIL-02`, `FIL-03`).
- `rank` per `FIL-04`'s five ranks, case-insensitive over the relative path, ties in the list's order. It is one pass over `paths`, with no locale-aware comparison. Ignored files are never in the list, so they are never ranked.
- `matches` gives the characters to draw in `accent` for one path. The view asks only for the rows it draws, never for all results.
- `invalidated` maps event folders to worktree-relative listings. Paths outside the worktree (its git directory) invalidate nothing.
- `WorktreeFiles` runs both `ls-files` through `ProcessRunner` in the worktree with the workspace environment. A symlink lists as its target's kind (`WorktreeLinker`'s `.env` links are files), and a broken link lists as a file.

Tests:
- `FileTreeTests`:
  - `foldersFirstThenFilesInFindersOrder`.
  - `ignoredEntriesAreHiddenUnlessShown`: the ignored rule, a tracked dotfile, `.git`.
  - `anEmptyFolderCountsAsIgnored` (git lists no folder).
  - `aDeletedFileIsAbsent`: from `paths`, `rank` and `rows`.
  - `rankFollowsFIL04`, with "srv" finding `server.ts`.
  - `rankTiesKeepFindersOrder`.
  - `ranks100000PathsInUnder50ms`: a generated list, timing `rank` alone.
  - `anEventInvalidatesOnlyItsFolder`, `eventsOutsideTheWorktreeInvalidateNothing`.
- `WorktreeFilesTests` (`.blockingWork`) on temporary repositories: `listHasTrackedAndUntrackedButNotIgnored`, `listLeavesOutFilesDeletedFromDisk`, `listingNeverShowsGit`.

Commit `feat(kit): list a worktree's files and rank them for the filter`.

### Task 12: The All files tab

**Requirements:** `FIL-01`, `FIL-02`, `FIL-03`, `FIL-07`.
**Files:** `Sources/RockyUI/FilesTab.swift` (new), `Sources/RockyUI/RightPanel.swift`, `Sources/RockyUI/FileBadge.swift`, `Sources/RockyKit/App/PullRequestActions.swift`, `Sources/RockyKit/App/AppModel.swift`, `Sources/RockyKit/Store/Records.swift`, `Sources/RockyKit/Store/RockyStore.swift`, `Tests/RockyKitTests/RockyStoreTests.swift`, `Tests/RockyKitTests/AppModelTests.swift`.

```
RightPanelTab: case files, changes, checks                        // "All files" first (FIL-01)
public struct FileTreeState: Equatable, Sendable { list: FileList?; listings: [String: [FileEntry]]; expanded: Set<String> }
AppModel
  public private(set) var fileTrees: [String: FileTreeState]      // selected workspace, filled while All files shows
  public func setFolder(_ path: String, expanded: Bool, workspaceId: String)
  public func collapseAllFolders(workspaceId: String)
  public func setShowsIgnoredFiles(_ shows: Bool, repoId: String)
Repo: public var showsIgnoredFiles: Bool
// In the next free migration (read the latest name in RockyStore.migrator first):
//   table expandedFolder (workspaceId → workspace, on delete cascade; path; the two are the key), column repo.showsIgnoredFiles (false)
RockyStore: expandedFolders(workspaceId:), setExpandedFolders(_:workspaceId:), setShowsIgnoredFiles(_:repoId:)   // column-only
FileKind (RockyUI): init(path: String, isDirectory: Bool)         // no disk check
```

It must:
- Add `RightPanelTab.files` ("All files") before `.changes`. The row then shows `CHG-01`'s three pills.
- `FIL-01`'s tab has a 38 pt head and the tree:
  - The head holds the filter field (its behavior is Task 14's) and "⋯": Show Ignored Files (`isChecked`), Collapse All Folders, and Reveal Active File (Task 13; disabled without a worktree tab on screen). The menu has no icons.
  - The tree is a `LazyVStack` of fixed 26 pt rows in its own `ScrollView`. No footer of its own: M2.7's `RightPanelFooter` stays under it.
- Rows per `FIL-02`:
  - Indent and chevron, which turns in `Theme.Motion.hover` and stays still with Reduce Motion.
  - The icon comes from `FileKind(path:isDirectory:)`. The row already knows whether it is a folder, and `FileKind(path:)` would check the disk once per row drawn.
  - Status letters and folder dots come from `changes`. Deleted files are not in the tree, so they mark no folder, as in the mock.
  - Hover and selection: the selected row is the path of the worktree tab on screen.
  - The accessibility outline labels.
  - Keys: ↑ / ↓ move, → expands, ← collapses or goes to the parent (`KBD-02`); Return is Task 13's.
- Ignored entries per `FIL-03`: hidden, or dimmed (name `textTertiary`, icon at 50 %) with Show Ignored Files, stored per repository.
- Expanded folders are stored per workspace and go with it. The first time, only the top level shows. Collapse All Folders empties the set.
- Read the disk per `FIL-07`, through `Task.blocking`:
  - A folder's listing (`WorktreeFiles.listing`) is read when it expands and cached in `fileTrees` until an event names it.
  - The workspace's watcher (Task 2) feeds `FileTree.invalidated`. Only the expanded folders it names are read again; a collapsed folder is only dropped from the cache.
  - `WorktreeFiles.list` runs when the tab first shows, and after each event batch while it shows. The watcher's 500 ms debounce is `FIL-07`'s. Never on a timer.
  - Events while the tab is hidden only mark the list and the named folders stale, with no read and no process. Showing the tab again reads what is stale.
  - Workspaces that are not selected keep nothing and run nothing.
- Keep `changes` computed while All files shows (Task 2's rule).

Tests:
- `RockyStoreTests.treeStateMigrationAddsItsTableAndColumn` (a database at the previous migration opens, migrates, keeps its rows), `expandedFoldersRoundTripAndGoWithTheWorkspace`.
- `AppModelTests`, with the watcher and `WorktreeFiles` injected: `hiddenFilesTabRunsNoGit`, `anEventReReadsOnlyTheExpandedFolderItNames`, `eventsWhileHiddenAreReadWhenTheTabShows`, `expandedFoldersSurviveRelaunch`, `showIgnoredFilesIsRememberedPerRepository`.

Commit `feat(ui): add the all files tab with the worktree's tree`.

### Task 13: Opening files and preview tabs

**Requirements:** `FIL-05`.
**Files:** `Sources/RockyKit/App/AppModel.swift`, `Sources/RockyUI/FilesTab.swift`, `Sources/RockyUI/DiffTabView.swift`, `Sources/RockyUI/WorkspaceDetailView.swift`, `Sources/RockyUI/ActivityRows.swift`, `Tests/RockyKitTests/AppModelTests.swift`.

```
AppModel
  public private(set) var previewTabs: [String: String]                    // workspace id → its one preview tab's path
  public func openFromTree(workspaceId: String, path: String, keep: Bool)   // single click, Return: false; double-click: true
  public func keepPreview(workspaceId: String)                             // a double-click on the tab, or the first edit
  public func reveal(workspaceId: String, path: String)                    // All files, the file's folders expanded
  public private(set) var revealedPaths: [String: String]                  // FilesTab scrolls that row into view
```

It must:
- Open a file in Changes as its diff tab in Diff mode, or select that tab if it is open (`FIL-05`).
- Open any other file in the same tab kind, in Edit, its only mode. Its header shows the path and "Unchanged" (11 `textTertiary`) instead of Diff | Edit. The tab shows the file's `FileKind` icon instead of a status letter.
- When `changes` gains the path (your save, or the agent), the tab gains the status letter and Diff | Edit and stays in Edit.
- Preview tabs:
  - A single click on a tree row, or Return, opens the workspace's one preview tab or replaces it. `WorkspaceTab` gains an italic title for it.
  - A double-click on the row, a double-click on the tab, or the first edit keeps it.
  - A kept tab is never replaced. The Changes tab and badges keep opening regular tabs.
- One handler per row and per tab reads the click count (`NSEvent.clickCount`). A count-2 tap gesture next to a count-1 one would hold every single click for the double-click interval.
- Add "Reveal in All Files" to the "⋯" menus of diff and file tabs; the tree's Reveal Active File does the same. It shows the panel on All files, clears the filter, expands `FileTree.ancestors` (stored) and scrolls the row into view.
- Route a badge's file inside the worktree to its worktree tab, resolving the absolute path the way the worktree's own path is resolved. Files outside the worktree keep `openFiles` (Decisions).

Tests: `AppModelTests.aSingleClickReplacesThePreviewTab`, `aDoubleClickKeepsThePreview`, `theFirstEditKeepsThePreview`, `aChangedFileOpensInDiffAndAnUnchangedOneInEdit`, `aBadgeInsideTheWorktreeOpensItsWorktreeTab`, `revealExpandsTheFilesFolders`.

Commit `feat(ui): open any worktree file from the tree in a preview tab`.

### Task 14: Filter and Go to File

**Requirements:** `FIL-04`.
**Files:** `Sources/RockyUI/FilesTab.swift`, `Sources/RockyUI/ChatView.swift`, `Sources/RockyKit/App/AppModel.swift`, `Tests/RockyKitTests/AppModelTests.swift`.

```
AppModel
  public func goToFile(workspaceId: String)            // All files selected; FilesTab focuses its field and selects its text
  public private(set) var goToFileRequests: Int         // FilesTab reacts when it changes
```

It must:
- The filter field of `FIL-01`'s head: 26 pt, radius 6, `fillControl`, "Filter files", the "⌘P" hint at its right end.
- Typing replaces the tree with a flat list of matches (icon, name, directory in 11 `textTertiary`, status letter), ranked by `FileTree.rank`. Rank off the main actor; the latest query wins. Matched characters are in `accent` (`FileTree.matches`). No match shows "No file matches “query”", as in the mock. An empty query brings back the tree as it was: expanded set and scroll position.
- Keys per `FIL-04`: ↓ / ↑ move through the results, Return opens (Task 13, as a preview), Esc clears the query, and a second Esc leaves the field.
- `ChatView.handleKey` lets Esc through while the filter field has focus. It takes Esc anywhere in the key window while a turn runs, and would stop the agent's turn instead. Read the focus through a reference, since the monitor keeps the view as it was when it was added (`CLAUDE.md`).
- Go to File per `FIL-04`: the panel opens on All files with the field focused and its text selected. The command is Task 17's.

Tests: `AppModelTests.goToFileSelectsTheAllFilesTab`.

Commit `feat(ui): filter the worktree's files and go to a file`.

### Task 15: Large and binary files

**Requirements:** `FIL-06`.
**Files:** `Sources/RockyKit/Files/FileContent.swift` (new), `Sources/RockyUI/DiffTabView.swift`, `Sources/RockyUI/FileTabView.swift`, `Sources/RockyUI/WorkspaceDetailView.swift`, `Tests/RockyKitTests/FileContentTests.swift` (new).

```
public enum FileContent: Equatable, Sendable {
  case text, largeText, tooLarge, binary                 // up to 2 MB, 2–20 MB, over 20 MB, a NUL in the first 8 KB
  public static let editableLimit = 2_000_000, readableLimit = 20_000_000, sniffLength = 8_192
  public static func classify(size: Int, head: Data) -> FileContent
}
```

It must:
- Read the size from the file's attributes before anything else. Over 20 MB, read nothing. Otherwise read the first 8 KB to classify, and the whole file only for text.
- Show images and PDFs first, by `FileKind`, with today's `FileTabView` content: the image view, and Quick Look for PDFs.
- Draw each case of `FIL-06`'s table:
  - Text up to 2 MB: the editor.
  - Text of 2–20 MB: the read-only editor, in plain text (Decisions), with the banner "Large file · 3.4 MB · read-only in Rocky".
  - Over 20 MB: "Too large to open in Rocky · 48 MB", with Open in Finder and one button per installed editor (`ExternalEditor.installed`). Those buttons open the file, not the worktree: `openWorktree(in:app:)` becomes a shared opener of a URL, with its toast on failure.
  - Other binary: "Binary file · 112 KB" and Open in Finder.
- Apply the same rules to worktree tabs and to badge file tabs, so a file looks the same whatever opened it.

Tests: `FileContentTests.followsTheTableAtItsLimits` (2 MB and 20 MB exactly and one byte over), `aNULInTheFirst8KBIsBinary`, `aNULAfter8KBIsText`.

Commit `feat(ui): show large and binary files without loading them whole`.

### Task 16: Commit

**Requirements:** `GIT-04`, `ERR-02`.
**Files:** `Sources/RockyUI/CommitSheet.swift` (new), `Sources/RockyKit/Git/GitChangesService.swift`, `Sources/RockyKit/App/AppModel.swift`, `Tests/RockyKitTests/GitChangesServiceTests.swift`.

```
GitChangesService: public func commit(worktree: URL, subject: String, description: String?, environment: [String: String], output: @Sendable (String) -> Void) async throws
```

It must: open the sheet from the Uncommitted header of the Changes tab; run `git add -A` and `git commit` with the workspace environment; stream hook output; keep the sheet open with the output and exit code on failure (`GIT-04`). Every git failure in M3 (diff, commit, discard) shows its last stderr lines where the action was (`ERR-02`).

Tests: `GitChangesServiceTests.commitIncludesUntrackedFiles`, `failingHookReportsItsOutput`.

Commit `feat(ui): commit a workspace's changes`.

### Task 17: Keyboard commands

**Requirements:** `KBD-02`.
**Files:** `Sources/Rocky/RockyApp.swift`, `Sources/RockyUI/ChangesTab.swift`, `Sources/RockyUI/FilesTab.swift`, `Sources/RockyUI/CodeEditor.swift`, `Sources/RockyUI/ChatView.swift`.

It must:
- Add these as commands:
  - ⌘⇧C, the right panel on its Changes tab.
  - ⌘P, File ▸ Go to File…, which opens the panel through `RightPanelStorage.openKey` as `PullRequestPanelCommand` does.
  - ⌥⌘↓ / ⌥⌘↑, ⌘S and ⌘L.
- Keep the other keys local: ⌘F is the system find bar, and ⌘Return, Esc and the tree's arrows and Return belong to their views.
- Check that none collides with M2, M2.5, M2.6 and M2.7 shortcuts. M2.7 has ⌥⌘B and ⌃⌘S, and dropped ⌘⇧G because it is Edit ▸ Find ▸ Find Previous.
- Give Esc this order: an open menu, the settings panels, a sheet, the comment composer, the filter field, then the agent's turn (M2.5). `ChatView.handleKey` skips while the composer or the filter has focus.

Commit `feat(app): add review, file and editor keyboard commands`.

### Task 18: Build, tests and verification

1. `swift build` and `swift test`. Fix and rerun until green.
2. `scripts/make-app.sh`, `open build/Rocky.app`, then the manual checklist with the HTML open next to the app.
3. Energy: with five workspaces open, the All files tab showing, and nothing happening for 10 minutes, Rocky starts no process (Activity Monitor or `CurrentPowerlog.PLSQL`).
4. Update `docs/README.md` (Spanish) for the All files tab, the Changes tab, diff and file tabs, comments, the editor, commit and the new shortcuts, and move its "Última actualización" date (`CLAUDE.md`).
5. Merge `feat/m3-review-edit-files` into `development` only with the user's approval.

Manual checklist (on a personal repository):
1. Let an agent change files: the sidebar stats and the Changes tab update within a second; nothing runs while idle (`GIT-01`, `GIT-03`). ⌘⇧C and the three pills switch between All files, Changes and Checks; "Changes N" hides its count at 0; the Checks tab's comments load only while it shows (`CHG-01`).
2. Open each kind of file: modified, new, deleted, renamed, binary, a large lockfile (`DIFF-01`…`DIFF-03`); highlighting in TypeScript and Swift (`DIFF-04`); a tool badge opens the diff (`DIFF-05`).
3. Comment on one line, on a range by dragging, on a range by Shift-click, on a removed line; edit and delete; relaunch and see them (`CMT-01`…`CMT-03`).
4. Send to agent: the conversation receives the exact prompt; comments turn Sent; when the agent edits those lines they turn Outdated, when it inserts lines above they move (`CMT-04`, `CMT-05`).
5. Edit and save; undo past the save; find; go to line; the change bars follow (`EDIT-01`, `EDIT-02`, `EDIT-04`).
6. Edit without saving while the agent changes the same file: the banner; Reload and Keep Mine both behave (`EDIT-03`).
7. Discard a tracked file and an untracked one (it is in the Trash) (`GIT-05`); commit with a failing hook, then a passing one (`GIT-04`).
8. A failing git command (a commit hook, a discard on a locked index) shows its stderr where the action was (`ERR-02`).
9. All files:
   - The order ("file2" before "file10"), icons, status letters and folder dots.
   - Expand folders, relaunch, and see the same ones; Collapse All Folders.
   - Show Ignored Files dims `node_modules` and the linked `.env` files, and is remembered per repository.
   - `.git` never shows.
   - The tree's arrow keys.
   - (`FIL-01`…`FIL-03`, `KBD-02`)
10. The filter and Go to File:
    - "srv" finds `server.ts`; the ranks and the accent characters.
    - ↓ / ↑ and Return; Esc twice.
    - ⌘P from the message box and from a terminal, with the panel closed.
    - With an agent working, Esc in the filter clears it and does not stop the turn.
    - (`FIL-04`, `KBD-02`)
11. Opening files:
    - A single click opens an italic preview that the next click replaces; a double-click on the row or the tab, or an edit, keeps it.
    - An unchanged file shows "Unchanged" and Edit only; save a change and it joins Changes with its letter and Diff | Edit, still in Edit.
    - Reveal in All Files.
    - A badge of an unchanged worktree file opens the same tab.
    - Saving a linked `.env` keeps it a symlink (`ls -l` in the worktree).
    - (`FIL-05`, `EDIT-02`)
12. Large and binary files: a 5 MB log opens read-only with its banner; a 30 MB file is not loaded and opens in Finder and in an installed editor; an unknown binary; an image; a PDF (`FIL-06`).
13. A big repository (a personal one with a large tree, or 100,000 generated files): the tab opens at once; typing in the filter stays fluent; with the tab showing and nothing happening, no process runs; `ls-files` runs only after a change (`FIL-07`).

## Known risks

- **M2.7's names** were checked against its code on 2026-09-24 (Preconditions). If its last changes before merging move them, adapt Tasks 2 and 12 and record it below.
- **Diff performance:** if the `LazyVStack` of fixed rows stutters on large diffs, or its scroll bar jumps like the chat's did, switch the diff body to an `NSTableView` behind an `NSViewRepresentable`, keeping comment cards as expanding rows. The same fallback holds for the tree, with an `NSOutlineView`.
- **Tree performance on big repositories:**
  - `ls-files` on 100,000 files prints megabytes, and runs after every debounced event while the tab shows. A build writing `dist/` there runs it every 500 ms. If Activity Monitor shows it, exclude the repository's biggest ignored top-level folders from the stream, which takes up to 8 exclusion paths.
  - The 50 ms of `ranks100000PathsInUnder50ms` is measured in `swift test`'s debug build. If `rank` misses it only there, measure a release build and record it; do not raise the bound silently.
- **`NSRulerView` and highlighting** in a large file: highlight the visible range first; if typing lags past 5,000 lines, highlight only the visible range.
- **FSEvents on the worktree's git directory:** the worktree's `.git` is a file; resolve it once, and re-resolve if the worktree moves.
- **FSEvents paths are canonical:** a worktree under `/var` gets events under `/private/var`. `FileWatcher` resolves its paths, and a badge's path is resolved the same way before it is matched to the worktree; otherwise nothing refreshes and badges miss their tabs.
- **Excluded folders get no events:** with Show Ignored Files, an expanded `node_modules` never hears about its changes. Read its listing again each time it expands instead of caching it.
- **A new file appears after the next `ls-files`,** up to about a second: until the list has it, the ignored rule counts it as ignored. Accepted.
- **The file tab kept in preview:**
  - A preview stays a preview when its file joins Changes, so the next click in the tree replaces a tab the agent just changed. Changes still lists the file.
  - The first edit keeps the tab, so a preview never holds unsaved edits and never asks Save / Don't Save.
  - If users lose tabs they meant to keep, the rule is the user's to change (Decisions).
- **Text that is not UTF-8** (Latin 1) has no NUL byte but does not decode. It shows `FIL-06`'s "Binary file" with Open in Finder. If real repositories hit it, record it and ask the designer.
- **A linked `.env` changes outside the worktree:** its target is in the main clone, which the workspace's stream does not watch, so `EDIT-03`'s reload misses changes made there. Accepted.
- **The panel's name:** View ▸ Show Pull Request Panel (⌥⌘B) and the toggle's tooltips name a panel that now holds files and changes too. M3 keeps M2.7's words; renaming is the user's call.
- **The agent and the editor on the same file** stay a race in the worst case (the agent writes between your save's stamp check and the write). The stamp check makes it rare, not impossible.

## Changes during implementation

Record here anything that differs from this plan, with the date and the reason.

- **2026-09-24, Tasks 1–3: interfaces as built.**
  - The plan's tuples are small structs with the same member names, so the types stay `Equatable`:
    `Hunk.noNewlineAtEnd` is `NoNewlineAtEnd(old:new:)`, `FileDiff.modeChange` is `ModeChange(old:new:)` (git's modes,
    "100644"), and `shortstat` returns `DiffStat(additions:deletions:files:)`, which `AppModel.diffStats` holds too.
    `DiffStat.files` is the number of changed files: `CHG-01`'s "Changes N" shows it while the Changes tab is hidden and
    `changes` is not computed.
  - Added to the parser's types: `FileDiff.isUntracked` (GIT-05 needs it), `oldPath`, `Status.letter`;
    `WorkspaceChanges.uncommitted`, `committed`, `listOrder` (Uncommitted first), `file(at:)`, `file(after:step:)`
    (⌥⌘↓ / ⌥⌘↑), `stat`; `DiffStat.abbreviated(_:)` ("2.3k"). `Hunk.header` is the whole `@@` line, with git's
    function context. The parser reads a hunk by its counts (a context line that lost its space still counts), splits
    on the newline byte (Swift reads "\r\n" as one character; CRLF lines keep their "\r"), drops git's tab after a
    name with a space, and unquotes C-quoted names.
  - Added to `GitChangesService`: `init(environment:recycle:)` (the Trash step, injected by tests), and the static
    `gitDirectory(worktree:)` and `isBusy(worktree:)`, which read the worktree's `.git` file without running git.
    `ProcessRunner.output(_:_:in:environment:)` returns stdout untrimmed: `run` trims it, which cut a patch whose last
    context line is a lone space and the leading space of `status -z`'s first entry.
  - `FileWatcher`: `debounce` (500 ms), `excludedFolders` (`node_modules`, `.git/objects`: FSEvents' kernel exclusions
    at the top of each watched folder, and a filter on path components below it, so a package's own `node_modules` is
    left out), `workspacePaths(worktree:)` (the worktree and its git directory), `canonicalPath(_:)` (`realpath`;
    `URL.resolvingSymlinksInPath` strips `/private`, the opposite of what FSEvents reports). The debounce is FSEvents'
    own latency, one batch per window, so Rocky runs no timer. `WorkspaceWatch` (`stop()`) is what
    `AppModel.init(watchWorkspace:)` takes, so tests pass a fake (`FakeWatchers`) and fire its events.
  - `AppModel`: `rightPanelTab(workspaceId:)` (the fallback to Changes), `changesFailures` and
    `dismissChangesFailure(workspaceId:)` (`ERR-02` in the Changes tab for the diff and discard; `ChangesFailure` in
    `PullRequestActions.swift`, Task 16 adds commit), `discardChanges(workspaceId:paths:)`, and the stand-ins below.
    `refreshChanges(workspaceId:)` is serialized per workspace: called while a run is in flight, it makes that run go
    once more, so a burst of events never piles up git processes.
  - Tests: `DiffParserTests` (the plan's seven cases, plus a pure rename, CRLF, quoted names, 1,501 lines is large,
    `diffStatAbbreviatesThousands`, `listOrderPutsUncommittedFirst`); `GitChangesServiceTests`
    (`committedStagedUnstagedAndUntrackedAllAppear`, `shortstatMatchesTheParsedTotals`,
    `baseIsTheMergeBaseAfterTheBaseBranchMoves`, `nilBaseRefFallsBackToOriginHEADsBranch`,
    `nilBaseRefWithoutOriginIsTheMainFoldersBranch`, `aLockedIndexIsBusyInTheWorktreesGitDirectory`, the three
    discard tests and `discardSendsAStagedNewFileToTheTrash`); `FileWatcherTests.reportsTheFolderOfANewFile`,
    `excludedFoldersAreDroppedAndRescansNameSubtrees`; `AppModelTests.fileChangeRefreshesTheSidebarStats`,
    `hiddenChangesTabDoesNotComputeTheFullDiff`, `commentsAreReadOnlyWhileTheChecksTabShows`,
    `aWorkspaceThatNeverPickedATabShowsChanges`, `discardClosesTheFilesTabAndRefreshesTheChanges`.
- **2026-09-24, Task 1: GIT-03's numbers come from `git diff --numstat`, not `--shortstat`.** The same numbers,
  summed, but never translated: a git built with gettext translates shortstat's summary line. Every diff also runs
  with `-c core.quotepath=off`, explicit `a/` and `b/` prefixes (against `diff.noprefix`), `-c diff.renames=true`
  (against `diff.renames=copies`, whose copy entries the parser does not read) and a closing `--`, so the patch stays in
  the parser's format and a file named like the base is not read as a path.
- **2026-09-24, Task 1: untracked files over 1 MB have no rows.** They are `isLarge`, with their lines counted from the
  mapped file and no hunks, so a 50 MB log is not read into strings on every refresh. Task 4's Show must read such a
  file itself. Binary is a NUL in the first 8,000 bytes, git's own rule.
- **2026-09-24, Task 3: discard never deletes.** GIT-05's Trash is `FileManager.trashItem`, not `NSWorkspace.recycle`:
  RockyKit is Foundation only (`CLAUDE.md`), and it is the same Trash. Beyond the HTML's two cases, a file only added
  to the index, or the new name of a staged rename, is unstaged and goes to the Trash, since `git restore --staged
  --worktree` deletes a path HEAD lacks; a staged rename's original comes back. It runs with `--literal-pathspecs` (a
  file named `*.ts` is one file), refuses a file with no uncommitted change, and refuses one whose tracked or untracked
  state differs from the list's (it changed since). Test: `GitChangesServiceTests.discardSendsAStagedNewFileToTheTrash`.
- **2026-09-24, Task 2: what decides the full diff.** `RightPanel` sets `AppModel.visibleRightPanelTab` with
  `.onChange(of: tab, initial: true)`, and clears it on disappear only while its workspace is still selected: a new
  selection clears it in the model, drops the previous workspace's `changes` and stops its comment reads, because the
  old panel's `onDisappear` can come after the new one's `onChange`. The full diff is computed when the tab comes into
  view without one or with one older than the last change on disk, then on each change while it shows; window
  visibility does not gate it, as GIT-01 names only the tab. Each workspace's stats are read once when its stream
  starts (at launch, or when the workspace is created), so the sidebar has numbers before any change; after that, only
  on events. Streams are created through `Task.blocking`, since resolving them reads the `.git` file.
- **2026-09-24, Tasks 2–3: stand-ins until Task 4's diff tabs.** A Changes row's click and its Edit open the worktree
  file in today's file tab (`AppModel.openChangedFile`), and a deleted file opens nothing; the selected row is that file
  tab (`selectedChangedFile`); ⌥⌘↓ / ⌥⌘↑ walk from it (`showAdjacentChangedFile`); a discard closes that file tab.
  Task 4 re-points these three functions at diff tabs, and adds its diff tabs on screen to the private
  `showsChanges(workspaceId:)`.
- **2026-09-24, Tasks 2–3: ⌘⇧C and ⌥⌘↓ / ⌥⌘↑ are menu commands already** (View ▸ Show Changes / Hide Changes, Next
  Changed File, Previous Changed File, in `RockyApp.swift`), since these tasks ask for their behavior; Task 17 keeps
  them and checks the collisions.
- **2026-09-24, Task 2: the panel's tab row.** M2.7's one-tab title in `RightPanelTabRow` is gone, and
  `RightPanelTabButton` takes the count. `GitHubLoginNote` moved into `ChecksTab.swift` with the Checks tab's own
  scroll view. `Theme.diffDeletions` (#E48A8A, the `−D` of GIT-03 and CHG-03) is added now; TOK-10's fills stay Task
  5's.
- **2026-09-24, Tasks 2–3: not drawn yet.** CHG-02's comments bar and CHG-03's comment counts come with comments (Tasks
  6 to 8; the tab keeps the slot under its list), and the Uncommitted header's "Commit…" with Task 16. No store
  migration in Tasks 1–3: the next free one is still `v9`.
- **2026-09-24, Task 4: interfaces as built.**
  - `openDiff(workspaceId:path:mode:)` takes a `DiffTabMode?`, nil by default: a new tab shows its diff and an open one
    keeps its mode, so CHG-03's click selects the tab as it was left and its Edit asks for `.edit`. Added:
    `selectedDiffTabs` (at most one of it and `selectedFiles` per workspace; showing a conversation clears both),
    `showDiff`, `diffMode`, `setDiffMode`, `diffTabModes`, and `FileDiff.isEditable` (deleted and binary files show
    their diff whatever the tab picked).
  - The stand-ins are gone: `openChangedFile` is removed (the Changes tab calls `openDiff`), `selectedChangedFile` is
    the diff tab on screen, `showAdjacentChangedFile` opens diff tabs, and a discard closes the diff tabs of the files
    it discarded, not of those that failed. `showsChanges(workspaceId:)` counts the selected diff tab, and selecting a
    workspace asks for its diff at once when one of its diff tabs is on screen.
  - The rows are laid out in RockyKit so they are tested: `DiffLayout.rows(for:newLines:expanded:)` gives `DiffRow`s
    (`hunk`, `line`, `gap`). The unchanged runs before, between and after hunks come from the hunk ranges; their lines
    come from the worktree file, which is the diff's new side (`DiffLayout.readLines`, through `Task.blocking`, files up
    to 20 MB). Without the file the runs between hunks still show their count, and the run after the last hunk, whose
    length only the file knows, is left out. New file `Sources/RockyKit/Git/DiffLayout.swift`.
  - The number columns stay by an offset, not a second scroll view: the 96-point gutter (both numbers and the marker)
    moves by the horizontal scroll position (`onScrollGeometryChange`), which only the gutters, hunk headers and gap
    labels read (`DiffScrollOffset`, `@Observable`), so scrolling redraws them and not every row. Every row is as wide
    as the widest line, counted in columns (a tab draws as four spaces, a CRLF file's `\r` is not drawn), so the
    horizontal range never changes as rows come into view.
  - DIFF-03 beyond the table: the binary sizes come from `git cat-file -s <base>:<path>` (`GitChangesService.blobSize`,
    `AppModel.binarySizes`) and the file's attributes, read when the tab shows. An untracked file over 1 MB is read on
    Show; past 20 MB it says "This file is too large to show in Rocky." A rename without content changes says "Renamed
    without changes", an empty new file "Empty file". A mode change above hunks is a caption row over them.
  - A diff tab of a path not in Changes shows "Unchanged" instead of Diff | Edit, and Edit mode shows the file, both
    through `FileTabView(path:showsHeader: false)` until Task 9's editor. While the changes are not read the tab shows a
    spinner, or the diff's failure (ERR-02).
  - DIFF-05: `openBadgeFile(workspaceId:path:)`, the workspace's `OpenFileAction`, opens the diff tab of a worktree file
    in `changes`, and also while `changes` is not read (the panel on Checks or closed): the tab reads them, and an
    unchanged file then shows as above. A file outside the worktree, or known unchanged, opens a file tab as before. The
    worktree is matched by a plain prefix of the paths; Task 13 resolves them. `diffScrollRequests` scrolls a tab already
    on screen to its first hunk; a tab that opens starts at its top, where the first hunk is.
  - `WorkspaceTab` gained `isDirty` (DIFF-01's 7-point dot in the ×'s place until hover), for Task 10.
  - Not observed: no build ran in this session, so whether the `LazyVStack`'s scroll bar jumps (Known risks) is Task
    18's to check, with the `NSTableView` fallback if it does.
  - Tests: `DiffLayoutTests` (`theRunBetweenHunksCollapsesToItsCount`, `anExpandedRunShowsItsLinesWithBothNumbers`,
    `theRunAfterTheLastHunkNeedsTheFile`, `aRunBeforeTheFirstHunkStartsAtLineOne`, `anAddedOrDeletedFileHasNoRuns`,
    `aLargeUntrackedFileIsAddedRowsOnceRead`, `rowIdsAreUnique`, `aShorterFileShowsTheLinesItHas`,
    `readLinesKeepsCarriageReturnsAndSkipsBinaryFiles`); `GitChangesServiceTests.blobSizeIsTheFilesSizeAtTheCommit`;
    `AppModelTests.aDiffTabIsOnePerFileAndKeepsItsMode`, `aDiffTabOnScreenKeepsTheFullDiffComputed`,
    `adjacentChangedFilesOpenInDiffTabs`, `aBadgeOfAChangedFileOpensItsDiffTab`,
    `worktreeRelativePathIsOnlyForFilesInsideTheWorktree`; `discardClosesTheFilesTabAndRefreshesTheChanges` now checks
    the diff tab.
- **2026-09-24, Task 5: Prism and the highlighter as built.**
  - Prism 1.30.0, checked as that version on jsdelivr (`prismjs@1.30.0/components/`): the minified core and the plan's
    languages (markup for HTML, css, clike, javascript, typescript, jsx, tsx, json, swift, python, go, rust, yaml, toml,
    bash, markdown, sql), unmodified and in dependency order, with the MIT license in the bundle's header and in the
    root README. The bundle is `Sources/RockyUI/Resources/Prism/prism-bundle.js`, in a folder like `Resources/Icons`,
    which `Package.swift` copies (`.copy("Resources/Prism")`), rather than the plan's `Resources/prism-bundle.js`.
  - `SyntaxHighlighter` is an actor whose executor is its own `DispatchSerialQueue`, so Prism never runs on the main
    actor or the cooperative pool. It caches by the text's SHA-256 (64 texts) and leaves texts over 1,000,000 UTF-16
    units plain. `SyntaxKind`, `SyntaxToken` (UTF-16 ranges, JavaScript's unit), `SyntaxToken.split(_:lines:)` and the
    extension map (`SyntaxLanguage`, which `SyntaxHighlighter.language(forPath:)` forwards to) live in RockyKit
    (`Sources/RockyKit/Syntax/SyntaxTokens.swift`) so they are tested; JavaScriptCore stays in RockyUI, since RockyKit
    is Foundation only.
  - A small script after the bundle walks Prism's token stream into start, end and kind. A token's kind is the first
    known name from the innermost token out, its own type before its aliases; punctuation, operators and
    interpolations stay plain. Properties, keys and attribute names are `function`; builtins, class names and
    variables `type`; constants `number`. Checked in JavaScriptCore (`osascript -l JavaScript`) for every language.
  - A diff's new side is tokenized from the whole worktree file when it was read, else per hunk; its old side per
    hunk (context and removed lines), the only old text a patch has. The editor's 150 ms re-tokenizing is Task 9's.
  - `Theme` has TOK-10's `diffAddLine`, `diffAddGutter`, `diffDeleteLine`, `diffDeleteGutter`, `diffHunk`,
    `commentRange`, `currentLine`, `Theme.Syntax` and `Theme.syntax(_:)` (nil for plain).
  - Tests: `SyntaxTokensTests` (`languageFollowsTheExtension`, `splitCutsATokenAtEachLineEnd`,
    `splitCountsUTF16Units`, `newlinesAndEmptyLinesGetNoPieces`).

- **2026-09-24, the file finder is ⌘P (user decision).** Like VS Code's Quick Open: File ▸ Go to File… (⌘P)
  replaces macOS's File ▸ Print…, which Rocky has no use for (`CommandGroup(replacing: .printItem)`). FIL-04's
  ⌘⇧O is dropped; FIL-01's filter hint reads "⌘P".
- **2026-09-24, Task 6: comments as built.**
  - The migration is `v9` (table `diffComment`, `workspaceId` → `workspace` on delete cascade). The next free one, Task
    12's, is `v10`. `DiffCommentRecord.side` and `.state` are enums (`Side`: `new`, `old`; `State`: `pending`, `sent`,
    `outdated`) stored as those strings; `snippet`, `contextBefore` and `contextAfter` are JSON arrays of lines (a CRLF
    line keeps its `\r`, as the diff's do). The context is three lines each side and is stored only: CMT-04's rule
    reads the snippet alone.
  - `CommentAnchor` keeps the plan's `relocate(snippet:start:in:)`, not the HTML's `relocate(comment:newText:)`. A tie
    between two matches goes to the one above. Added: `reanchor(_:lines:)` (the rule over a file's comments: new side,
    pending or sent; a file that is gone outdates them, one Rocky does not read leaves them), `capture(_:side:rows:
    newLines:)` (what a new comment keeps: the worktree file for the new side when it is read, else the rows),
    `placement(of:draft:in:)` → `CommentPlacement` (the row under which each comment and the composer go, the outdated
    ones, and the ones whose line has no row), `CommentLine` and `DiffLine.commentLine` (a removed row's old number,
    any other row's new number). New file `Sources/RockyKit/Review/CommentAnchor.swift`.
  - `reanchor` runs in the same `Task.blocking` as each full diff (`refreshGitOnce`), so the new diff and the moved
    comments land together, and the moves are stored. A comment whose lines changed while git ran (an edit, a
    delete) is left for the next refresh. A workspace whose diff is not computed moves its comments on its next one.
    Old-side comments never move or turn outdated (the HTML: the base does not change).
  - `AppModel`: `diffComments` (read from the store per workspace in `reload`, dropped with it), `comments(onFile:
    workspaceId:)`, `readyComments(workspaceId:)` (pending, oldest first), `addDiffComment`, `editDiffComment` (the
    body only; the state stays, as in the mock), `deleteDiffComment`.
  - Tests: `CommentAnchorTests` (`unchangedLinesKeepTheRange`, `linesInsertedAboveShiftTheRange`,
    `anEditedCommentedLineIsOutdated`, `theSnippetTwiceGoesToTheNearestMatch`, `theSnippetAtTheEndOfTheFile`,
    `reanchorMovesNewSideCommentsAndOutdatesTheOnesThatLostTheirLines`, `reanchorReadsEachFileOnce`,
    `captureKeepsTheLinesAndThreeAroundThem`, `captureReadsTheRowsOfTheOldSide`,
    `aCommentSitsUnderTheRowOfItsLastLineOnItsSide`, `aRowsCommentLineIsItsSidesNumber`);
    `RockyStoreTests.commentsMigrationCreatesTheTable`, `removingAWorkspaceRemovesItsComments`;
    `AppModelTests.aRefreshKeepsCommentsOnTheirLinesAndStoresThem`, `commentsSurviveARelaunchAndGoWithTheirWorkspace`.
- **2026-09-24, Task 7: the comment UI as built.**
  - `DiffCommentState` (`CommentViews.swift`, `@Observable`) holds a tab's range, the composer's draft and its text
    apart, so a drag redraws the rows and typing only the composer. A press on a row's numbers (the "+" sits over them,
    in the sticky gutter) starts a range, a drag moves its end to the nearest line of its side, from the frames the
    rows on screen report in the rows' named coordinate space, and Shift extends the last range from its anchor. The
    release opens the composer.
  - Cards and the composer (`DiffCommentSlot`) go under the row of the comment's last line, as the mock does, sticky
    like the number columns, the gutter's width in and at most 560 wide. Beyond the HTML: an unchanged run holding a
    commented line opens (`DiffLayout.gaps(holding:in:lineCount:)`), a comment whose line has no row shows at the top
    so none goes missing, an old-side comment whose removed line came back sits under that line's context row, and an
    outdated card has Delete only (its lines are gone). The count on CHG-03's rows counts every comment of the file, as
    the mock does.
  - Esc in the composer is the text box's `onKeyPress(.escape)`: `ChatView`'s monitor is inactive while a diff tab
    covers the chat, so it never sees it. ⌘Return is the Comment button's `keyboardShortcut`. With text, Esc asks
    "Discard this comment?".
  - New `RockyPrimaryButtonStyle` (white filled, `ButtonStyles.swift`) for Comment and Send to agent; `Sticky` is no
    longer private. No new `Theme` token.
  - Not observed: no build ran, so whether `onKeyPress` reaches a `TextEditor` before its `NSTextView` takes Esc, and
    whether the drag stays smooth, are Task 18's to check. The fallback for Esc is a key monitor that reads the
    composer's focus through a reference (`CLAUDE.md`).
- **2026-09-24, Task 8: sending comments as built.**
  - `sendReview(workspaceId:)` goes through `sendAgentAction` (the M2.7 rule: the selected conversation, its agent
    started if needed, the conversation shown instead of the diff tab). `sendAgentAction` gained `willSend:`: with it,
    the agent is started first and `willSend` runs only if the prompt goes out, so the comments turn Sent then and a
    failed start leaves them pending. Existing callers are unchanged.
  - While a turn runs the button is disabled, not queued: the HTML and the plan agree. Its reason is AGT-00's
    `agentActionAvailability`, so a stopped agent disables it too, with "Restart the agent first"; the HTML names only
    the turn.
  - `ReviewPrompt.build(branch:comments:language:)` is the plan's; the HTML's `fileTexts:` is not needed, as the snippet
    is stored (CMT-03). The branch is the live one (`local.branch`, else `workspace.branch`), as the compare URL names
    it. Comments go oldest first, as the mock sends them. From the mock's `sendComments`: " (removed)" after an
    old-side comment's lines. Beyond it: a code block's tag is the file's extension when Rocky highlights the file ("ts"
    as in CMT-05; `fenceLanguage(forPath:)`), bare otherwise; a snippet holding a fence gets a longer one; a CRLF
    snippet loses its `\r`.
  - Tests: `ReviewPromptTests` (`formatForOneAndSeveralComments`, `carriageReturnsGoAndAFenceInTheSnippetGetsALongerOne`,
    `fenceLanguageIsTheExtensionOfAHighlightedFile`); `AppModelTests.sendReviewMarksCommentsSent` (the exact prompt with
    a removed-side comment, the conversation shown, Sent in the store), `sendReviewWaitsForTheTurn`;
    `DiffLayoutTests.aRunHoldingACommentedLineIsFound`.
- **2026-09-24, Task 9: the editor as built.**
  - `CodeEditor` (`Sources/RockyUI/CodeEditor.swift`) keeps the plan's `text`, `language`, `baseText` and `isEditable`.
    `goToLine` is an `EditorLineRequest` (line and serial, so the same line can be asked twice; a nil line only gives
    the keyboard back), and it gains `takesFocus`, `onGoToLine` (⌘L) and `zoom`. The TextKit 1 stack is built by hand
    (non-contiguous layout), with `CodeTextView` (Tab inserts the detected indentation; Return keeps the line's, beyond
    EDIT-01; ⌘L; the caret line on `currentLine` under the text) and `CodeGutterView`, an `NSRulerView` that draws the
    numbers and EDIT-04's bars. The final newline's empty line has no number, as in the mock and the diff.
  - Each editor has its own `UndoManager` (the text view's delegate), so its undo never reaches the message box or
    another tab. It lives as long as the view: a tab hidden and shown again keeps its text (Task 10) but starts a new
    history. EDIT-01's "undo goes back past a save" holds within one showing.
  - Colors (DIFF-04) are the layout manager's temporary attributes, so they touch neither the undo history nor the
    layout: 150 ms after typing, the visible lines alone first past 20,000 UTF-16 units, then the whole text, whose
    tokens are applied only to the lines on screen and a screen around them, and to the rest as it scrolls in. The
    change bars (`ChangeBars`, RockyKit) are computed off the main actor on the same 150 ms.
  - The SwiftUI side is `Sources/RockyUI/EditorPane.swift`: `EditorPane` (the file read into the model once, the
    editor, the go-to-line field over it; "File not found"; Quick Look for what is not text, until Task 15),
    `EditorStatusControls` ("Edited" and Save, or "Reloaded") and `EditorBanners`. `FileKind.opensInEditor` decides
    which tabs get the editor: code, data, text, spreadsheets and unknown kinds (a Makefile, a dotfile); their bytes
    then decide (binary, not UTF-8 or over 20 MB → Quick Look as before; 2–20 MB → read-only and plain). Before, file
    tabs sent text over 2 MB to Quick Look.
  - `FileTabView` takes the model and the workspace: code and text file tabs are the editor, Markdown with
    Preview | Edit (Preview first, `MarkdownFilePreview`), images and the rest as before. `DiffModePicker` became the
    generic `ModePicker`, for both. The diff tab's Edit mode is `EditorPane` for editor files and `FileTabView` without
    header for images and other media.
  - Before the changes are read, a diff tab shows the mode it picked, so Edit shows the editor at once. FIL-05's
    "Becoming changed" is in `DiffTabView`: a tab shown unchanged records Edit, so joining Changes keeps it in Edit.
  - Keys: ⌘L is the text view's key equivalent while it has the keyboard; ⌘S is the header's Save while the file has
    unsaved edits (off while the settings or a repository's settings are open, whose Save has ⌘S). Task 17 makes them
    menu commands. `ChatView.handleKey` leaves every key to an editor with the keyboard, its find bar included
    (`CodeEditor.hasKeyboard(in:)`, the way `TerminalView` is skipped), so Esc closes the find bar and never stops the
    turn.
  - New `Theme` tokens from the mock's CSS: `editorSelection` (`accent` 30 %), `bannerWarning` / `bannerWarningText`,
    `bannerInfo` / `bannerInfoText`.
  - Tests: `EditorTextTests.swift` (`IndentationTests`, `LineStartsTests`, `ChangeBarsTests`), new file
    `Sources/RockyKit/Edit/EditorText.swift` (`Indentation`, `LineStarts`, `ChangeBars`).
- **2026-09-24, Task 10: saving and changes on disk as built.**
  - The buffers live in `AppModel.editors` (workspace id → absolute path → `EditorState`: loading, missing,
    unavailable, or a document), not in the view: `DiffTabView` is a new view each time its tab shows, and unsaved
    edits must survive that and a workspace switch. One buffer per file: a file tab and a diff tab of the same path
    share it (`AppModel.editorPath(worktree:relativePath:)` is a diff tab's key), and it goes with the file's last tab
    or its workspace. Added: `openEditor`, `setEditorText` (a read-only file takes none), `saveEditor`, `reloadEditor`,
    `keepMine`, `hideAgentBanner` (per tab), `isEditorDirty`, `workingAgent(workspaceId:)` (the banner's agent name).
  - `EditBuffer` keeps the plan's rules, with these names: `keepsMine` (a property and a method cannot both be
    `keepMine`), `saved(_:stamp:)` takes the text written, so text typed during a save stays unsaved, and `disk` is the
    version a conflict is about, which Reload takes and Keep Mine lets a save overwrite. `canSave(current:)` is the
    loaded stamp, or Keep Mine over that very version: one written after it blocks the save again. `diskChanged`
    returns `.none` for the version already recorded, so each event does not undo a Keep Mine, and for a file only
    touched. `FileStamp` is the modification date and a SHA-256 (CryptoKit, a system framework, in RockyKit).
  - A save is one blocking job: read the file, check the stamp, write. A file only touched is taken in and written; a
    changed one writes nothing and shows the conflict banner. `TextFile.write` writes at a link's target through
    `FileManager.replaceItemAt`, which keeps the file's permissions and extended attributes, and creates a file that
    is gone (Keep Mine over a deletion). A failed write is the window's alert. A save inside the worktree refreshes the
    changes, so the diff and the bars follow.
  - Line endings: a file whose every line ends in CRLF edits with "\n" and saves as CRLF; a mixed file keeps its "\r"s
    in the text, so each line is written back as it was; a UTF-8 byte order mark stays; a final newline is never added
    or dropped (`TextFormat`, new file `Sources/RockyKit/Edit/TextFile.swift` with `TextFile`). Each side of the change
    bars is normalized by its own format, so a change of line endings alone shows no bar.
  - EDIT-03 runs on the workspace's stream: each batch stats the workspace's open files and reads only those whose date
    moved, off the main actor, and a result applies only if the buffer did not change meanwhile (a save, a reload). A
    clean buffer takes the new text in a fresh document (a new format or size is written back the new way) and shows
    "Reloaded", which the model clears 2 s later (one sleep, no timer). Beyond the HTML: a file that was missing is
    read once it appears; a clean file that goes shows as missing, and one with unsaved edits turns the conflict,
    against an empty file.
  - EDIT-04's base: `git cat-file blob <base>:<path>` (`GitChangesService.blob`), once per base and path
    (`EditorBase`, `loadEditorBase`, `editorBaseText`), under a rename's old path. A file the base lacks compares with
    nothing (all added); one git has no text for (ignored, binary) shows no bars. File tabs outside the worktree have
    no bars.
  - The close prompt ("Save changes to …?", Save / Don’t Save / Cancel) is a `confirmationDialog` of
    `ConversationTabs`, for file and diff tabs; a Save stopped by a change on disk shows the tab with its banner.
  - Not covered: quitting Rocky with unsaved edits does not ask (EDIT-02 names only the tab). Until Task 13 routes a
    badge's worktree file to its worktree tab, a file tab and a diff tab can reach one file by two spellings of its
    path, and then hold two buffers.
  - Not observed: no build ran. The baseline centering under a fixed line height, temporary attributes following
    edits, the ruler's drawing, Esc in the find bar, and whether SwiftUI's ⌘S reaches the button while the text view
    has the keyboard are Task 18's to check.
  - Tests: `EditBufferTests` (the plan's six, `keepMineCoversOnlyTheVersionItWasChosenOver`,
    `theVersionAlreadySeenChangesNothing`, `aTouchedFileOnlyMovesTheStamp`, `theFileTakingTheUnsavedTextCleansTheBuffer`,
    `textTypedDuringASaveStaysUnsaved`), `TextFormatTests`, `TextFileTests` (`.blockingWork`: the symlink, the
    permissions, missing, binary and the 2 MB rule); `GitChangesServiceTests.blobIsTheFileAtTheCommit`;
    `AppModelTests.aCleanEditorReloadsAndADirtyOneConflicts`, `aSaveNeverOverwritesAChangeItHasNotSeenUntilKeepMine`,
    `savingAnUnchangedFileBringsItIntoChanges`, `anEditorGoesWithTheLastTabOfItsFile`,
    `aMissingFileIsReadWhenItAppearsAndALargeOneIsReadOnly`.
- **2026-09-24, Task 11: the file list and the tree as built.**
  - `FileTree.rows` keeps each listing's order instead of sorting it on every draw: `WorktreeFiles.listing` sorts once,
    off the main actor, with the new `FileTree.sorted` (folders first, then files, `localizedStandardCompare`), and
    `foldersFirstThenFilesInFindersOrder` pins both. A folder of thousands of entries is then never sorted in a view's
    body.
  - `FileList.paths` is in Finder's order folder by folder: each folder's files and subfolders sorted together by name,
    which is the order of comparing paths component by component, and costs short-name comparisons only. Equality is
    git's output (`ls-files`' two lists as printed), so `WorktreeFiles.list(worktree:reusing:)` returns the previous
    list, unsorted again and with its identity, when git prints the same; the plan's `list(worktree:)` is kept. A
    nested repository ("vendor/lib/", git's trailing slash) counts as a folder that is not ignored and adds no file;
    `--cached`'s repeated conflict entries count once.
  - `rank` searches a `SearchIndex` built with the list (the paths lowercased, back to back as UTF-8, with each name's
    start) with `memmem`, as `SlashCommand` does; its in-order ranks take the query one Unicode scalar at a time. It
    checks the in-order match over the whole path first, so most paths fail in one pass. `matches` uses Foundation's
    case-insensitive search for the contiguous ranks.
  - Added: `FileEntry: Hashable`, `FileTree.shownSubfolders` and `shownFolders` (the folders the rows reach: the
    root, then each expanded folder whose parents are expanded and read, an ignored one only with Show Ignored Files;
    nothing counts as ignored before git's list is read), `FileTreeState.listFailure` (`ERR-02`: `ls-files`' last lines
    in place of the tree), and the `WorktreeFileReading` protocol that `AppModel` takes. `FileTreeState` lives in
    `FileTree.swift`.
  - Tests beyond the plan: `FileTreeTests.onlyTheFoldersTheRowsReachAreShown`, `listsWithTheSameOutputAreEqual`.
  - Not observed: no test ran, so whether `ranks100000PathsInUnder50ms` holds in the debug build is Task 18's (Known
    risks: measure release if it misses only there, and record it).
- **2026-09-24, Task 12: the All files tab as built.**
  - The migration is `v10` (table `expandedFolder`, primary key `workspaceId` and `path`, `workspaceId` → `workspace`
    on delete cascade; column `repo.showsIgnoredFiles`, not null, false). The next free one is `v11`. `Repo` gains
    `showsIgnoredFiles` (init default false); `RockyStore.setShowsIgnoredFiles` writes that column alone, and
    `AppModel.setShowsIgnoredFiles` updates its own copy of the repository, so the whole-row updates of the other
    settings write it back as it is (`showIgnoredFilesIsRememberedPerRepository` saves the linked paths after it).
  - `AppModel.init(worktreeFiles:)` takes a factory by environment, like `watchWorkspace` (`WorktreeFiles` in Rocky,
    `FakeWorktreeFiles` in the tests, which counts the runs and the folders read). Added: `showsIgnoredFiles(workspaceId:)`
    and the internal `refreshFiles(workspaceId:)`, serialized per workspace like `refreshChanges`.
  - Each read is one blocking job: `ls-files` when the list is missing or stale, then the folders from the root down
    through the expanded ones the rows reach, reading only the missing or stale ones, so a relaunch with ten expanded
    folders spawns one thread, not ten. A folder that cannot be read lists nothing and is not read again until an event
    names it. Opening a folder reads it again each time (Known risks: `node_modules` gets no events). An event batch
    marks the list and the named folders the rows show stale, and drops the cached listings of the others (subtrees:
    every cached folder inside); it reads only while the tab shows. The events are compared with both spellings of the
    worktree, its own path and the one FSEvents reports (`canonicalWorktrees`, resolved once in the stream's blocking
    job), so the tests' events and FSEvents' are read alike.
  - Another workspace selected drops the previous one's `fileTrees` and marks; its expanded folders come back from the
    store when its tab shows again, and `ls-files` runs again then, as for a first showing.
  - Beyond the HTML: "Reading the files…" until git's list and the root are read; git's failure in place of the tree.
    Clicking a row gives the tree the keyboard, so ↑ / ↓ go on from it; the keyboard's row is ringed in `accent` at 45 %
    (the mock's `.trow.cursor`) while the tree has it. → on an open folder moves to its first child. A folder opens or
    closes on the first click of a double-click only.
  - `FileKind(path:isDirectory:)` classifies from the name; `FileKind(path:)` keeps its disk check for badges and calls
    it. Tree rows, match rows and worktree tabs (`DiffTabIcon`, the diff tab's editor choice) use the new one.
  - Tests: `RockyStoreTests.treeStateMigrationAddsItsTableAndColumn`, `expandedFoldersRoundTripAndGoWithTheWorkspace`;
    `AppModelTests.hiddenFilesTabRunsNoGit` (also: a second showing with nothing changed reads nothing, and an
    unselected workspace keeps and reads nothing), `anEventReReadsOnlyTheExpandedFolderItNames` (also: an event naming a
    collapsed folder only drops it), `eventsWhileHiddenAreReadWhenTheTabShows`, `expandedFoldersSurviveRelaunch` (also
    Collapse All Folders), `showIgnoredFilesIsRememberedPerRepository`; `WorktreeFilesTests` (the plan's three, plus
    links in `listingNeverShowsGit` and the reused list in `listHasTrackedAndUntrackedButNotIgnored`).
- **2026-09-24, Task 13: opening files and preview tabs as built.**
  - `revealedPaths` is kept until the tab has drawn the row and scrolled to it, which it says with the added
    `revealHandled(workspaceId:)`: the folders' listings may still be on their way, and the panel may be closed. Reveal
    in All Files opens the panel through `RightPanelStorage.openKey`, the Reveal Active File of the tree's menu clears
    the filter itself, and the tab clears it for any reveal.
  - `openDiff` is the regular open (the Changes tab, badges, ⌥⌘↓ / ⌥⌘↑): opening the preview's file there keeps the
    preview. A replaced preview leaves its mode, its base and its editor behind (`forgetWorktreeTab`, shared with
    `closeDiff`).
  - A preview does not take the keyboard: `WorkspaceDetailView` passes `DiffTabView(takesFocus:)` false for the preview
    tab, which `EditorPane` forwards, so the tree's arrows and the filter keep browsing. A kept tab takes it.
  - `WorkspaceTab` gained `isPreview` (italic title) and `onDoubleClick`, called on the second click after `onSelect`,
    from its one tap handler.
  - "Reveal in All Files" is in the worktree tabs' "⋯" menu, not for a deleted file (it has no row). File tabs now hold
    only files outside the worktree, which have no row either, so theirs has none (they have no "⋯" menu).
  - Badges: a worktree file matched by the worktree's own path or its canonical one (no disk touched; a link inside the
    worktree, a linked `.env`, stays the worktree's file) opens its worktree tab; an unchanged one in Edit, where it
    opened a file tab before. `aBadgeOfAChangedFileOpensItsDiffTab` now expects that.
  - Tests: the plan's six; `aSingleClickReplacesThePreviewTab` also pins a kept tab shown by a click, the Changes tab's
    open keeping the preview, and closing the preview.
- **2026-09-24, Task 14: filter and Go to File as built.**
  - `goToFileRequest: String?` (the workspace whose tab is to focus its filter) and `goToFileHandled(workspaceId:)`
    instead of `goToFileRequests: Int`: a tab that appears for the request (the panel was closed, or on another tab)
    reads it once with `.onChange(initial: true)`, and a counter would have made every appearance focus the field. The
    text is selected with `NSText.selectAll` right after the field takes the keyboard.
  - `ChatView.handleKey` leaves every key to the filter while it has the keyboard, the way the editor and the terminal
    are skipped: `FileFilterFocus.hasKeyboard(in:)` reads the tab's focus (a static the tab sets) and checks that the
    window types through a field editor, so a focus state left behind never keeps Esc from the agent.
  - The ranking runs in `Task.detached` (CPU work, no blocking call), keyed on the query and the list, so a new list
    re-ranks the same query and keeps the cursor. ↓ in the empty field gives the keyboard to the tree (the mock's). The
    tree stays under the matches, hidden, so an empty query shows it with its scroll position.
  - Not observed: no build ran, so whether `onKeyPress` reaches the field before its field editor takes the arrows, and
    whether the tree's `focusable` scroll view takes the keyboard on a click, are Task 18's to check.
- **2026-09-24, Task 15: large and binary files as built.**
  - `FileContent.classify` looks at the size first: over 20 MB is `tooLarge`, binary or not, since nothing is read.
    `TextFile`'s limits are now `FileContent`'s. `TextFile.snapshot` reads the first 8 KB, and the rest only for text; a
    binary file's stamp hashes those 8 KB with its date, so a binary file up to 20 MB is no longer read whole.
  - The cards are `UnopenedFileView` (`FileTabView.swift`): "Too large to open in Rocky · 48 MB" with Open in Finder
    and one "Open in …" per installed editor, looked up once when the card appears; "Binary file · 112 KB" with Open in
    Finder. Sizes are `ByteCountFormatter`'s file style (`FileSizeText`). `EditorPane` shows them for
    `EditorState.unavailable`, which includes text that is not UTF-8 (Known risks). File tabs of archives, audio and
    video show the binary card where they used Quick Look; images and PDFs keep today's views.
  - The private `openWorktree(in:app:)` became `ExternalEditorOpener.open(_:in:app:toasts:)` in
    `WorkspaceDetailView.swift`, for the worktree folder and for one file. The large-file banner is in `EditorBanners`,
    while the editor shows.
  - Tests: `FileContentTests` (the plan's three); `TextFileTests.aBinaryFileHasAStampAndNoText` still holds.
- **2026-09-24, Task 16: the commit as built.**
  - `GitChangesService.commit(worktree:subject:description:output:)` is synchronous and throws, like the rest of the
    service (Decisions: callers use `Task.blocking`), not the plan's `async throws`. The workspace environment is the
    service's own (`init(environment:)`), so it takes no `environment:`. `output` gets a batch of lines per read.
  - Hook output: `ProcessRunner.stream(_:_:in:environment:onOutput:)` runs git with stdout and stderr on one pipe, so a
    hook's lines keep their place among git's, and returns the exit status. `CommandOutputDecoder` (`ProcessRunner.swift`)
    turns the reads into lines: a UTF-8 character split by a read comes back whole, terminal escapes and control
    characters go, a line that carriage returns rewrote shows its last version. Every line goes through
    `GitHubAccounts.withoutTokenShapes`, since hooks get `GH_TOKEN`.
  - A failed step throws `GitCommitFailure` (`command` "git add -A" or "git commit", `status`, `outputTail`, its last 20
    lines; `summary` "git commit exited 1"). Beyond the HTML: a worktree in the middle of a rebase or a merge is refused
    before anything is staged, since a commit there would land inside that operation.
  - `AppModel.commits` (`CommitProgress`: the subject and description it was given, the output's last 500 lines, the
    failure) is the sheet's state while the commit runs, and after a failure until the sheet closes
    (`dismissCommit(workspaceId:)`). `commitChanges(workspaceId:subject:description:)` trims both and leaves out an
    empty description, waits for the login environment (the hooks need the user's PATH), reads the output through an
    `AsyncStream`, so lines arrive in order, reads the changes again, and shows the mock's toast "Committed".
  - The Changes tab shows the sheet while the model has a commit for the workspace, so a sheet that went away with its
    tab (⌘1 or ⌘P while it runs) comes back with it, message included. ERR-02 for the commit is the sheet:
    `ChangesFailure` gains no `.commit` (the Tasks 1–3 record expected one).
  - The sheet (`CommitSheet.swift`, new) is a SwiftUI `.sheet`: macOS's own slide from the top of the window. Cancel has
    Esc (`.cancelAction`), and while git runs it is off and the sheet cannot be dismissed (`interactiveDismissDisabled`);
    Commit has ⌘Return. The subject is prefilled with the workspace's title only when it has one, not with its city
    name, as the mock's `w.title || ''`. The file list is the model's live uncommitted list: `git add -A` takes a file
    the agent adds meanwhile. "Commit…" is a 22-point filled button at the end of the Uncommitted header.
  - No store migration: the next free one is still `v11`.
  - Tests: `GitChangesServiceTests.commitIncludesUntrackedFiles`, `failingHookReportsItsOutput`, `aPassingHookRunsFirst`,
    `commitRefusesDuringARebase`; `CommandOutputDecoderTests` (`linesComeWholeAcrossReads`,
    `escapesGoAndARewrittenLineShowsItsLastVersion`, `commitProgressKeepsItsLastLines`);
    `AppModelTests.commitCommitsEveryChangeAndLeavesNoSheet`, `aFailedCommitKeepsItsMessageAndOutputForTheSheet`.
- **2026-09-24, Task 17: keyboard commands as built.**
  - File ▸ Save (⌘S) sits after Close (`CommandGroup(after: .saveItem)`: replacing that group would remove Close, ⌘W).
    It is `AppModel.saveVisibleEditor(workspaceId:)` on the file of the tab on screen (`visibleEditorPath`), on while
    that file has edits to write (`canSaveVisibleEditor`, the header's Save rule), and off while the settings or a
    repository's settings are open (`SettingsPresenter.isAnySettingsPanelOpen`), whose Save has ⌘S. The header's Save
    lost its own ⌘S, so the key has one owner.
  - File ▸ Go to File… (⌘P) and Go to Line… (⌘L) replace Page Setup and Print (`CommandGroup(replacing: .printItem)`).
    Go to File calls `goToFile(workspaceId:)` and opens the panel through `RightPanelStorage.openKey`. Go to Line runs
    the `EditorGoToLineAction` that the editor on screen publishes (`focusedSceneValue(\.editorGoToLine)` in
    `EditorPane`), so it works on a preview tab without the keyboard and is off wherever no editor shows (a diff, a
    conversation, a Markdown preview). The text view keeps its own ⌘L, which it answers first while it has the keyboard.
  - ⌘⇧C (View ▸ Show / Hide Changes) and ⌥⌘↓ / ⌥⌘↑ (Next / Previous Changed File) stay as Tasks 2–3 made them and match
    KBD-02. ⌥⌘↓ / ⌥⌘↑ are off while the workspace's changes are not read (panel on Checks or closed, no diff tab on
    screen).
  - Collisions, checked against every shortcut in `RockyApp.swift` and every `keyboardShortcut` and key monitor in the
    views: ⌘N, ⌘K, ⌘1–⌘9, ⌃⌘S, ⌥⌘B, ⌘⇧C, ⌥⌘↓ / ⌥⌘↑, ⌘+ ⌘= ⌘- ⌘0, ⌘, (Settings), ⌘J (terminal panel), ⌘U (attach),
    ⇧Tab (plan mode), ⌘S in a repository's settings, ⌘Return (a comment, and the commit in its own sheet window), Esc.
    None repeats (⌘S is not ⌃⌘S). SwiftTerm's `TerminalView` has no key equivalent of its own, so ⌘P reaches the menu
    from a terminal.
  - Esc: `ChatView.handleKey` leaves every key to a diff comment's composer while it has the keyboard
    (`CommentComposerFocus`, set from the composer's focus state and read at the key's time, as `FileFilterFocus` is),
    and to a sheet's own window (`window.sheetParent != nil`) or an app-modal alert (`NSApp.modalWindow`). A sheet's
    keys come from the sheet's window, which has no attached sheet of its own, so the old `attachedSheet == nil` check
    let Esc in the commit sheet, a permission request or an alert stop the agent's turn, and ⌘U open the attach panel
    behind it.
  - Tests: `AppModelTests.saveWritesTheFileOnScreen`. The commands themselves are UI (manual checklist items 5, 7, 10).
- **2026-09-24, unsaved edits on quit: a departure made for safety (dev-1's request, beyond KBD-02).**
  - Quitting Rocky with unsaved editor edits lost them without asking (Task 10's record: EDIT-02 names only the tab).
    `applicationShouldTerminate` now asks first, in an app-modal alert, which shows with the window closed too (⌘W
    closes the window, not Rocky): "Save changes to 3 files before quitting?", the files (worktree-relative, with the
    workspace's title when they span several workspaces; eight named, the rest counted), then Save All (Return), Cancel
    (Esc) and Don't Save (⌘D). Save All writes each file as ⌘S does (`AppModel.saveEditors`). A file whose save a change
    on disk stopped, or whose write failed, cancels the quit and shows its tab, with its banner (`showUnsavedEditor`).
  - The tab's close prompt (Task 10's confirmation dialog, Save / Don't Save / Cancel) now uses the same words:
    `UnsavedChangesPrompt` (title, file list, save button) and `AppModel.unsavedEditors(workspaceId:)` serve both
    (`UnsavedEditor`, new file `Sources/RockyKit/Edit/UnsavedChanges.swift`). With one file the button says Save, not
    the requested "Save All", in both prompts.
  - Kept to that: no autosave. Closing the window keeps the buffers in the model, as before; a discard and a
    workspace's removal still drop the buffers of their files.
  - Tests: `UnsavedChangesPromptTests` (`oneFileIsNamedAndSeveralAreCounted`, `theListNamesEightFilesAndCountsTheRest`;
    new file `Tests/RockyKitTests/UnsavedChangesTests.swift`);
    `AppModelTests.saveAllWritesEveryUnsavedFileAndKeepsTheOnesThatChangedOnDisk`.
- **2026-09-24, Tasks 16–17: not observed.** No build ran. Task 18 checks first: `focusedSceneValue` reaching the
  menu's `@FocusedValue` while the editor is an AppKit text view; the menu's ⌘S and ⌘L against the window's own key
  equivalents (a repository's settings' Save, the text view's ⌘L); `ProcessRunner.stream` ending when git exits (a hook
  that leaves a background process holding the pipe would keep it open); the sheet's Esc and ⌘Return while its
  description's text view has the keyboard; and `NSAlert.runModal` inside `applicationShouldTerminate`.

### After the merge (2026-09-24, branch `fix/m3-editor-and-quick-open`)

- **The editor broke the window's drawing (user reports).** Opening a file first left the sidebar, the top bar and the
  tabs undrawn; once `.clipped()` contained that, the text itself stayed blank and the gutter's numbers ran over the
  terminal bar. The cause was `CodeGutterView.draw(_:)` filling `dirtyRect`: since macOS 14 a view does not clip its
  drawing to its bounds and `dirtyRect` can be larger than them, so the gutter painted its background over the text
  and past the editor. It now fills `bounds ∩ dirtyRect` and sets `clipsToBounds`. Found by hosting the real
  `CodeEditor` in a throwaway window: with the ruler hidden the text drew, and a red text-view background never showed
  with it. A first guess (the text view's `greatestFiniteMagnitude` sizes, then `.clipped()`) was wrong and was reverted.
- **Placeholders jumped 1 point on focus (user report).** A plain `TextField`'s `prompt` is drawn by the cell at rest
  and by the field editor while editing, 1 point higher. The All files filter and the sidebar search now draw their
  placeholder with `stablePlaceholder(_:isVisible:)` (`ButtonStyles.swift`) over an empty prompt.
- **The diff draws one line-number column (user request).** "Tenemos un duplicado en el número de líneas, mira cómo
  lo hace conductor": the old and new columns (40 each) read as the number twice. `DiffLineGutter` now draws one
  48-point column, as Conductor does: the new number, the old one on a removed row, in `success` on an added row,
  `danger` on a removed one and `textTertiary` on context; the marker stays, so `DiffMetrics.gutterWidth` is 48 + 16.
  UI only, no test. The designer is updating `DIFF-02` and `CMT-01`.
- **Review comments reach the chat as Conductor's do (user decision, pending design).** The user disliked the whole
  `ReviewPrompt` as the message bubble and chose Conductor's flow: commenting on lines opens a box "Sending to
  <conversation>" with a "<file> +<start>-<end>" chip, the comment goes at once, and the transcript shows the chip and
  the text. The designer rewrote `CMT-02` and `CMT-05`, added `CMT-06`, and removed `CMT-03` and `CMT-04`. Tasks 23–27
  below.
- **A short diff sat in the middle of its tab (user report).** "Conductor muestra de primero solo las líneas
  modificadas; nosotros estamos centrando en la pantalla las líneas modificadas": a two-axis `ScrollView` centers
  content shorter than itself, and a diff whose unchanged runs are collapsed is short. `UnifiedDiffView` now sets
  `.defaultScrollAnchor(.topLeading, for: .alignment)`. UI only, no test.
- **No `@@` rows (user decision).** Asked whether to drop git's hunk header lines as Conductor does, the user said yes.
  `DiffRow.hunk`, `DiffHunkRow` and `Theme.diffHunk` are gone: a collapsed run already separates two hunks, since git
  merges hunks with no unchanged line between them. `DIFF-05`'s scroll goes to the first hunk's first line
  (`DiffLayout.firstHunkRowId(in:)`). `DiffLayoutTests.aRunBeforeTheFirstHunkStartsAtLineOne` and
  `anAddedOrDeletedFileHasNoRuns` now expect no header row, and so does `theRunBetweenHunksCollapsesToItsCount`, which
  still listed the headers' ids (`h0`, `h1`) until Task 30's first test run failed on it.
- **A simpler Open menu (user request).** "El menú de abrir creo que puede ser más sencillo, solo mostrar el logo del
  app y el nombre, como en Conductor". `TB-03`/`OPN-01`'s menu (`WorkspaceDetailView.openMenu`) loses its path header
  and the "Open in" prefix: Finder (with Finder's own icon) and each installed editor as its icon and name, then a
  divider, New Terminal and Copy Path; 200 wide. `OpenMenuPathHeader` is gone. UI only, no test.
- **No "Working…" in the pull request header (user decision, 2026-09-25).** "No me parece que si el agente está
  pensando en el panel de la derecha también haya un loader… ya tenemos suficientes": M2.7's `HDR-02` row "Working…"
  is gone. `HeaderState.working` and `PullRequestHeader.state`'s `agentWorking` parameter are removed, so the header
  always shows the pull request's state; its agent actions stay disabled with `AGT-00`'s reason while a turn runs.
  `PullRequestHeaderTests.working` is gone and the other tests call the new signatures.
- **⌘P becomes Quick Open (user request).** "Pensé que haríamos como un command palette que tendría todos los archivos
  y un buscador", with Zed's quick open as the reference. The designer added it as `FIL-08`, fixed `FIL-05` (only a new
  preview replaces the preview tab) and updated `FIL-04`, `KBD-02` and `OUT-10`. Tasks 19–22 below.
- **2026-09-24, Tasks 19–22 (Quick Open), what the tasks did not settle:**
  - Quick Open keeps the full diff computed while it shows (`showsChanges`), and `quickOpenWillShow` computes it when it
    is missing or stale. Without it, with the panel closed or on Checks, `changes` is nil and FIL-08's status letters
    and "then the changed files" were missing. The Decisions' "`changes` follows what is on screen" covers it: events
    already run git for the stats, so an open Quick Open costs a full diff instead of a shortstat, and one run at
    opening. Pinned by `AppModelTests.eventsWhileQuickOpenIsOpenReadNothing`.
  - Quick Open's keys (↑ / ↓, Return, ⌥Return, Esc) are taken by `QuickOpenPresenter`'s local key monitor, not by the
    field's `onKeyPress`: FIL-08 asks for Esc and the arrows before `ChatView`'s monitor, and the field editor would
    have taken ⌥Return as a line break. Return and Esc are left to an input method's composition.
  - Esc, a click outside and ⌘P give the keyboard back to what had it (the message box, the editor, a terminal); a
    text field's field editor is not kept. Opening a file leaves it to the tab. Another selected workspace, an open
    settings panel (`RootView`) and closing the window (`QuickOpenHost`) close Quick Open.
  - Hover selects only after the pointer moves, as in the slash command popup, so a list the keyboard scrolls under a
    still pointer keeps its row.
  - `FileList.position(of:)` finds a recent file by binary search in Finder's order (`FileTree.pathPrecedes`), so the
    recent files need no index of every path. With 20 of them, `rank` takes about 1 ms more (17.5–18.5 ms alone, debug
    build). `ranks100000PathsInUnder50ms` counts the best of three runs, after one parallel run measured 58 ms under
    the other suites' load; the bound stays 50 ms (`m3-verification.md`).
  - The store replaces a recent file's row (delete, insert) instead of updating it, so opens in the same millisecond
    keep their order by rowid. Raw SQL like `expandedFolder`: no record type in `Records.swift`. Pinned by
    `RockyStoreTests.recentFilesKeepTheNewest20AndGoWithTheWorkspace`.
  - `FIL-05`'s fix changed `aDoubleClickKeepsThePreview`: a double-click on another row is its first click, then its
    second, as the tree sends them; a lone `keep: true` now keeps its own tab (`openingToKeepLeavesThePreviewTabAlone`).
  - A worktree with no files and an empty query shows "No files" (no copy in the design for it). The folder of a row
    shows without its trailing "/", as in the mock.
- **2026-09-24, Tasks 23–27 (comments like Conductor), what the tasks did not settle:**
  - The prompt is one text block through a new `PromptAttachment.text` case (the plan's "or equivalent"), never split
    at the file marker, so code holding U+FFFC reaches the agent whole. Pinned by
    `ACPProtocolTests.aTextAttachmentIsOneTextBlockAsItIs`.
  - `ChatSessionModel.send(_: LineComment)` queues the comment when a turn is running, also one that began while the
    agent started, so a comment is never dropped. `AppModel.sendLineComment` returns once the comment is on its way
    (the send runs in a task) or queued, not when the turn ends, so the toast shows at once. Pinned by
    `ChatSessionModelTests.aQueuedLineCommentGoesOutWithThePromptBuiltBefore` and `AppModelTests.aLineComment…`.
  - `makeChat` returns the conversation's chat when another caller made it while it waited (a comment sent to a
    conversation whose tab opens meanwhile), so a conversation never runs two agents. Not pinned: it is a race.
  - The box's draft is an `@Observable` class the model keeps (`CommentDraft`, `AppModel.commentDrafts`), so typing
    redraws the box and not the diff's rows. Its conversation resolves as picked while that one is open, else the one
    the workspace shows, else its newest (`commentConversation(for:workspaceId:)`). Opening a box keeps a preview tab
    (FIL-05), as the first edit does, so a click in the tree never drops a comment being written. Pinned by
    `AppModelTests.aCommentBoxStaysWithItsTabAndGoesWhenItCloses`.
  - `.unavailable` (the conversation closed, or its agent did not start) puts the comment back in its box and shows
    "Couldn’t send to “<title>”" with Show; the design has no copy for it. UI only.
  - Once the tab has scrolled to a chip's line, the model keeps that request's serial (`AppModel.lineScrollHandled`,
    `handledLineScrolls`), so showing the tab again starts at its top. The request itself keeps its line: a request
    rewritten without it would read as a badge's first-hunk request, which keeps its rule (only on a change). Pinned
    by `AppModelTests.aChipOpensTheDiffAtItsLineOrTheUnchangedFilesTab`.
  - The code capture is `DiffLayout.lines(in:side:rows:newLines:)` (`CommentAnchor.capture` without the context lines)
    and the box's row `DiffLayout.rowId(for:in:)`. Pinned by `DiffLayoutTests.aCommentsCodeComesFromTheFileOrTheRows`
    and `theBoxOpensUnderTheRowOfItsLastLineOnItsSide`.
  - Send is drawn with `RockyPrimaryButtonStyle`, Rocky's white filled button, not the gray `RockyFilledButtonStyle`
    Task 24 names: `CMT-02` says "white filled". UI only.
  - The chip is `FileBadgeLook(range:)`; its tooltip is the absolute path (with "~") and the range, since the
    transcript keeps the absolute entry. A queued comment's delete button reads "Remove" ("Remove this queued
    comment"). The box's text is a `TextEditor` sized by a hidden copy of its text, since a `TextEditor` does not grow;
    its 22-point lines come from `lineSpacing`. UI only, on the manual checklist.
  - `LineRangeAttachment(entry:)` takes the last "#" and only ASCII digits from 1, with the end not before the start.
    A user message whose one attached file's name itself ends in "#L<n>" would read as a line comment. Pinned by
    `LineRangeAttachmentTests`.
  - Still to tell the designer, as the Decisions ask: the entry is an absolute path, and ↑ history and a queued
    comment's Edit skip comments.
- **2026-09-24, Tasks 28–30 (file icons), what the tasks did not settle:**
  - **587 SVGs, not 586.** `github-actions-workflow`, the workflow rule's icon, is one of the 9 icons reached only
    through `languageIds`, so the 586 that `fileNames`, `fileExtensions` and `file` reference leave it out. The script
    adds it (`LANGUAGE_ID_ICONS`) and stops if no language id uses it any more. 493,218 bytes of SVG. Tell the
    designer (FIL-09 says 586). Pinned by `FileIconsTests.everyIconTheVendoredManifestNamesShips`.
  - The script checks npm's `sha512` integrity of the tarball as well as its name and version, and names each SVG by
    its icon id, since 20 definitions point at `<id>.clone.svg` files. It stops on two keys equal but for case. The
    manifest keeps the theme's keys as they are, sorted, one per line, so a version bump reads as a diff.
    `FileIconManifest` lowercases them when it is made, and keeps the path tails apart, keyed by their components, so
    a lookup builds only its own path's tails (all 204 have two components today). Pinned by
    `theManifestIgnoresCaseInItsKeys` and `aPathTailMatchesOnWholeComponents`.
  - The workflow rule is checked first, as in the mock: otherwise `yml` → yaml (step 4) would always win. It matches
    anywhere under a `.github/workflows/` folder, subfolders included, as the GitHub Actions extension's
    `**/.github/workflows/**/*.yml` does. Pinned by `workflowsUnderGitHubWorkflowsGetTheActionsIcon`.
  - Steps 3 and 4 are one pass, as in VS Code: the name after each of its dots, from the first, so the longest
    extension is tried first. A dotfile's name after its dot counts as an extension (`.env` → tune, FIL-09's example).
    Pinned by `theLongestCompoundExtensionWins` and `theExtensionComesNext`.
  - RockyKitTests cannot see RockyUI's bundle, so two tests read the vendored manifest from the source tree
    (`#filePath`): FIL-09's examples, and an SVG for every id it can return. Pinned by
    `theVendoredManifestGivesTheRequirementsExamples`.
  - `FileTreeIcon` takes the row's worktree-relative path instead of its name, so the path tails and the workflow rule
    work in the tree, the filter and Quick Open.
  - Two places beyond Task 29's list draw the icon, since FIL-09 says "everywhere a file's icon is drawn": the tabs
    of files outside the worktree (`WorkspaceDetailView`, 12 points) and the hover preview's card for a file with no
    preview (`FilePreviewContent`, 22 points). A folder keeps the blue folder there and in `FileBadgeLook`. UI only.
  - If an SVG fails to load, the fallback symbol is drawn at 80 % of the icon's size. All 587 load in `NSImage`
    (checked once with a throwaway script, not committed). `bithound.svg` (`.bithoundrc`) draws almost blank in
    AppKit: its root sets `fill-opacity=".05"`. The icons are vendored as the theme ships them, so it stays. UI only.
  - Not observed: the app was not built with `scripts/make-app.sh` or launched. Task 30's manual checks are open in
    `m3-verification.md`.
- **2026-09-24, Tasks 31–34 (the default app, the path chip and "+"), what the tasks did not settle:**
  - The kit's side is `OpenApp` (`.finder`, `.editor(ExternalEditor)`, with its `bundleIdentifier` and
    `displayName`) and `DefaultOpenApp` (`storageKey`, `resolve`), in `RockyKit/App/DefaultOpenApp.swift` beside
    `ExternalEditor`. A stored id Rocky does not know falls back like an uninstalled editor. Pinned by
    `DefaultOpenAppTests`.
  - RockyUI's `InstalledApp` pairs an `OpenApp` with its bundle on this Mac, for the icon and for opening. It is public
    because ⌘O's command lives in the `Rocky` target. The split button resolves the default when it draws and again on
    each click, the menu its apps when it opens, the chip when it draws and on its click, and ⌘O its title when the
    menu bar reads it and again when it runs. An editor removed while Rocky runs can leave the button's icon stale
    until it redraws; the click still resolves afresh. UI only.
  - Finder opens the worktree with `NSWorkspace.open(_:)` as before, with no toast on failure, as before. A file goes
    to `activateFileViewerSelecting`. ⌘O's command has no `ToastPresenter`, so its failure goes through
    `AppModel.onToast`; `ExternalEditorOpener.open` gained a variant that takes the toast as a closure.
  - ⌘O is not disabled while a settings panel is open, unlike ⌘S and ⌘P: OPN-02 names only "no workspace selected".
    The split button's left part shows `fillPressed` while pressed, like `RockyIconButtonStyle`; TB-03 names only the
    hover. UI only.
  - `PathChip` (`DiffTabView.swift`) also replaces the path of a file tab opened from a badge outside the worktree
    (`FileTabView`), where OPN-02 says "the diff and file tab headers". There it shows the full path with "~" instead
    of the absolute path as selectable text, keeps the "Show in Finder" and "Open in its app" buttons, and the header
    is now 34 tall like a diff tab's (it was 8 points of padding around its content), so the chip sits the same in
    both. A folder a badge opened keeps the blue folder in the chip. The chip does not check the disk, so a file tab
    whose file is gone still opens. UI only.
  - The chip's tooltip ("Open in Zed", "Reveal in Finder") replaces the header's path tooltip; the tab keeps the path
    as its tooltip, and a rename's "old → new" is in the chip's text. VoiceOver reads the path, with the tooltip as the
    hint. A deleted file's plain path has no padding either, as the mock's `.path-chip.plain`. UI only.
  - `AppModel.defaultAgent(repoId:)` (internal) falls back to Claude Code when the store read fails, without an error:
    a new conversation must not wait on it. `lastUsedAgent` breaks a tie in `createdAt` by rowid, and an agent this
    build does not know in the newest message reads as nil, so Claude Code, rather than an older message's agent.
    Pinned by `RockyStoreTests.lastUsedAgentFollowsTheNewestUserMessageAcrossTheRepository` and
    `AppModelTests.theDefaultAgentFollowsTheLastUserMessageInTheRepository`.
  - CNV-01's Motion, which Task 33 does not list: a conversation tab that joins after the strip's first load enters
    with `ChatView`'s `Entrance` (now internal), tracked in `ConversationTabs.drawnConversationIds`, so switching
    workspaces plays nothing. UI only.
  - "+" takes no second `.clickable()`: `RockyIconButtonStyle` already sets it. The bridge keeps the old menu's width,
    280. `MenuIconButtonLabel` had no user left and is gone.
  - Not observed: the app was not built with `scripts/make-app.sh` or launched, so OPN-02's unknown (whether Zed reuses
    the worktree's window for the chip's file) is still open. Task 34's manual checks are open in `m3-verification.md`.
- **2026-09-25, the designer's update to Tasks 35–36 (`CMT-05` History, Resend, Running and Kit; `CMT-06` In the
  box).** It supersedes Task 35 where they differ:
  1. **A queued comment has Edit again**, offered only while the message box is empty, like any queued row. It puts
     the chip and the text back in the box through ↑'s path (`ComposerController.load(text:files:lineRange:)`), drops
     the code captured at Send, and the next Send reads the lines again. Task 35's "A queued comment row still has no
     Edit" and the Decisions' "queued Edit skip comments" no longer hold. The kit side is the queued message keeping
     the comment's range and files: pinned by `ChatSessionModelTests.aLineCommentWithFilesSendsTheBlockThenTheirLinks`
     (its queued row); the box itself is UI, on the manual checklist.
  2. **All or nothing.** If any line of the range cannot be read, the block goes with no code, never part of it.
     `ReviewPrompt.single`'s `code` is optional, and nil gives the header and the comment. Pinned by
     `ReviewPromptTests.noCodeOnTheNewSideGivesTheHeaderAndTheComment`,
     `noCodeOnTheRemovedSideGivesTheHeaderAndTheComment` and `AppModelTests.aRangePastTheEndOfTheFileGivesTheBlockWithoutCode`.
  3. **The caret and edits.** The caret and every selection start after the chip (`ComposerTextView.setSelectedRanges`),
     Backspace at the start of the text removes it (`deleteBackward`), and a drop before it is refused
     (`shouldChangeText(inRanges:replacementStrings:)`). Since no selection holds the chip, copying and dragging never
     write it, so it cannot be pasted twice or into the middle of the text. UI only, on the manual checklist.
  4. **Slash commands.** With the chip first, a "/" at the start of the text is not a command (CMD-01): the chip is an
     attachment at the start, so the popup stays closed (`SlashQuery.parse`'s `firstIsAttachment`), "+" ▸ Commands does
     nothing, and the message goes as a line comment, never through CMD-08's terminal commands. Pinned by
     `ChatSessionModelTests.aLineCommentStartingWithASlashIsNoCommand` and the existing
     `SlashCommandTests` case of a badge before the "/".
  5. **The history test**: `MessageHistoryTests.upStopsOnALineComment`.
- **2026-09-25, Tasks 35–36 (↑ brings a line comment back), what the tasks did not settle:**
  - The history is built in RockyKit, `MessageHistory.entries(from:)`, so "history entries keep their line range" is a
    test (`MessageHistoryTests.historyEntriesKeepTheirLineRange`); `ChatView` used to build it inline.
  - Files next to a chip travel in `LineComment.files`. The transcript keeps the chip's entry first and the files after
    it, so `ChatItem.lineRange` is now "the first attachment is an entry and no other one is" (it was "the one
    attachment"), and `ChatItem.attachedFiles` gives the files without the chip. Two entries still make no line
    comment. A queued comment keeps its files as the row's attachments, for its badges and its Edit. Pinned by
    `LineRangeAttachmentTests.aUserMessageStartingWithOneEntryIsALineComment` and
    `ChatSessionModelTests.aLineCommentWithFilesSendsTheBlockThenTheirLinks`.
  - In the block, each file's marker reads as the file's name (`ReviewPrompt.comment(_:naming:)`): the block is one
    text block never split at a marker, so a marker would have reached the agent as U+FFFC. Pinned by
    `ReviewPromptTests.filesInACommentReadAsTheirNames` and
    `AppModelTests.aResentCommentReadsTheNewSideFromTheWorktreeAndTheRemovedSideFromTheBase`.
  - The removed side uses the base commit and a rename's old path the diff uses while the changes are read
    (`editorBaseKey`), and otherwise finds the base then (`GitChangesService.base`, one `git merge-base` per resend of
    a removed-side comment, on the user's Send only), at the chip's path: a renamed file whose changes are not read
    gives no code. The base's text is split as the patch splits the removed rows (`DiffParser.lines`), and a binary
    base gives no code. A chip outside the worktree keeps its absolute path in the block and has no removed side. Both
    paths are pinned by `aResentCommentReadsTheNewSideFromTheWorktreeAndTheRemovedSideFromTheBase`.
  - A comment needs words: with the chip in the box, Send and Return do nothing until there is text other than spaces,
    as the comment box's Send (CMT-02). The chip alone, or with only files, does not send. A queued row's Edit is off
    while the box holds a chip, since loading would replace it. UI only.
  - The chip in the box is `LineChipAttachment`, an image of `FileBadgeLook(range:)` with a 6-point gap after it in its
    own bounds, so the text starts clear of it with no space character to delete. It has no hover, X, preview or click,
    unlike a file badge: `CMT-06` names only Backspace. UI only.
  - `AppModel.lineComment(for:comment:files:workspaceId:)` takes `files` (default none) beside the plan's signature.
    The message box sends through the conversation's own chat (`ChatSessionModel.send(_:)`, which queues during a
    turn), not `sendLineComment`: the chat is on screen, so no toast is needed. The block is built before the send,
    after a file read, so a typed message sent in that instant can reach the queue first. Not pinned: it is a race.
  - Not observed: the app was not built with `scripts/make-app.sh` or launched. Task 36's manual checks are open in
    `m3-verification.md`.
- **2026-09-25, Tasks 37–38 (line counts on edit rows), what the tasks did not settle:**
  - The events are `SessionEvent.toolCall` and `.toolCallUpdate`; `ACPUpdate` does not exist. Both gained `diffs`.
    The installed adapter is claude-agent-acp 0.81.2, whose `dist/diff.js` has 0.81.0's shape.
  - The whole count runs off the main actor, in a detached task as the All files filter ranks, rules 1 and 2 included,
    so there is one path; the label shows a moment after the completion. Each call keeps the serial of its latest
    count, and a newer update drops a count still running.
  - A count that lands during its turn is saved with the turn's items; one that lands after is saved at once. Saving
    it earlier would give the row its `seq` ahead of the items before it, since `upsert` numbers a row on its first
    write. Pinned by `ChatSessionModelTests.editCountsAppearOnCompletionFromTheLatestContent` and
    `anUpdateWithContentReplacesTheCountsAndOneWithoutKeepsThem`.
  - An update whose content holds no diff (text, a terminal) is no longer `.ignored` when it carries nothing else: its
    `diffs` is empty, and it takes a completed call's counts away, as it replaces the content. Pinned by
    `ACPProtocolTests.anUpdateWithContentButNoDiffReplacesTheEntries` and `ChatSessionModelTests.aRejectedEditHasNoCounts`.
  - The entries wait only until their call completes. A failed call drops them at once, and a turn that ends drops
    those of calls that never completed.
  - Lines split on the "\n" scalar, not on `Character`, since "\r\n" is one `Character`: a file with Windows line
    endings counts its lines. OpenCode sends "" as a new file's `oldText`, and rule 3 adds all its lines. Pinned by
    `ToolDiffStatsTests.aFinalNewlineStartsNoLine` and `aNewFileAddsEveryLine`.
  - An entry without a string `path` and `newText` is left out. `_meta`'s counts must be whole and non-negative, read
    without `JSONValue.intValue`, which traps on a number past `Int`'s range. Pinned by
    `ACPProtocolTests.readsCountsOnlyInTheirKnownShape`.
  - Rule 3 numbers each distinct line and diffs the integers. At the cap, two unrelated sides of 2,500 lines take about
    0.1 s (release, measured once with a throwaway script).
  - `ToolDiffStats.label(for:)` (kit) gives the row's label and the group's, hidden at 0, so both are tests
    (`theLabelSumsTheRowsAndHidesAtZero`). The row's gap of 6 is its spacing of 8 less 2, as the mock's
    `margin-left: -2px`. The group's label sits after its title at the row's spacing, folded or expanded: `DIFF-06` gives
    it no gap and the mock draws no group. UI only.
  - Not observed: the app was not built with `scripts/make-app.sh` or launched. Task 38's manual checks are open in
    `m3-verification.md`.

## Quick Open (FIL-08), after the merge

> Same execution rules as Tasks 1–18: task by task on `fix/m3-editor-and-quick-open`, tests written with each change and
> run once in Task 22, one build at the end, commits only when the user asks. Read `FIL-08`, `FIL-05`, `FIL-04`,
> `KBD-02` and `OUT-10` in the M3 HTML first, and try the mock's "Quick Open (⌘P)" button (the browser prints on ⌘P).

**What exists (checked with `rg` on 2026-09-24; symbols are authoritative, lines are not):**
- `FileTree.rank(_:in:) -> [String]` (`RockyKit/Files/FileTree.swift`): `FIL-04`'s five tiers, stable inside a tier,
  every match (no limit), `list.paths` for an empty query. `FileTree.matches(_:in:)` gives the highlight ranges.
  `FileList.paths` is in Finder's order and never holds ignored or deleted files.
- The list lives in `AppModel.fileTrees[workspaceId]` (`FileTreeState`), made by `prepareFileTree` for the selected
  workspace only and dropped when another is selected. `readFilesOnce` and `refreshShownFilesIfNeeded` run only while
  `showsFiles` (the All files tab on screen). `fileTreeChanged` marks `staleFileTrees[id].list` on FSEvents, and does
  nothing while `fileTrees[id]` is nil.
- `openFromTree(workspaceId:path:keep:)` replaces the preview tab even when `keep` is true; `openDiff` does not.
- ⌘P today: `GoToFileCommand` (`Rocky/RockyApp.swift`, `CommandGroup(replacing: .printItem)`) calls
  `AppModel.goToFile`, which turns the panel to All files and sets `goToFileRequest`; `FilesTab` focuses its filter
  and shows a "⌘P" hint in it.
- Overlays: `RootView` stacks `SettingsModal`, `RepoSettingsModal`, `MenuHost`, `ToastHost`. `MenuPanel`
  (`RockyMenu.swift`): `Theme.panel` at radius 12, a `Theme.hairline` ring, `shadow(.black 0.45, radius 18, y 10)`.
  `MenuHost` catches outside clicks with `Color.black.opacity(0.001)`. `SettingsPresenter` is an `@Observable`
  singleton with its own Esc monitor that yields to `MenuPresenter.isAnyMenuOpen`.
- `ChatView.handleKey` passes events through for a terminal, the editor, `FileFilterFocus`, `CommentComposerFocus`,
  sheets and modal windows; Esc stops the turn otherwise.
- Nothing stores recent files or open tabs. The store's last migration is `v10`.

**Decisions:**
- The panel's radius is 12, `MenuPanel`'s, not the 10 the requirement text says: `FIL-08` asks for "MenuPresenter's
  menu style", and Rocky's menus are drawn at 12. The designer confirmed it and fixed `FIL-08` (2026-09-24).
- Recent files are stored (`v11`), because `FIL-08` keeps them across relaunches. A worktree tab records its file each
  time it is shown by an open (`openDiff`, `openFromTree`, `openBadgeFile`), not by selecting a tab that is already on
  screen. The last 20 per workspace, trimmed on write.
- Quick Open reads git's list itself, at most once per opening, and only when there is no list or an event marked it
  stale. It never makes `showsFiles` true, so events while it is open only mark the list stale: nothing reads while
  typing, and nothing reads per keystroke.
- ⌘P is disabled while a settings panel is open (as ⌘S is, `isAnySettingsPanelOpen`) and with no selected workspace.

### Task 19: Ranking with recent files, and their storage

**Files:** `RockyKit/Files/FileTree.swift` (or a new `RockyKit/Files/QuickOpen.swift`), `RockyKit/Store/RockyStore.swift`,
`RockyKit/Store/Records.swift`; tests in `Tests/RockyKitTests/FileTreeTests.swift` and the store's tests.

- `rank` takes the recent files: `rank(_ query:, in list:, recent: [String] = [])`. Inside each tier the recent files
  come first, newest first, then the rest in Finder's order. The default keeps `FilesTab`'s behavior.
- An empty query's order (`FIL-08`): the recent files still in the list, newest first; then the changed files (the
  order of `WorkspaceChanges`, deleted ones left out) that are not recent; then every other file in Finder's order. A
  pure function in RockyKit, e.g. `QuickOpen.results(query:list:recent:changed:) -> [String]`, which calls `rank` for a
  query.
- Store `v11`: `recentFile(workspaceId TEXT NOT NULL REFERENCES workspace ON DELETE CASCADE, path TEXT NOT NULL,
  openedAt DATETIME NOT NULL, PRIMARY KEY (workspaceId, path))`. `recordRecentFile(path:workspaceId:at:)` upserts and
  keeps the newest 20 of the workspace in the same transaction; `recentFiles(workspaceId:) -> [String]` newest first.
- Tests:
  - A recent file ranks first inside its tier, never above a better tier.
  - The empty query's order, with a recent file that is also changed listed once, as recent.
  - A recent file no longer in the list is left out.
  - `ranks100000PathsInUnder50ms` passes with 20 recent files.
  - The store keeps 20, drops the oldest, moves a reopened file to the front, and deletes with the workspace.

Commit: `feat(kit): rank recent files first and store the last 20 per workspace`

### Task 20: The model: the list for Quick Open, recent files, and the preview fix

**Files:** `RockyKit/App/AppModel.swift`; tests in `Tests/RockyKitTests/AppModelTests.swift`.

- `public func quickOpenWillShow(workspaceId:)`: makes the workspace's `FileTreeState` if needed, loads its recent files
  from the store once per session (`recentFiles[workspaceId]`, public read), and reads git's list only when there is
  none or `staleFileTrees[workspaceId]?.list` is true. The read goes through the same serialized `refreshFiles` path,
  with a gate that admits it (for example a `quickOpenWorkspaceId` checked beside `showsFiles` in `readFilesOnce`), and
  reads only the list, no folder listings. `quickOpenDidHide()` clears the gate.
- Every open of a worktree tab records the file in `recentFiles` and in the store (the decision above). A store failure
  sets `errorMessage` and changes nothing else.
- `FIL-05`'s fix: `openFromTree` with `keep: true` on a file with no tab appends a kept tab and leaves the preview tab
  as it is; only `keep: false` replaces the preview. An open tab is only shown, as today.
- Remove `goToFile`, `goToFileRequest` and `goToFileHandled` (and their use in `removeWorkspace`).
- Tests (with `FakeWorktreeFiles`' `listCount`):
  - `quickOpenReadsTheListOnceWhileItIsCurrent`: two openings with no event in between list once.
  - `quickOpenReadsAgainAfterAnEvent`: an FSEvents batch between openings makes the next one list again.
  - `eventsWhileQuickOpenIsOpenReadNothing`: events while it is open only mark the list stale.
  - `openingToKeepLeavesThePreviewTabAlone`: preview A open, keep-open B, then A is still the preview and B is kept.
  - `openingRecordsARecentFile`: newest first, capped at 20, and back after a new model on the same store.
  - Update or remove `goToFileSelectsTheAllFilesTab`.

Commit: `feat(kit): read the file list for quick open and record recent files`

### Task 21: The Quick Open panel

**Files:** new `RockyUI/QuickOpen.swift` (`QuickOpenPresenter`, `QuickOpenPanel`, its row), `RockyUI/RootView.swift`,
`RockyUI/ChatView.swift`, `RockyUI/FilesTab.swift`, `Rocky/RockyApp.swift`.

- `QuickOpenPresenter`: an `@Observable` singleton like `SettingsPresenter`, with `workspaceId: String?`, `toggle(for:)`,
  `dismiss()`, and a local keyDown monitor while shown that closes on Esc unless `MenuPresenter.isAnyMenuOpen`. Showing
  it calls `model.quickOpenWillShow`, hiding it `model.quickOpenDidHide()`.
- The overlay goes in `RootView` after `RepoSettingsModal` and before `MenuHost`: a full-window click catcher
  (`Color.black.opacity(0.001)`, no dimming) and the panel, 440 wide, centered, `WindowMetrics.titleRowHeight + 12`
  from the top, in `MenuPanel`'s fill, radius (12), ring and shadow. It works with the right panel open or closed and
  never changes it.
- **The entrance runs once** (user report, 2026-09-24: in the mock every keystroke hid and reopened the panel). The
  120 ms fade and 4 pt drop is the transition of the `if` that shows the panel, keyed on the presenter's
  `workspaceId`. Typing, the arrows and hover change only the list's rows and the selection, under no animation (no
  `.id` on the panel, no `withAnimation` around the query). Check it by typing fast in the built app.
- Search: 40 pt, `magnifyingglass`, the field at 14 pt with `stablePlaceholder("Search project files…")` over an empty
  prompt, focused when it opens, a hairline under it.
- Rows: 28 pt, radius 6, 11 visible, then the list scrolls (316 pt tall at most with its 4 pt padding). A row holds the
  `FileKind` icon, the name 13 semibold, the folder 12 `textTertiary` truncated from the head, then at the right end
  the status letter (`ChangeStatusLetter`) and a `clock` glyph on recent files. `FileTree.matches` in `accent`: share
  `FilesTab`'s highlighting code instead of copying it. The first row is selected (`fillSelected`); hover selects;
  the selection scrolls into view.
- Keys, in the field: ↓ / ↑ move and wrap; Return opens with `keep: true`; ⌥Return opens as a preview (`keep: false`);
  Esc closes. A click opens, ⌥-click previews. Opening closes the panel and calls `model.openFromTree`.
- Footer: 32 pt, a hairline on top, "Open ↩" left and "Open as preview ⌥↩" right, 11.5 `textSecondary` text buttons on
  the selected row, disabled with no rows. The shortcut glyphs are 11 mono `textTertiary`.
- States: "No file matches “…”" (12.5 `textTertiary`, centered, 20 pt padding); while there is no list yet, a
  `ProgressLabel` "Reading files…"; a list failure shows its message in the same place.
- Ranking runs off the main actor as in `FilesTab` (cancelled by the next keystroke), with the recent files and the
  changes' paths.
- `ChatView.handleKey`: `return event` while Quick Open is shown, before any other check, so Esc and ⌘U stay with it.
- ⌘P: `GoToFileCommand` becomes File ▸ Go to File… calling `QuickOpenPresenter.shared.toggle(for:)`; it no longer
  opens the right panel. Disabled as decided above.
- `FilesTab`: remove the "⌘P" hint from the filter and the `goToFileRequest` handling (`FIL-04`).
- A11y: the panel is a dialog "Quick Open", the field "Search project files", and a row reads "openapi.ts, src,
  modified, recent".

Commit: `feat(ui): add quick open on cmd+p`

### Task 22: The guide, build, tests and verification

- `docs/README.md` (Spanish guide): Quick Open with ⌘P, its keys, recent files and the preview tab rule. Replace the old
  "⌘P focuses the filter" text.
- Build once, then `swift test` (parallel twice, `--no-parallel` once) and record the counts in
  `docs/superpowers/m3-verification.md` under a new "After the merge" section, with the editor and placeholder fixes.
- Manual, in the built app: ⌘P with the panel open and closed; type fast (the panel must not flicker); ↑/↓ wrap;
  Return and ⌥Return (the preview rule); Esc and a click outside; ⌘P again closes; recent files after a relaunch.

Commit: `docs: record quick open in the guide and the m3 verification`

## Comments like Conductor (CMT-02, CMT-05, CMT-06), after the merge

> Same execution rules as Tasks 19–22. Read the M3 HTML's "Comments" section first: `CMT-01`, the "Revised 2026-09-24"
> note, `CMT-02`, `CMT-05`, `CMT-06`, and `DIFF-02`. Rocky no longer stores review comments: a comment is written in a
> box under the selected lines and goes at once to a conversation, whose transcript keeps it.

**What exists (checked with `rg` on 2026-09-24; symbols are authoritative, lines are not):**
- Stored comments: `DiffCommentRecord` (`Records.swift`), migration `v9` (`diffComment`), `RockyStore.comments`,
  `saveComment`, `deleteComment`; `CommentAnchor` (`relocate`, `reanchor`, `capture`, `placement`); `ReviewPrompt.build`;
  in `AppModel` `diffComments`, `sendingReviews`, `comments(onFile:)`, `readyComments`, `addDiffComment`,
  `editDiffComment`, `deleteDiffComment`, `sendReview`, `markSent`, `applyReanchoring`, `saveComments`,
  `syncDiffComments`, and the re-anchoring inside the changes refresh (`movedComments`). `sendAgentAction`'s `willSend`
  exists only for `sendReview`.
- UI: `CommentViews.swift` (`DiffCommentState`, `CommentAddGlyph`, `CommentComposerFocus`, `DiffCommentComposer`,
  `DiffCommentSlot`, `OutdatedCommentsBox`, `DiffCommentCard`, `CommentStateChip`); `DiffTabView`'s comment slots and
  `saveDraft`; `ChangesTab`'s `ReviewBar` and CHG-03's `CommentCountLabel`.
- `DiffCommentRecord.Side` is also the side of `CommentLine`, `DiffCommentState` and `DiffLayout.gaps(holding:)`.
  `CommentAnchor.placement(...).draftRowId` is the only code that finds the row a box opens under.
- The draft is `@State` in `UnifiedDiffView`: it is lost when the tab or its Diff | Edit mode changes.
- Chat attachments are `[String]` absolute paths (`ChatItem.attachments`, `ChatMessageRecord.attachments`, JSON since
  `v5`). `ChatSessionModel.send(_:attachments: [URL])` and `enqueue` turn each into a `resource_link`
  (`PromptAttachment.file`). `UserMessageRow`, `QueuedMessageRow`, ↑ history (`MessageHistory`) and a queued
  message's Edit all treat every entry as a file.
- `sendAgentAction` sends only to the selected conversation, never queues, and shows the conversation tab.
- A conversation's chat exists only once its tab was shown (`makeChat` is private).
- `ToastPresenter` shows text only and never takes a click.
- `DiffScrollRequest` carries a path, not a line, and scrolls to the first hunk only on a change.
- GRDB 7.11.1 skips an applied migration that the code no longer registers. The only guard is a
  `fatalError` when the target is below the last applied one. Rocky's own database holds one `diffComment` row, already
  sent (read-only check, 2026-09-24).

**Decisions:**
- **Drop the table.** `v9` stays registered, as history. The next free migration drops `diffComment`, so old and new
  databases end with the same schema. The one stored comment was already sent; its conversation keeps it.
- **The line entry is an absolute path with a fragment.** It is `/…/worktree/src/openapi.ts#L18-25`, and
  `…#base-L12-13` for removed lines. The attachments already hold absolute paths, and the chip's click resolves them
  like a file badge (`openBadgeFile`). This departs from `CMT-05`'s relative example; tell the designer.
- **The agent's text is built when the comment is written, and travels with the message.** A queued comment must not
  read its lines after the agent's turn may have edited them. So the message carries its prompt text:
  - The transcript stores the comment and the entry.
  - The agent gets `ReviewPrompt.single`'s block, as one text block and no `resource_link`.
- **↑ history and queued Edit skip comments.** ↑ history leaves out messages with a line entry, because the composer
  cannot hold the chip. A queued comment row offers Send now and Remove, not Edit. Tell the designer.
- **Toast wording:**
  - after a send: "Sent to “<title>”" with Show;
  - when the turn is running: "Queued in “<title>”" with Show.
  
  Show calls `showConversation`.
- **A stopped conversation** is started, and then the comment goes to it, like `sendQueuedNow` does.

### Task 23: The kit: line entries, the prompt, and sending to any conversation

**Files:** `RockyKit/Review/` (`LineRangeAttachment`, `ReviewPrompt`, `CommentLine` with its own `Side`),
`RockyKit/Chat/ChatSessionModel.swift`, `RockyKit/ACP/ACPProtocol.swift`, `RockyKit/App/AppModel.swift`,
`RockyKit/Store/RockyStore.swift`; tests beside each.

- `LineRangeAttachment` (`Sendable`, `Equatable`): `path` (absolute), `side` (`.new` / `.old`), `start`, `end`;
  `init?(entry:)` parses the last `#L<a>[-<b>]` or `#base-L<a>[-<b>]` suffix, and `entry` prints it; a plain path is
  not one.
- `ReviewPrompt.single(path:side:start:end:code:language:comment:) -> String`: the exact text of `CMT-05` for each side
  (path worktree-relative, "lines 18–25", "line 18", "removed lines 12–13 (from the base)"), the fence one backtick
  longer than the longest run in the code (`longestBacktickRun`), `\r` removed. `build` goes.
- `CommentLine` keeps its fields with a `Side` of its own; `DiffLayout.gaps(holding:)` and the tests move to it. The
  row a box opens under moves from `CommentAnchor.placement` to `DiffLayout` (e.g. `rowId(for:in:)`, with its old-side
  fallback). The rest of `CommentAnchor` goes.
- A line comment on the chat side: a message with the comment as its text, the entry as its only attachment, and the
  prompt text. `ChatSessionModel` sends it (one text block, `PromptAttachment` gains a text case or equivalent) and
  queues it (`QueuedMessage` keeps the prompt text); `ChatItem` and its record store only the text and the entry.
- `AppModel.sendLineComment(workspaceId:conversationId:comment:) async -> LineCommentOutcome` (`.sent`, `.queued`,
  `.unavailable`): makes the conversation's chat if needed without selecting it, starts a stopped one, then sends or
  queues. It never changes the selected conversation or the tabs.
- Comment drafts per workspace and diff tab, in `AppModel` like `editors`: the range, its side, the text and the
  chosen conversation. Dropped when the tab closes, the comment is sent, or it is cancelled.
- `DiffScrollRequest` gains an optional `CommentLine`; `openLineRange(workspaceId:attachment:)` opens the diff tab
  scrolled to it, or the file tab when the file is no longer changed.
- Remove the stored comments (every symbol under "What exists"), `sendAgentAction`'s `willSend`, and add the drop
  migration.
- Tests:
  - `LineRangeAttachment` round-trips both sides and one line, and rejects plain paths and malformed fragments.
  - `ReviewPrompt.single` produces the exact text on each side, with a fence inside the code.
  - `ChatSessionModel`: the comment goes out as one text block; while running it is queued and goes out with the text
    built before; the transcript item holds the comment and the entry.
  - `AppModel.sendLineComment`: to a conversation not shown, without selecting it; queued while running; a stopped
    one starts.
  - `openLineRange` opens a changed file's diff with the line request and an unchanged one's file tab.
  - The migration drops `diffComment` and a fresh database has none.
  - Delete the stored-comment tests: `CommentAnchorTests` (keeping `aRowsCommentLineIsItsSidesNumber` and the placement
    test, moved), `sendReview…`, `aRefreshKeepsCommentsOnTheirLinesAndStoresThem`,
    `commentsSurviveARelaunchAndGoWithTheirWorkspace`, `commentsMigrationCreatesTheTable`,
    `removingAWorkspaceRemovesItsComments`.

Commit: `feat(kit): send line comments to any conversation and stop storing review comments`

### Task 24: The comment box (CMT-02)

**Files:** `RockyUI/CommentViews.swift`, `RockyUI/DiffTabView.swift`, `RockyUI/DiffRows.swift`.

- `DiffCommentState` keeps the selection (press, drag, Shift, Esc) and loses editing. It reads and writes the draft
  in the model, so the box comes back after a tab switch.
- The box opens under the range's last row, aligned with the code, at most 560 wide, with the range kept in
  `commentRange`:
  - The head is 34 pt with a hairline under it: "Sending to" (12 `textTertiary`), then a `MenuButton` with the chosen
    conversation's `AgentIcon`, its title (12.5 `textPrimary`) and `chevron.up.chevron.down`.
  - The menu lists the workspace's open conversations, with `MenuItem(isChecked:)` on the chosen one. The default is
    `selectedConversationIds[workspaceId]`.
  - The body holds the chip (CMT-06), fixed and not deletable, then the text: 13 pt on 22-pt lines, at least two lines,
    growing, with the placeholder "Ask about these lines…" through `stablePlaceholder`.
  - The actions are "⌘Return to send" (11.5 `textTertiary`), Cancel, and Send (`RockyFilledButtonStyle`, white,
    disabled while the text is empty).
  - Send reads "Queue" while the chosen conversation's turn runs. Its tooltip is "<agent> is working; this goes out when
    its turn ends".
- Keys:
  - ⌘Return sends and Return adds a new line.
  - Esc closes an empty box. With text, it first asks "Discard this comment?" in Rocky's style.
  - `CommentComposerFocus` still keeps Esc from `ChatView`.
- Sending captures the code: the new side from the worktree lines (`newLines`), the removed side from the removed
  rows. It builds `ReviewPrompt.single` and calls `sendLineComment`. The box closes and the diff stays on screen.
- Delete `DiffCommentSlot`, `OutdatedCommentsBox`, `DiffCommentCard`, `CommentStateChip` and the slots in
  `DiffTabView`.

Commit: `feat(ui): write a comment under the lines and send it to a chosen conversation`

### Task 25: The line chip (CMT-06), the transcript and the toast

**Files:** `RockyUI/FileBadge.swift` (or a new `LineChip`), `RockyUI/ActivityRows.swift`,
`RockyUI/QueuedMessagesView.swift`, `RockyUI/ChatView.swift`, `RockyUI/Toast.swift`, `RockyUI/DiffTabView.swift`.

- The chip:
  - It is 22 pt, radius 6, a 1 pt hairline border, on white 4 %.
  - A 22 pt left segment holds the `FileKind` icon (12) and a hairline divider.
  - Then the name (12 `textPrimary`) and the range (12 `textSecondary`, tabular): "+18–25", "−12–13", "+18".
  - The tooltip is the path and the range. Reuse `FileBadgeLook` rather than drawing a second one.
- `UserMessageRow` and `QueuedMessageRow` show a message with a line entry as the chip on top and the text under it,
  never as a file badge. A click calls `openLineRange`.
- ↑ history skips messages with a line entry. A queued comment row has Send now and Remove, and no Edit.
- `ToastPresenter` takes an optional action: `show(_:action:)`, with a `Show` text button.
  - Only the toast takes clicks, and only while it has an action.
  - An action keeps it up longer, 4 s.
  - The box's send shows "Sent to “…”" or "Queued in “…”".
- `DiffTabView` scrolls to a line request's row, also when the tab first appears. The gaps that hold the line open
  first.

Commit: `feat(ui): show line comments as chips in the chat and toast where they went`

### Task 26: The Changes tab and the numbers

**Files:** `RockyUI/ChangesTab.swift`, `RockyUI/DiffRows.swift`.

- Remove `ReviewBar` and CHG-03's comment count, `commentText` and their accessibility text.
- `DiffRows` already draws `DIFF-02`'s one number column. Check that its doc comments match `CMT-01`: the "+" sits
  over that number, and a removed row comments on the removed side.

Commit: `refactor(ui): drop the comments bar and counts from the changes tab`

### Task 27: The guide, build, tests and verification

- `docs/README.md`: rewrite the comments section for the box, "Sending to", the queue, the chip and its click. Remove
  "Send to agent", Pending, Sent and Outdated. Mention the diff's one number column.
- Build once, then `swift test` (parallel twice, `--no-parallel` once). Record the counts in `m3-verification.md`'s
  "After the merge".
- Manual checks in the built app:
  - comment on new lines and on removed lines;
  - send to a conversation that is not shown, and see it arrive;
  - send while a turn runs, and see it queued and then sent;
  - the chip's click;
  - Esc with and without text;
  - the draft after a tab switch;
  - the toast's Show.

Commit: `docs: record comments like conductor in the guide and the m3 verification`

## File icons (FIL-09), after the merge

> Same execution rules as Tasks 19–27. Read `FIL-09` in the M3 HTML first, and the requirements that now point at it
> (`FIL-02`, `FIL-05`, `FIL-08`, `CHG-03`, `DIFF-01`, `CMT-06`). User decision, 2026-09-24: Material Icon Theme, files
> only; folders keep the blue folder.

**What exists:** `FileKind` (`RockyUI/FileBadge.swift`) draws an SF Symbol and a color per category. It is used by
`FileTreeIcon` (tree, Quick Open), `DiffTabIcon` (tabs), `FileBadgeLook` (chat badges, composer attachments, the line
chip) and the Changes rows. Bundled SVG marks load through `Bundle.module.url(forResource:withExtension:subdirectory:
"Icons")` into `NSImage` (`AgentIcon`, `SidebarRow`'s git glyphs). `README.md` credits Prism and Simple Icons.

**Decisions:**
- **A committed script vendors the icons.** `scripts/vendor-file-icons.py` downloads the pinned npm tarball
  (`material-icon-theme` 5.38.1) and checks its version. It copies the icons `fileNames`, `fileExtensions` and `file`
  reference, plus `LICENSE`, into `Sources/RockyUI/Resources/FileIcons/`. It writes the trimmed manifest there as
  `manifest.json`. Running it again gives the same files.
- `FileKind` stays: it decides what opens in the editor, and its symbol is the fallback when an SVG fails to load.
  Folders keep `FileKind.folder`.
- The lookup is pure and lives in RockyKit. It takes the manifest as a value, so tests use small handmade manifests.
  RockyUI decodes the bundled manifest once.

### Task 28: The icons, the manifest and the lookup

**Files:** `scripts/vendor-file-icons.py`, `Sources/RockyUI/Resources/FileIcons/` (generated), `Package.swift`
(`.copy("Resources/FileIcons")` and its credit comment), `README.md`,
`Sources/RockyKit/Files/FileIcons.swift`, `Tests/RockyKitTests/FileIconsTests.swift`.

- `FileIconManifest` (`Decodable`, `Sendable`) holds `fileNames`, `fileExtensions` and `file`.
- `FileIcons.iconId(forPath:manifest:) -> String` applies `FIL-09`'s order, case-insensitive:
  1. the longest path tail in `fileNames`, matched on component boundaries, relative or absolute;
  2. the file name;
  3. the longest compound extension;
  4. the extension;
  5. the default.
  
  The `.github/workflows/*.yml|yaml` rule gives `github-actions-workflow`.
- Tests: one per step. Each covers case-insensitivity, the longest match winning (`d.ts` and `test.ts` over `ts`), a
  path tail against an absolute path, and the workflow rule both inside and outside `.github/workflows/`. A file with
  no extension and no name match gets the default.
- `README.md` credits Material Icon Theme 5.38.1 (MIT, © 2025 Material Extensions) next to Prism, and names the
  script.

Commit: `feat(kit): vendor material icon theme's file icons and look them up by path`

### Task 29: Drawing them everywhere

**Files:** a new `RockyUI/FileIcon.swift` (the view and its cache), `FilesTab.swift`, `QuickOpen.swift`,
`ChangesTab.swift`, `DiffTabView.swift`, `FileTabView.swift`, `FileBadge.swift`.

- `FileIcon(path:size:)` draws the SVG of `FileIcons.iconId`. It uses `Image(nsImage:)`, resizable, at `Zoom.shared(size)`,
  drawn as a vector at any viewBox. Images are cached per icon id on the main actor, and the manifest is decoded once.
  If an SVG fails to load, it falls back to `FileKind`'s symbol and color. It is hidden from accessibility.
- It replaces `FileKind`'s symbol for files, in these places and at these sizes:
  - 14 pt: the tree and Quick Open rows (`FileTreeIcon`), Changes rows (after the status letter), and the diff and
    file tab headers (before the path);
  - 12 pt: unchanged tabs (`DiffTabIcon`; changed ones keep their letter), `FileBadgeLook` (chat badges, composer
    attachments, the line chip).
  
  Folders keep the blue folder.
- Ignored files draw their icon at 50 %.
- Energy: no disk reads per row beyond the first load of each icon id; nothing at rest.

Commit: `feat(ui): draw each file's material icon`

### Task 30: The guide, build, tests and verification

- `docs/README.md`: file icons in the All files section, with the credit.
- Build once, then `swift test` (parallel twice, `--no-parallel` once). Record the counts in `m3-verification.md`.
- Manual checks: the tree with `.ts`, `.tsx`, `.test.ts`, `package.json`, `tsconfig.json`, `README.md`, `.env` (dimmed),
  a workflow `.yml`; Quick Open; a tab; a chat badge; the line chip; zoom at 90 % and 125 %.

Commit: `docs: record file icons in the guide and the m3 verification`

## The default app, the path chip and "+" without a menu, after the merge

> Same execution rules as Tasks 19–30. Read first: `TB-03` (`2026-09-23-sidebar-topbar.html`), `OPN-01` and `OPN-02`
> (`2026-09-23-m2.7-github.html`), `DIFF-01` and `FIL-05` (M3 HTML), and `CNV-01`, `CNV-02`, `KIT-11` and `KIT-13`
> (`2026-09-23-m2.8-conversations.html`, marked "Shipped early").
>
> User decisions, 2026-09-24:
> - The default app is the last one picked in the Open menu, one for all of Rocky.
> - A click on a tab header's path opens the file in that app.
> - "+" creates a conversation at once, with the agent last used in the repository.
> - A right-click on "+" shows today's two items, as a bridge until M2.8's agent rail.

**What exists:**
- `WorkspaceDetailView.openMenu` is already simplified: Finder and the editors by name, a divider, New Terminal, Copy
  Path, 200 wide.
- `ExternalEditor.installed(lookup:)` and `ExternalEditorOpener.open(_:in:app:toasts:)` open a folder or a file.
- The "+" is `MenuButton(id: "new-conversation-…")` in `WorkspaceDetailView`, and it calls
  `AppModel.newConversation(workspace:agent:)`.
- `showConversations` creates a Claude Code conversation when a workspace has none.
- `DiffTabHeader` and `FileTabView`'s header draw the path as text.

### Task 31: The default app (OPN-02) and the split button (TB-03)

**Files:** RockyKit (`DefaultOpenApp`, with its tests), `RockyUI/WorkspaceDetailView.swift`, `Rocky/RockyApp.swift`.

- `DefaultOpenApp.resolve(stored:installed:) -> OpenApp` (`.finder` / `.editor(ExternalEditor)`) is pure, with
  `OPN-02`'s five tests:
  - the stored app when installed;
  - the first installed editor when nothing is stored;
  - Finder with none installed;
  - the fallback when the stored app is uninstalled, keeping the stored value;
  - Finder stored.
- `@AppStorage("defaultOpenApp")` holds the bundle id. It is resolved on each use, with no cache and no polling.
- The split button follows `TB-03`'s values:
  - the left part (30 wide) shows the default app's icon at 16 pt and opens the worktree in it; its tooltip is "Open in
    <app> (⌘O)";
  - then a 1 × 16 divider;
  - the right part (22 wide) holds the chevron that opens the menu, with `fillSelected` while the menu is open.
- In the menu, the default app's item shows the "⌘O" shortcut. Picking Finder or an editor opens the worktree there
  and makes it the default; New Terminal and Copy Path leave the default alone.
- File ▸ "Open in <app>" (⌘O) goes in `CommandGroup(after: .newItem)`, disabled with no selected workspace.

Commit: `feat(ui): open the worktree in the default app from a split button`

### Task 32: The path chip (DIFF-01, FIL-05)

**Files:** `RockyUI/DiffTabView.swift`, `RockyUI/FileTabView.swift` (and a shared chip view).

- The chip is 24 pt, radius 6, a 1 px hairline ring, padding 0 8 and gap 6. It holds the `FileIcon` (14), the folder in
  `textTertiary` and the name in `textPrimary`, at 12.5, with `fillHover` on hover.
- A click opens the file in the default app: `NSWorkspace.open([fileURL], withApplicationAt:)` for an editor, and
  `activateFileViewerSelecting` for Finder. A failure shows a toast. The tooltip is "Open in <app>", or "Reveal in
  Finder".
- A deleted file's path stays plain text, with no ring, hover or tooltip. The "⋯" menu keeps Open in Finder and Copy
  Path.

Commit: `feat(ui): open a tab's file in the default app from its path`

### Task 33: "+" creates at once (CNV-01, CNV-02, KIT-13)

**Files:** `RockyKit/Store/RockyStore.swift`, `RockyKit/App/AppModel.swift`, `RockyUI/WorkspaceDetailView.swift`;
tests in the store's and the model's tests.

- `RockyStore.lastUsedAgent(repoId:) -> AgentKind?` is `KIT-13`'s one query, `chatMessage` → `chatSession` →
  `workspace`. Its tests:
  - across two workspaces of a repository;
  - another repository's messages ignored;
  - a closed tab still counts;
  - nil with no messages.
- `AppModel.newConversation(workspace:)` uses the default agent, `lastUsedAgent` or else Claude Code. `showConversations`
  first conversation uses the same rule. `newConversation(workspace:agent:)` stays for the bridge. Test: the default
  agent follows the last user message in the repository.
- "+" becomes a `Button` in `RockyIconButtonStyle` with `.clickable()` and the tooltip "New conversation". One click
  adds the tab at the end, selects it and focuses the message box.
- The bridge is `.rockyContextMenu(id:)` on "+", with "New Claude Code conversation" and "New OpenCode conversation".
  A pick there does not change the default by itself.

Commit: `feat(ui): create a conversation at once with the last agent used`

### Task 34: The guide, build, tests and verification

- `docs/README.md` covers:
  - the split button, ⌘O and how the default is picked;
  - the path chip;
  - "+" and its right-click.
- Build once, then `swift test` (parallel twice, `--no-parallel` once). Record the counts in `m3-verification.md`.
- Manual checks:
  - ⌘O and the split button with Zed, VS Code and Finder;
  - picking another app changes the button;
  - the path chip opens the file in Zed, whether Zed reuses the worktree's window (`OPN-02`'s unknown);
  - a deleted file's plain path;
  - "+" with the last agent, and its right-click.

Commit: `docs: record the default app, the path chip and new conversations in the guide`

## ↑ brings a line comment back (CMT-05 History), after the merge

> Same execution rules as Tasks 19–34. User decision, 2026-09-25, after ↑ skipped a line comment and loaded an older,
> pre-redesign review prompt: "Chip y texto". The designer is updating `CMT-05` History and `CMT-06`.

**What exists:**
- `ChatView` builds the composer's history from `chat.items` and leaves out messages with a `lineRange`
  (`ChatView.swift`, `MessageHistory.Entry(text:files:)`).
- The composer (`Composer.swift`) holds files as `FileAttachment` (`NSTextAttachment`) at `PromptAttachment.marker`.
  It loads an entry with `load(_:)` and gives back `(text, files)`.
- A line comment goes out through `AppModel.sendLineComment` / `ChatSessionModel.send(_: LineComment)`, with the prompt
  text built by the comment box from the diff's rows (`DiffLayout.lines`, `ReviewPrompt.single`).
- The base's text comes from `AppModel.loadEditorBase` / `editorBaseText` (EDIT-04).

### Task 35: The line chip in the message box

**Files:** `RockyKit/Chat/MessageHistory.swift`, `RockyKit/App/AppModel.swift`, `RockyUI/Composer.swift`,
`RockyUI/ChatView.swift`; tests in `MessageHistoryTests` / `AppModelTests`.

- `MessageHistory.Entry` carries an optional `LineRangeAttachment`. The history keeps line-comment messages again.
- The composer can hold at most one line chip, at the start, drawn as `CMT-06`'s chip (`FileBadgeLook(range:)`). ↑
  and ↓ load it with the text. Backspace over it removes it, and the message then goes as a normal one. Nothing else
  inserts a line chip.
- Sending a message that holds a line chip builds the agent's block at send time. `AppModel.lineComment(for:comment:
  workspaceId:) async -> LineComment` reads the lines:
  - the new side from the worktree file;
  - the removed side from the base, like `EDIT-04`, both through `Task.blocking`.
  
  It then calls `ReviewPrompt.single`. The comment is sent or queued as a `LineComment`, like the comment box's, so
  the transcript shows the chip. If the lines can't be read (the file is gone, or the range is past its end), the
  block goes without the code: "Comment on <path>, lines a–b:" and the comment. Files attached next to a line chip go
  as `resource_link`s after the block.
- A queued comment row still has no Edit (scope: the user asked about ↑ only).
- Tests:
  - history entries keep their line range;
  - `lineComment(for:)` reads the new side from the worktree and the removed side from the base;
  - a range past the end of the file gives the block without code;
  - the transcript item of a resent comment holds the chip and the text.

Commit: `feat(ui): bring a line comment back with its chip on the up arrow`

### Task 36: The guide, build, tests and verification

- `docs/README.md`: ↑ on a comment brings back the chip and the text, and resending reads the lines again.
- Build once, then `swift test` (parallel twice, `--no-parallel` once). Record the counts in `m3-verification.md`.
- Manual checks:
  - ↑ after a comment;
  - resend it;
  - remove the chip with Backspace and send;
  - ↑ on a comment about removed lines.

Commit: `docs: record the up arrow on line comments in the guide`

## Line counts on edit rows (DIFF-06), after the merge

> Same execution rules as Tasks 19–36. Read `DIFF-06` in the M3 HTML: it settles the counting, the cap, the
> storage and the test list. This section adds only what the code already holds.
>
> The request (2026-09-25): "en las ediciones a los archivos, sería bueno también ver cuántas líneas quitó y agregó".

**What exists:**
- `ACPUpdate.toolCall` and `toolCallUpdate` (`ACPProtocol.swift`) parse id, title, status, kind and paths, never
  `content`.
- `ChatSessionModel` applies them to `ChatItem` (`.tool` rows).
- `ChatMessageRecord` persists items, and has no stats.
- `ToolCallRow` and the group header draw the rows (`ActivityRows.swift`).
- `DiffStat` and `DiffStatLabel` draw M3's `+a −d`.
- Claude's per-hunk stats are at `_meta.jetbrains.air.diffStats` `{version: 1, added, removed}`
  (claude-agent-acp 0.81.0, `dist/diff.js`, `air-extension.js`), not `_meta.diffStats`.

### Task 37: Counting and storing (kit)

**Files:** `RockyKit/ACP/ACPProtocol.swift`, a new `RockyKit/Chat/ToolDiffStats.swift`, `RockyKit/Chat/ChatSessionModel.swift`,
`RockyKit/Store/RockyStore.swift`, `RockyKit/Store/Records.swift`, `RockyKit/App/AppModel.swift` (the record mapping);
tests beside each.

- `ToolCallDiff`: path, `oldText?`, `newText`, and the stats from `_meta`. `ACPUpdate.toolCall` and `toolCallUpdate` get
  `diffs: [ToolCallDiff]?`, which is nil when the update carries no `content`.
- `ToolDiffStats.count(_:) -> DiffStat?` follows `DIFF-06`'s order:
  1. the stats;
  2. `oldText` nil counts all of `newText`'s lines as added;
  3. otherwise a `CollectionDifference` line diff, capped at 5,000 lines for both sides together.

  A final newline does not start a line. If any entry cannot be counted, the result is nil.
- `ChatItem.diffStat` is set only when the status is completed, from the latest content. An update with `content`
  replaces the stat, and an update without it keeps it. The line diff runs off the main actor (`Task.blocking` or a
  detached CPU task, as `FilesTab`'s ranking does).
- The next free migration adds nullable `additions` and `deletions` columns to `chatMessage`. Old rows stay nil.
- Tests: `DIFF-06`'s list. At least: Claude's `_meta` path, a new file, a context-line diff, the cap, one uncountable
  entry giving nil, an optimistic diff replaced by the completed one, failed and rejected giving none, and the record
  round trip.

Commit: `feat(kit): count the lines each edit tool call added and removed`

### Task 38: The rows, the group, the guide and verification

**Files:** `RockyUI/ActivityRows.swift`, `docs/README.md`, `docs/superpowers/m3-verification.md`.

- `DiffStatLabel` sits 6 after the badges of a tool row with a stat, showing both numbers, including "+10 −0".
- The "N tool calls" header shows the sum of its rows' stats. It counts each row, so this is not a net change.
- `docs/README.md` explains the counts on edit rows and on the group.
- Build once, then `swift test` (parallel twice, `--no-parallel` once). Record the counts.
- Manual checks, with Claude and with OpenCode: an Edit, a Write of a new file, a rejected edit, and a resumed
  conversation keeping its counts.

Commit: `feat(ui): show each edit's line counts in the chat`

