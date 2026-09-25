# M3 verification

Date: 2026-09-24. Branch `feat/m3-review-edit-files`, created from `development` at `0450f07`, which already had M2.5,
M2.6 and M2.7. The user asked for the merge once the user guide was updated ("haz el merge apenas termine el
agente").

## Automated

Tasks 1–17 were written by one writer at a time, and nothing was built between tasks. The first build of the whole
milestone had no errors, including the tests. `swift test`:

```
✔ Test run with 547 tests in 60 suites passed after 3.503 seconds.    (parallel, run 1)
✔ Test run with 547 tests in 60 suites passed after 3.277 seconds.    (parallel, run 2)
✔ Test run with 547 tests in 60 suites passed after 24.797 seconds.   (--no-parallel)
```

That includes the checks the Review Focus points to:
- `FileTreeTests.ranks100000PathsInUnder50ms` (FIL-07)
- `CommentAnchorTests` (comments move with the code and turn Outdated)
- `ReviewPromptTests` (CMT-05's exact format)
- `EditBufferTests` (a save never overwrites the agent's change without Keep Mine)
- `GitChangesServiceTests.discard…` (discard never touches commits; untracked files go to the Trash)

## Manual checklist (Task 18)

Not run yet: the user tries it in the app built after the merge. These are the points the writers could not settle
without the UI:
- the diff's scroll bar (if it jumps, the plan's fallback is an `NSTableView` body);
- ⌘L through `@FocusedValue` while the editor has focus;
- ⌘S against the repository settings' Save;
- Esc and the arrow keys in the All files filter and the tree;
- Esc in the comment editor and in the commit sheet;
- `ProcessRunner.stream` with a commit hook that leaves a background process;
- the unsaved-changes prompt on quit and on closing a tab.

## After the merge

Date: 2026-09-24. Branch `fix/m3-editor-and-quick-open`, from `79a86ed`. Plan: "After the merge" and Tasks 19–22 of
`docs/superpowers/plans/2026-09-23-m3-review-edit-pr.md`.

- **The editor's gutter** filled `bounds ∩ dirtyRect` instead of `dirtyRect`, and clips to its bounds: it had painted over
  the text and past the editor, which left the window's chrome and the text undrawn.
- **Placeholders** of the All files filter and the sidebar search are drawn by `stablePlaceholder(_:isVisible:)`, so they
  no longer move 1 point when the field takes the keyboard. Quick Open's field uses it too.
- **Quick Open (⌘P, FIL-08)**: recent files ranked first inside each tier and stored (the next free migration, `v11`),
  the list read at most once per opening, the preview rule of FIL-05 (only a new preview replaces the preview), and the
  panel.

Tasks 19–21 were written by one writer, and nothing was built between them. Their build (`swift build --build-tests`)
had no errors or warnings, nor had the one after the last change (Quick Open closes with the window). `swift test` on
the final tree:

```
✔ Test run with 556 tests in 60 suites passed after 3.294 seconds.    (parallel, run 1)
✔ Test run with 556 tests in 60 suites passed after 3.201 seconds.    (parallel, run 2)
✔ Test run with 556 tests in 60 suites passed after 24.178 seconds.   (--no-parallel)
```

547 before, one removed (`goToFileSelectsTheAllFilesTab`, with Go to File's panel request) and ten added: three in
`FileTreeTests`, two in `RockyStoreTests`, five in `AppModelTests`.

Before those three runs, one parallel run failed `FileTreeTests.ranks100000PathsInUnder50ms` at 58 ms, and a test
expectation of mine was wrong (every path does not match "srv"), fixed. Measured alone in the debug build, five times:
the ranking takes 16.3–17.0 ms without recent files and 17.5–18.5 ms with 20, of which the 20 lookups take about 1 ms.
The 58 ms was the other suites' load, so the test now counts the best of three runs; the bound stays at 50 ms.

### Manual checklist (Quick Open)

Not run: the app was not launched or rebuilt (the user had it open). In the built app:
- ⌘P with the right panel open and closed; the panel never changes;
- typing fast: the panel does not flicker or move, and the field keeps the keyboard;
- ↑ / ↓ wrap at both ends; hover selects, and a list scrolled by the keyboard under a still pointer keeps its row;
- Return opens a kept tab and leaves an open preview alone; ⌥Return and ⌥-click open as the preview;
- Esc, a click outside and ⌘P again close it, and the keyboard goes back to the message box or the editor;
- Esc while an agent's turn runs closes Quick Open and does not stop the turn;
- recent files, with their clock, after a relaunch;
- "Reading files…" on the first opening in a large repository, and no `git ls-files` while typing.

### Comments like Conductor (CMT-02, CMT-05, CMT-06)

Tasks 23–27 of the plan, same branch. A comment is written in a box under the selected lines ("Sending to" a
conversation of the workspace) and goes to that conversation at once, or into its queue while its turn runs; the
transcript shows its line chip and the text, and the agent gets `ReviewPrompt.single`'s text block. Rocky stores no
comment: the next free migration, `v12`, drops `diffComment`. The Changes tab lost its comments bar and counts.

Tasks 23–26 were written by one writer, and nothing was built between them. Their build (`swift build`, then
`swift build --build-tests`) had no errors or warnings, nor had the one after the last change (a chip's handled line
request is kept apart from the request, `handledLineScrolls`). `swift test` on the final tree:

```
✔ Test run with 558 tests in 60 suites passed after 3.595 seconds.    (parallel, run 1)
✔ Test run with 558 tests in 60 suites passed after 3.203 seconds.    (parallel, run 2)
✔ Test run with 558 tests in 60 suites passed after 23.638 seconds.   (--no-parallel)
```

556 before. Removed: `CommentAnchorTests` (11 tests, the suite), four in `AppModelTests` (`sendReview…`,
`aRefreshKeepsCommentsOnTheirLinesAndStoresThem`, `commentsSurviveARelaunchAndGoWithTheirWorkspace`), two in
`RockyStoreTests` and `ReviewPromptTests`' three. Added: `LineRangeAttachmentTests` (5, a new suite),
`ReviewPromptTests` (5), `DiffLayoutTests` (3, two of them moved from `CommentAnchorTests`), `AppModelTests` (5),
`ChatSessionModelTests` (2), `RockyStoreTests` (1) and `ACPProtocolTests` (1). The three runs before that last change
passed too (558; 3.315 s, 3.326 s and 24.057 s); no test failed at any point.

### Manual checklist (comments)

Not run: the app was not launched or rebuilt (the user had it open). In the built app:
- comment on new lines and on removed lines; the range stays lit while the box is open;
- the box: its text starts beside the chip, on 22-point lines, grows with the text, and Return adds a line;
- ⌘Return sends while the box's text view has the keyboard, and does nothing while the text is empty;
- send to a conversation that is not shown, and see it arrive; the diff stays on screen;
- send while a turn runs: "Queue", the queued row with its chip, Send now and Remove, and then the comment sent;
- the chip's click, on a changed file (scrolled to its line, a collapsed run opened) and on one no longer changed;
- Esc with and without text ("Discard this comment?"), and Esc never stops the agent's turn while the box types;
- the box after a tab switch and after Diff | Edit, with its text and its conversation;
- the toast's Show, and clicks anywhere else going through the toast's area as before;
- ↑ in the message box skips the comments.

### File icons (FIL-09)

Tasks 28–30 of the plan, same branch. `scripts/vendor-file-icons.py` downloaded `material-icon-theme` 5.38.1 from npm,
checked its integrity and version, and wrote `Sources/RockyUI/Resources/FileIcons/`: 587 SVGs (493,218 bytes; the
586 that the theme's file names, extensions and default reference, plus `github-actions-workflow`), `manifest.json`
and `LICENSE`. A second run gave the same files (one hash over the folder, before and after). All 587 SVGs load in
`NSImage`; `bithound.svg` draws almost blank (its root's `fill-opacity=".05"`). `FileIcons.iconId` (RockyKit) picks
the icon, and `FileIcon` (RockyUI) draws it in the tree, the filter, Quick Open, Changes rows, tabs, tab headers,
badges, the composer's attachments, the line chip and the hover preview.

Tasks 28–29 were written by one writer. Their build (`swift build`, then `swift build --build-tests`) had no errors or
warnings. The first `swift test` failed one test, `DiffLayoutTests.theRunBetweenHunksCollapsesToItsCount`, which still
expected the `@@` rows' ids that the "No `@@` rows" change removed; its expectation was fixed (plan record). Then, on
the final tree:

```
✔ Test run with 567 tests in 61 suites passed after 3.597 seconds.    (parallel, run 1)
✔ Test run with 567 tests in 61 suites passed after 3.394 seconds.    (parallel, run 2)
✔ Test run with 567 tests in 61 suites passed after 24.129 seconds.   (--no-parallel)
```

558 before; nine added, in a new suite, `FileIconsTests`: one per lookup step, the workflow rule, the manifest's case
rule, and two on the vendored manifest (FIL-09's examples, and an SVG for every id it can return).

### Manual checklist (file icons)

Not run: the app was not launched or rebuilt (the user had it open). In the built app:
- the tree with `.ts`, `.tsx`, `.test.ts`, `.d.ts`, `package.json`, `tsconfig.json`, `README.md`, `.gitignore`, a
  workflow `.yml` under `.github/workflows/` and a plain `.yml` elsewhere; folders keep the blue folder;
- Show Ignored Files: `.env` and `node_modules` dimmed, the icon at 50 % like the name;
- the filter's rows and Quick Open's rows;
- Changes rows (the icon after the status letter), an unchanged file's tab (the icon at 12) and a changed one's (its
  letter), the diff tab's header and a file tab's header (the icon at 14);
- a chat badge, an attachment in the message box, a line chip in the box and in the transcript, and a badge's hover
  card for a file with no preview;
- zoom at 90 % and 125 %: the icons stay sharp (drawn as vectors) and keep their size against the text;
- scrolling a large tree: no stutter on the first rows of each kind of file.

### The default app, the path chip and "+" (TB-03, OPN-02, DIFF-01, CNV-01, CNV-02)

Tasks 31–34 of the plan, same branch. The Open button is a split button: its left part opens the worktree in the
default app (OPN-02), the last one picked in its menu, stored as a bundle id under `defaultOpenApp` and resolved by
`DefaultOpenApp.resolve` (RockyKit) each time it is used; File ▸ Open in <app> (⌘O) does the same. The diff and file
tabs' path is a chip that opens the file in that app, or reveals it in Finder; a deleted file's path stays plain text.
"+" makes a conversation at once with the agent of the repository's last user message (`RockyStore.lastUsedAgent`),
Claude Code before any, as does a workspace's first conversation; a right-click on it keeps today's two items.

Tasks 31–33 were written by one writer, and nothing was built between them. Their build (`swift build`, then
`swift build --build-tests`) had no errors or warnings. `swift test` on the final tree:

```
✔ Test run with 575 tests in 62 suites passed after 3.503 seconds.    (parallel, run 1)
✔ Test run with 575 tests in 62 suites passed after 3.514 seconds.    (parallel, run 2)
✔ Test run with 575 tests in 62 suites passed after 24.331 seconds.   (--no-parallel)
```

567 before; eight added: `DefaultOpenAppTests` (5, a new suite, OPN-02's five cases), `RockyStoreTests` (2,
`lastUsedAgent`) and `AppModelTests` (1, the default agent). No test failed at any point.

### Manual checklist (the default app, the path chip and "+")

Not run: the app was not launched or rebuilt (the user had it open). In the built app:
- the split button: 28 tall, the default app's icon on the left, the chevron on the right, each lit on hover, the
  chevron lit while the menu is open; the menu hangs from the button's right edge, 200 wide, with "⌘O" on the default;
- ⌘O and the left part with Zed, VS Code and Finder as the default; File ▸ Open in <app> follows the default, and is
  off with no workspace selected;
- picking another app in the menu opens the worktree there and changes the button's icon; New Terminal and Copy Path
  leave it; the default survives a relaunch;
- with nothing stored, the first installed editor; with an editor removed, the fallback, and the editor back once it is
  installed again;
- the path chip of a diff tab and of an unchanged file's tab opens the file in Zed: note whether Zed reuses the window
  that shows the worktree or opens a new one (OPN-02's unknown); with Finder as the default, "Reveal in Finder";
- a deleted file's path: plain text, no ring, hover or tooltip; the "⋯" still has Open in Finder and Copy Path;
- a file tab from a badge outside the worktree: the chip with the full path, 34 tall like a diff tab's header;
- "+": one click, no menu, the tab enters at the end (a fade and a 6-point rise; only a fade with Reduce Motion),
  selected, with the message box focused; switching workspaces plays no entrance;
- "+" with the last agent used in the repository (send in an OpenCode conversation, then "+"), and a new workspace's
  first conversation with it;
- a right-click on "+": the two agents, each with its mark; the pick opens that agent and does not change the default.

### ↑ brings a line comment back (CMT-05 History, CMT-06)

Tasks 35–36 of the plan, same branch, with the designer's update of 2026-09-25 (a queued comment's Edit, all or
nothing, the caret, slash commands, the history test). ↑ in the message box, and a queued comment's Edit, bring a line
comment back as its chip at the start of the box and the comment after it (`MessageHistory.Entry.lineRange`,
`LineChipAttachment`). Sending it builds the block again (`AppModel.lineComment(for:comment:files:workspaceId:)`): the
new side from the worktree file, the removed side from the base with `git cat-file`, and no code at all when any line
of the range cannot be read (`ReviewPrompt.single`'s `code` is optional).

Task 35 was written by one writer, and nothing was built before its end. Its build (`swift build`, then
`swift build --build-tests`) had no errors or warnings. `swift test` on the final tree:

```
✔ Test run with 585 tests in 62 suites passed after 3.670 seconds.    (parallel, run 1)
✔ Test run with 585 tests in 62 suites passed after 3.999 seconds.    (parallel, run 2)
✔ Test run with 585 tests in 62 suites passed after 26.387 seconds.   (--no-parallel)
```

575 before; ten added: `ReviewPromptTests` (3: no code on each side, files named in the block), `MessageHistoryTests`
(2: ↑ stops on a line comment, entries keep their range), `ChatSessionModelTests` (2: files after the block, a "/"
comment is no command) and `AppModelTests` (3: the lines read again on each side, a range past the end, the resent
comment's chip). `LineRangeAttachmentTests.aUserMessageWithOneEntryIsALineComment` became
`aUserMessageStartingWithOneEntryIsALineComment`, with the files after the entry. Before those three runs, one parallel
run failed the new `aLineCommentStartingWithASlashIsNoCommand`: it used "/login", which is not among Claude Code's
terminal commands in Rocky (`TerminalOnlyCommand`); it now uses "/mcp".

### Manual checklist (↑ on a line comment)

Not run: the app was not launched or rebuilt. In the built app:
- ↑ from an empty box after a comment: the chip at the start (22 tall, the file's icon, name and range) and the comment
  after it, clear of the chip; ↑ again goes to the older message, ↓ back to the comment, then an empty box;
- resend it untouched, then after editing the file: the transcript shows the chip and the text, and the agent's block
  holds the lines as they are now;
- ↑ on a comment about removed lines, then resend: the base's code, "removed lines … (from the base)";
- a comment whose file is gone, or whose range runs past the end: the block without code;
- Backspace right after the chip removes it, and the message goes as a normal one; the caret cannot be put before the
  chip by clicking, ←, ⌘← or ↑; ⌘A then Delete leaves the chip; copying and pasting a selection never brings it twice;
- a "/" typed right after the chip opens no command list; "Commands" in the "+" menu does nothing with the chip there;
- the chip alone, with no text, does not send;
- during a turn: the resent comment queues with its chip; its Edit, only with the box empty, brings the chip and the
  text back and takes it out of the queue; Send reads the lines again;
- a file dropped next to the chip: a badge in the box and in the transcript, a link after the block for the agent;
- zoom at 90 % and 125 % with the chip in the box.

### Line counts on edit rows (DIFF-06)

Tasks 37–38 of the plan, same branch. A tool call whose content holds ACP `diff` entries shows `+A −D` after its file
badges once it completes (`DiffStatLabel`), and the "N tool calls" header shows the sum of its rows. The kit reads the
entries (`ToolCallDiff`, `SessionEvent.toolCall` / `.toolCallUpdate`'s `diffs`), counts them off the main actor
(`ToolDiffStats.count`: Claude's `_meta.jetbrains.air.diffStats`, else every line of a new file, else a line diff up to
5,000 lines), and stores them on the transcript row (`chatMessage.additions` / `deletions`, migration `v13`).

Both tasks were written by one writer, and nothing was built before their end. The build (`swift build`, then
`swift build --build-tests`) had no errors or warnings. `swift test` on the final tree:

```
✔ Test run with 600 tests in 63 suites passed after 3.958 seconds.    (parallel, run 1)
✔ Test run with 600 tests in 63 suites passed after 3.988 seconds.    (parallel, run 2)
✔ Test run with 600 tests in 63 suites passed after 26.994 seconds.   (--no-parallel)
```

585 before; fifteen added: `ToolDiffStatsTests` (7, a new suite: Claude's counts as sent, a new file, context lines, a
final newline and "\r\n", the cap, one uncountable entry, the row's and group's label), `ACPProtocolTests` (3: Claude's
entries and counts, the counts' known shape, content without diffs), `ChatSessionModelTests` (3: counts on completion
from the latest content, an update with content replaces them and one without keeps them, a rejected edit) and
`RockyStoreTests` (2: the migration, the round trip). No test failed at any point.

### Manual checklist (line counts)

Not run: the app was not launched or rebuilt. In the built app, with Claude Code and with OpenCode:
- an Edit of two lines in README.md: the row reads "Edit [README.md] +1 −1" once it completes, nothing while it runs;
  the folded group shows the same after its title;
- a Write of a new file: "+N −0" with N its lines, not the optimistic count once the real hunk arrives; a Write over an
  existing file: its real counts, not "+N −0";
- a rejected edit: "FAILED" and no counts;
- a call touching several files (MultiEdit, OpenCode's patch): one label, the sum;
- relaunching Rocky and opening the conversation: the rows and the group keep their counts; a conversation from before
  shows none;
- VoiceOver on a label: "2 lines added, 1 removed"; zoom at 90 % and 125 %: 6 points after the badges.

### Final run before the merge (2026-09-25)

After the last change on the branch (the pull request header no longer shows "Working…"), one parallel run and one
serial run, on the whole branch:

```
✔ Test run with 599 tests in 63 suites passed after 3.906 seconds.    (parallel)
✔ Test run with 599 tests in 63 suites passed after 27.137 seconds.   (--no-parallel)
```

599 = the 600 of the line-counts run minus `PullRequestHeaderTests.working`, removed with the header's working state.
The branch is committed in three commits (the editor fix, the file icons, the rest), because the other features share
files (`AppModel`, `ChatView`, `WorkspaceDetailView`); only the final tree was built and tested.

## Known issues

- Undo history is lost when a file tab is hidden (the text stays).
- Terminal shells inherit every open file descriptor of Rocky (carried over from M2.7).
- Only the final tree was built and tested; the intermediate commits were not built one by one.
