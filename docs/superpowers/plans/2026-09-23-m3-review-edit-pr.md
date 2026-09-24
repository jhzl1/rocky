# M3 Review and Edit Implementation Plan

> **Execution:** task by task. Tests are written with each change and run once, in Task 13 (global rule `## Tests` in `~/.claude/CLAUDE.md`). Build and commit follow the rule in force when M3 starts (in M2.5 the user asked for one compile at the end, and commits only when asked). This plan gives decisions, files, public interfaces, required behavior and the tests to write. It does not carry the code: the implementer writes it.

> **Revised 2026-09-23:** the pull request part (GitHub account, create, checks, merge, sidebar glyphs: `ACC-01`, `PR-01`…`PR-07`, `ROW-07`, former Tasks 12–14) moved to M2.7 (`docs/superpowers/plans/2026-09-23-m2.7-github.md`), and the Changes panel became the Changes tab of M2.7's right panel. The user asked for Conductor's right panel (relayed by dev-1). The file keeps its name so existing links still work.

**Goal:** Inside a workspace, see what changed against its base, review it file by file, comment on line ranges and send the comments to the agent, edit files in Rocky, and commit. It all lives in the Changes tab of M2.7's right panel and in diff tabs next to the conversations.

**Visual and behavioral source of truth:** `docs/superpowers/design/2026-09-23-m3-review-edit-pr.html`. Open it in a browser. Every requirement has an id (`CHG-02`, `DIFF-02`, `CMT-04`, `EDIT-03`…); the same id is on the element of the mock (button "Requirement pins"), in the requirement list on the right of that page, and in the task below that implements it. Values are at 100 % zoom. When the mock and a requirement's text disagree, the text wins. The mock's diff, highlighter and git are JavaScript stand-ins: do not port them.

**Architecture:** Same package. RockyKit gains the git layer (`GitChangesService`, `DiffParser`, `FileWatcher`), comment logic (`CommentAnchor`, `ReviewPrompt`), buffer rules (`EditBuffer`) and one store migration. RockyUI gains the Changes tab of M2.7's right panel, diff tabs, comment views, a syntax highlighter on a vendored Prism bundle, the `CodeEditor` and the commit sheet.

**Spec:** `docs/superpowers/specs/2026-09-22-rocky-design.md`, milestone M3, Sections 1 (energy), 4 (diff and comments) and 5 (errors). M2.5 (the shell this builds on): `docs/superpowers/design/2026-09-23-sidebar-topbar.html` and `docs/superpowers/plans/2026-09-23-m2.5-sidebar-topbar.md`. M2.7 (the right panel this adds a tab to): `docs/superpowers/design/2026-09-23-m2.7-github.html` and `docs/superpowers/plans/2026-09-23-m2.7-github.md`. Read each plan's "Changes during implementation".

## Preconditions

- M2.5 and M2.7 are finished and merged into `development`. Create `feat/m3-review-edit-pr` from `development` after that. Never commit on `development`; no remote, never push the Rocky repo.
- Re-read these symbols before Task 1; names below come from the M2.5 and M2.7 plans and their records, and may have moved. **Symbols are authoritative, line numbers are not.**
  - M2.5: `Theme` tokens and `Theme.Motion`, `RockyIconButtonStyle`, `RockyFilledButtonStyle`, `RockyTextButtonStyle`, `.clickable()`, `WindowMetrics.titleBarHeight`, `PanelDivider`, `WorkspaceStatus` (with `mostUrgent(_:)`), `AppModel.status(workspaceId:)`, `WorkingRow`, `ShimmerText`, `CircularProgress`.
  - `WorkspaceDetailView` (top bar row, tabs, the chat/panel split), `ConversationTabs`, `WorkspaceTab`, `FileTabView`, `FileBadge`, `ActivityRows` (`ToolCallRow`).
  - `AppModel`: `selectedWorkspaceId`, `openFiles` / `selectedFiles` / `openFile`, the chats and `ChatSessionModel`'s way to send a prompt, `removeWorkspace(id:skipArchive:)`, `environment(for:)`, `existingProcesses(for:)`.
  - M2.7 (`docs/superpowers/plans/2026-09-23-m2.7-github.md`): `RightPanel` and its tab list `RightPanelTab` (M3 adds `.changes` before `.checks`; the selected tab per workspace lives in `AppModel`), `PullRequestHeaderBar`, `PullRequestHeader` / `HeaderState`, `PullRequestMonitor`, `ChecksTab`, `MergeButton`, `ColumnDivider` (in `PanelDivider.swift`), `Theme.merged`, the toast (`ToastPresenter`), the ⌘⇧G command, `WorkspaceStatus.pullRequest` / `merged`.
  - `RockyStore` migrations (read the latest number: M2.5 added v6, M2.7 adds more), `Repo`, `Workspace`, `ProcessRunner`, `WorktreeService.baseRef(repo:)`.
  - `RepoSettingsView`, `MenuButton`, `MenuItem`, `MenuDivider`, `rockyContextMenu`, `MenuPresenter`, `Zoom.shared`, `Font.rocky`.
- The chat is a plain `VStack` with `ChatItemRow.equatable()` (M2 record), not a `LazyVStack`.

## Decisions

Taken with the user on 2026-09-23:

- **Layout:** the Changes tab of the right panel (M2.7's `PNL-01`); each file's diff opens as a tab next to the conversations. The chat stays visible. (Originally a Changes panel of its own; changed 2026-09-23 when the right panel moved to M2.7.)
- **Unified diff** only. Side by side is out.
- **Editing inside Rocky** with a real code editor, not by jumping to an external editor.
- **All of M3 in one plan:** review, comments, sending comments to the agent, editing and committing. The pull request part moved to M2.7 on 2026-09-23.

Taken in this plan. Change them here, not during implementation:

- **The diff is read-only; editing is a separate mode** (Diff | Edit) of the same tab. Comments live in the diff, typing lives in the editor, and neither has to handle the other's case.
- **Rocky commits** (GIT-04), without the agent, typically your own edits from the editor. M2.7's "Commit and push" (`AGT-02`) asks the agent instead.
- **Discard only uncommitted changes**, and untracked files go to the Trash (GIT-05).
- **Syntax highlighting with Prism vendored in RockyUI and run in JavaScriptCore** (DIFF-04). Textual's own tokenizer is internal and cannot be reused; tree-sitter would add a C dependency per language.
- **The diff is a `LazyVStack` of fixed-height rows** (DIFF-02) so comment cards can sit between rows. Fixed heights avoid the scroll bar jumps that pushed the chat to a `VStack`. Fallback in Known risks.
- **The editor is an `NSTextView`** in an `NSViewRepresentable` with a ruler for the gutter (EDIT-01).
- **One store migration, the next free one,** for comments only.

## Global constraints

- macOS 15 minimum, Swift 6 language mode. No new Swift package. Prism's JavaScript bundle is a resource file of RockyUI; record its version and MIT license in `README.md`.
- **Zoom:** text through `Font.rocky`, text- and icon-holding sizes through `Zoom.shared(_:)`, as in M2.5.
- **Energy (spec Section 1):** no timers that poll the disk. FSEvents per workspace (no process at rest); `git` runs only after a change, debounced; the full diff only for the selected workspace while its Changes tab is visible.
- Menus: Rocky's own (`MenuButton`, `MenuItem`, `rockyContextMenu`); no SwiftUI `Menu` or `.contextMenu`.
- Git runs in the worktree with the workspace environment (`environment(for:)`), through `ProcessRunner`. Never `--no-verify`.
- All code, comments, identifiers and UI copy in English. Commits: Conventional Commits, no AI attribution line.
- Shell: `bat`, `eza`, `rg`, `fd`, `sd`.
- Manual tests on personal repositories only, never a work repository.

## Review Focus

1. At rest, with several workspaces open, Rocky spawns no process (FSEvents only). Checked with Activity Monitor / `CurrentPowerlog.PLSQL` in Task 13.
2. A comment stays on its lines when lines are inserted above it, and turns Outdated when its lines change. Pinned by `CommentAnchorTests`.
3. Saving never overwrites a file the agent changed after it was loaded, unless the user chose Keep Mine. Pinned by `EditBufferTests`.
4. The review prompt has exactly the format of CMT-05. Pinned by `ReviewPromptTests`.
5. Discard never touches committed changes, and untracked files go to the Trash. Pinned by `GitChangesServiceTests.discard…`.

## File structure

```
Sources/RockyKit/Git/DiffParser.swift              new: FileDiff, Hunk, DiffLine, parse
Sources/RockyKit/Git/GitChangesService.swift       new: base, changes, shortstat, commit, discard, push
Sources/RockyKit/Git/FileWatcher.swift             new: FSEventStream wrapper
Sources/RockyKit/Review/CommentAnchor.swift        new
Sources/RockyKit/Review/ReviewPrompt.swift         new
Sources/RockyKit/Edit/EditBuffer.swift             new: clean / dirty / conflict rules
Sources/RockyKit/Store/Records.swift               DiffCommentRecord
Sources/RockyKit/Store/RockyStore.swift            the next free migration, comment CRUD
Sources/RockyKit/App/AppModel.swift                changes, stats, comments, review, commit
Sources/RockyUI/Resources/prism-bundle.js          new (vendored)
Sources/RockyUI/SyntaxHighlighter.swift            new
Sources/RockyUI/ChangesTab.swift                   new: the right panel's Changes tab
Sources/RockyUI/DiffTabView.swift                  new
Sources/RockyUI/DiffRows.swift                     new: rows, hunk headers, gaps
Sources/RockyUI/CommentViews.swift                 new: composer, cards
Sources/RockyUI/CodeEditor.swift                   new
Sources/RockyUI/CommitSheet.swift                  new
Sources/RockyUI/RightPanel.swift                   RightPanelTab.changes, the Changes tab in the row
Sources/RockyUI/WorkspaceDetailView.swift          diff tabs
Sources/RockyUI/FileTabView.swift                  editor for code and text
Sources/RockyUI/ActivityRows.swift                 badges open diffs
Sources/RockyUI/SidebarRow.swift                   diff stats
Sources/Rocky/RockyApp.swift                       commands
Tests/RockyKitTests/DiffParserTests.swift          new
Tests/RockyKitTests/GitChangesServiceTests.swift   new
Tests/RockyKitTests/CommentAnchorTests.swift       new
Tests/RockyKitTests/ReviewPromptTests.swift        new
Tests/RockyKitTests/EditBufferTests.swift          new
Tests/RockyKitTests/RockyStoreTests.swift          comments migration, comments
Tests/RockyKitTests/AppModelTests.swift            comments, review
```

---

### Task 1: Git changes and the diff parser

**Requirements:** `GIT-01`, `GIT-02`.
**Files:** `Sources/RockyKit/Git/DiffParser.swift`, `Sources/RockyKit/Git/GitChangesService.swift`, `Sources/RockyKit/Git/FileWatcher.swift`, `Tests/RockyKitTests/DiffParserTests.swift`, `Tests/RockyKitTests/GitChangesServiceTests.swift`.

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
public actor GitChangesService {
  public init(runner: ProcessRunner)
  public func base(worktree: URL, baseRef: String?) throws -> String
  public func shortstat(worktree: URL, base: String) throws -> (additions: Int, deletions: Int)
  public func changes(worktree: URL, base: String) throws -> WorkspaceChanges
}
public final class FileWatcher: Sendable { init(paths: [URL], excluding: [String], debounce: Duration, onChange: @escaping @Sendable () -> Void); func stop() }
```

It must:
- Follow `GIT-01` exactly: merge-base, `git diff … <base>`, untracked files read and shown as added, uncommitted flags from `git status --porcelain=v1 -z`, the nil-`baseRef` fallback, and the busy check.
- `FileWatcher` watches the worktree and its git directory (resolved from the worktree's `.git` file), excludes `node_modules` and `.git/objects`, and debounces 500 ms.
- Mark a file `isLarge` over 1,500 changed lines or 1 MB (DIFF-03).

Tests:
- `DiffParserTests`: modified with two hunks; added; deleted; renamed with similarity; binary; mode only; `\ No newline at end of file` on each side.
- `GitChangesServiceTests` on temporary repositories: committed + staged + unstaged + untracked all appear; the base is the merge-base after the base branch moves; nil `baseRef` falls back to `origin/HEAD`'s branch; shortstat matches the parsed totals.

Commit `feat(kit): compute workspace changes against their base`.

### Task 2: Sidebar stats and the Changes tab

**Requirements:** `GIT-03`, `CHG-01`, `CHG-02`.
**Files:** `Sources/RockyKit/App/AppModel.swift`, `Sources/RockyUI/ChangesTab.swift` (new), `Sources/RockyUI/RightPanel.swift`, `Sources/RockyUI/SidebarRow.swift`, `Tests/RockyKitTests/AppModelTests.swift`.

```
AppModel
  public private(set) var diffStats: [String: (additions: Int, deletions: Int)]   // every workspace, from shortstat
  public private(set) var changes: [String: WorkspaceChanges]                     // selected workspace, while its Changes tab is visible
  public var isChangesTabVisible: Bool                                            // set by the view: panel open and the Changes tab selected
  public func refreshChanges(workspaceId: String) async
```

It must:
- Start one `FileWatcher` per workspace when the model loads and stop it when the workspace is removed. A change refreshes that workspace's `diffStats`; it refreshes `changes` too when that workspace is selected and its Changes tab is visible.
- The sidebar row shows the stats per `GIT-03` (M2.5's reserved trailing slot).
- Add `RightPanelTab.changes` ("Changes N") before `.checks` in M2.7's tab row (`CHG-01`), and ⌘⇧C: show the panel on this tab, or hide the panel if this tab already shows. No top bar control and no panel of its own: width, divider and open state are M2.7's.
- The tab's content per `CHG-02`: the 30 pt row with the file count, totals and "⋯", the file list, and the comments bar pinned at the bottom.

Tests: `AppModelTests.fileChangeRefreshesTheSidebarStats`, `hiddenChangesTabDoesNotComputeTheFullDiff`.

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
  public private(set) var diffTabs: [String: [String]]          // workspace id → paths, in tab order
  public func openDiff(workspaceId: String, path: String, mode: DiffTabMode = .diff)
  public func closeDiff(workspaceId: String, path: String)
enum DiffTabMode { case diff, edit }
```

It must:
- Add diff tabs after conversations and file tabs, with the status letter, dirty dot and close rules of `DIFF-01`; the header with the Diff | Edit control and "⋯" menu.
- Render `DIFF-02`: fixed 20 pt rows in a `LazyVStack`, both number columns, markers, the diff tokens, hunk headers, collapsed unchanged runs that expand, horizontal scrolling with sticky number columns.
- Handle every case of `DIFF-03`.
- Tool call badges of files present in `changes` open their diff tab (`DIFF-05`).
- Keep M2.5's rules for tabs (`TAB-01`), zoom and the pointing hand.

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
- Add the `TOK-10` tokens to `Theme` (diff fills, `commentRange`, `currentLine`, `merged`, `syntax`).

Commit `feat(ui): highlight code with a vendored prism bundle`.

### Task 6: Comment storage and anchoring

**Requirements:** `CMT-03`, `CMT-04`.
**Files:** `Sources/RockyKit/Store/Records.swift`, `Sources/RockyKit/Store/RockyStore.swift`, `Sources/RockyKit/Review/CommentAnchor.swift` (new), `Tests/RockyKitTests/RockyStoreTests.swift`, `Tests/RockyKitTests/CommentAnchorTests.swift` (new).

```
public struct DiffCommentRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  id, workspaceId, path, side ("new" | "old"), startLine, endLine, snippet, contextBefore, contextAfter, body,
  state ("pending" | "sent" | "outdated"), createdAt, sentAt?
}
// In the next free migration (read the latest number first).
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
}
```

It must:
- `NSTextView` in an `NSScrollView` with an `NSRulerView` subclass for line numbers and change bars; current-line fill; highlighting from Task 5, re-tokenized 150 ms after typing, visible range first; system find bar; ⌘L go to line; Tab inserts the detected indentation; substitutions and spell check off; no wrap.
- Be the Edit mode of diff tabs and the view of code, data and text file tabs; Markdown file tabs get Preview | Edit; files over 2 MB stay read-only.
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
- React to disk changes per `EDIT-03` (FSEvents from Task 1): silent reload with "Reloaded", or the conflict banner; saving checks the stamp; the agent-working banner.

Tests in `EditBufferTests`: clean buffer reloads; dirty buffer conflicts; Reload drops edits; Keep Mine lets the next save through; a stale stamp blocks the save without Keep Mine; saving clears the dirty state.

Commit `feat(ui): save edits safely while the agent works`.

### Task 11: Commit

**Requirements:** `GIT-04`, `ERR-02`.
**Files:** `Sources/RockyUI/CommitSheet.swift` (new), `Sources/RockyKit/Git/GitChangesService.swift`, `Sources/RockyKit/App/AppModel.swift`, `Tests/RockyKitTests/GitChangesServiceTests.swift`.

```
GitChangesService: public func commit(worktree: URL, subject: String, description: String?, environment: [String: String], output: @Sendable (String) -> Void) async throws
```

It must: open the sheet from the Uncommitted header of the Changes tab; run `git add -A` and `git commit` with the workspace environment; stream hook output; keep the sheet open with the output and exit code on failure (`GIT-04`). Every git failure in M3 (diff, commit, discard) shows its last stderr lines where the action was (`ERR-02`).

Tests: `GitChangesServiceTests.commitIncludesUntrackedFiles`, `failingHookReportsItsOutput`.

Commit `feat(ui): commit a workspace's changes`.

### Task 12: Keyboard commands

**Requirements:** `KBD-02`.
**Files:** `Sources/Rocky/RockyApp.swift`, `Sources/RockyUI/ChangesTab.swift`, `Sources/RockyUI/CodeEditor.swift`.

It must: add ⌘⇧C (the right panel on its Changes tab), ⌥⌘↓ / ⌥⌘↑, ⌘S, ⌘L as commands (⌘F is the system find bar; ⌘Return and Esc are local to the composer and sheets), and check none collides with M2, M2.5, M2.6 and M2.7 shortcuts (M2.7 has ⌘⇧G). Esc in a conversation whose agent works cancels the turn (M2.5); the comment composer and the sheets must take Esc first.

Commit `feat(app): add review and editor keyboard commands`.

### Task 13: Build, tests and verification

1. `swift build` and `swift test`. Fix and rerun until green.
2. `scripts/make-app.sh`, `open build/Rocky.app`, then the manual checklist with the HTML open next to the app.
3. Energy: with five workspaces open and nothing happening for 10 minutes, Rocky starts no process (Activity Monitor or `CurrentPowerlog.PLSQL`).
4. Merge `feat/m3-review-edit-pr` into `development` only with the user's approval.

Manual checklist (on a personal repository):
1. Let an agent change files: the sidebar stats and the Changes tab update within a second; nothing runs while idle (`GIT-01`, `GIT-03`). ⌘⇧C and the tab row switch between Changes and Checks (`CHG-01`).
2. Open each kind of file: modified, new, deleted, renamed, binary, a large lockfile (`DIFF-01`…`DIFF-03`); highlighting in TypeScript and Swift (`DIFF-04`); a tool badge opens the diff (`DIFF-05`).
3. Comment on one line, on a range by dragging, on a range by Shift-click, on a removed line; edit and delete; relaunch and see them (`CMT-01`…`CMT-03`).
4. Send to agent: the conversation receives the exact prompt; comments turn Sent; when the agent edits those lines they turn Outdated, when it inserts lines above they move (`CMT-04`, `CMT-05`).
5. Edit and save; undo past the save; find; go to line; the change bars follow (`EDIT-01`, `EDIT-02`, `EDIT-04`).
6. Edit without saving while the agent changes the same file: the banner; Reload and Keep Mine both behave (`EDIT-03`).
7. Discard a tracked file and an untracked one (it is in the Trash) (`GIT-05`); commit with a failing hook, then a passing one (`GIT-04`).
8. A failing git command (a commit hook, a discard on a locked index) shows its stderr where the action was (`ERR-02`).

## Known risks

- **M2.7's names** come from its plan, before implementation; if M2.7's record renamed or restructured the panel, adapt Task 2 and record it below.
- **Diff performance:** if the `LazyVStack` of fixed rows stutters on large diffs, or its scroll bar jumps like the chat's did, switch the diff body to an `NSTableView` behind an `NSViewRepresentable`, keeping comment cards as expanding rows.
- **`NSRulerView` and highlighting** in a large file: highlight the visible range first; if typing lags past 5,000 lines, highlight only the visible range.
- **FSEvents on the worktree's git directory:** the worktree's `.git` is a file; resolve it once, and re-resolve if the worktree moves.
- **The agent and the editor on the same file** stay a race in the worst case (the agent writes between your save's stamp check and the write). The stamp check makes it rare, not impossible.

## Changes during implementation

Record here anything that differs from this plan, with the date and the reason.
