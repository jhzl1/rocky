# M3 Review and Edit Implementation Plan

**Status: planned, next after M2.7** (user decision, 2026-09-24). Needs M2.7 merged into `development` (its All files and Changes tabs live in M2.7's right panel). The All files tab joins M3 (user decision, 2026-09-24): its tasks are in this plan, Tasks 11–15 (`FIL-01`…`FIL-07`).

> **Execution:** task by task. Tests are written with each change and run once, in Task 18 (global rule `## Tests` in `~/.claude/CLAUDE.md`). Build once, at the end of the tasks, and commit only when the user asks (`CLAUDE.md`); each task's commit line is the message to use then. This plan gives decisions, files, public interfaces, required behavior and the tests to write. It does not carry the code: the implementer writes it.

> **Revised 2026-09-23:** the pull request part (GitHub account, create, checks, merge, sidebar glyphs: `ACC-01`, `PR-01`…`PR-07`, `ROW-07`, former Tasks 12–14) moved to M2.7 (`docs/superpowers/plans/2026-09-23-m2.7-github.md`), and the Changes panel became the Changes tab of M2.7's right panel. The user asked for Conductor's right panel (relayed by dev-1). The file keeps its name so existing links still work.

> **Revised 2026-09-24:** the All files tab joins M3 (user decision): `FIL-01`…`FIL-07`, Tasks 11–15. The designer also changed `CHG-01` (three pills: All files · Changes N · Checks), `KBD-02` (⌘⇧O and the tree's keys; M2.7's panel is ⌥⌘B, and ⌘⇧G is gone) and `OUT-10` (no creating, renaming or deleting files from the tree), and the mock now follows M2.7's final layout (`LAY-01`). The former Tasks 11–13 are now Tasks 16–18.

**Goal:** Inside a workspace, browse the worktree's files and open any of them, see what changed against its base, review it file by file, comment on line ranges and send the comments to the agent, edit files in Rocky, and commit. It all lives in the All files and Changes tabs of M2.7's right panel and in tabs next to the conversations.

**Visual and behavioral source of truth:** `docs/superpowers/design/2026-09-23-m3-review-edit-pr.html`. Open it in a browser. Every requirement has an id (`FIL-02`, `CHG-02`, `DIFF-02`, `CMT-04`, `EDIT-03`…); the same id is on the element of the mock (button "Requirement pins"), in the requirement list on the right of that page, and in the task below that implements it. Values are at 100 % zoom. When the mock and a requirement's text disagree, the text wins. The mock follows M2.7's final layout (`LAY-01`). Its tree, diff, highlighter and git are JavaScript stand-ins: do not port them.

**Architecture:** Same package. RockyKit gains the git layer (`GitChangesService`, `DiffParser`, `FileWatcher`), the worktree's files (`FileTree`, `WorktreeFiles`, `FileContent`), comment logic (`CommentAnchor`, `ReviewPrompt`), buffer rules (`EditBuffer`) and two store migrations. RockyUI gains the All files and Changes tabs of M2.7's right panel, diff and file tabs, comment views, a syntax highlighter on a vendored Prism bundle, the `CodeEditor` and the commit sheet.

**Spec:** `docs/superpowers/specs/2026-09-22-rocky-design.md`, milestone M3, Sections 1 (energy), 4 (diff and comments) and 5 (errors). M2.5 (the shell this builds on): `docs/superpowers/design/2026-09-23-sidebar-topbar.html` and `docs/superpowers/plans/2026-09-23-m2.5-sidebar-topbar.md`. M2.7 (the right panel this adds two tabs to): `docs/superpowers/design/2026-09-23-m2.7-github.html` and `docs/superpowers/plans/2026-09-23-m2.7-github.md`. Read each plan's "Changes during implementation".

## Preconditions

- M2.5, M2.6 and M2.7 are finished and merged into `development`. Create `feat/m3-review-edit-pr` from `development` after that. Never commit on `development` or `main`. The remote is `origin`; push only when the user asks.
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
- The filter field of `FIL-01`'s head: 26 pt, radius 6, `fillControl`, "Filter files", the "⌘⇧O" hint at its right end.
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
  - ⌘⇧O, File ▸ Go to File…, which opens the panel through `RightPanelStorage.openKey` as `PullRequestPanelCommand` does.
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
5. Merge `feat/m3-review-edit-pr` into `development` only with the user's approval.

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
    - ⌘⇧O from the message box and from a terminal, with the panel closed.
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
