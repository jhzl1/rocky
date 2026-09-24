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

## Known issues

- Undo history is lost when a file tab is hidden (the text stays).
- Terminal shells inherit every open file descriptor of Rocky (carried over from M2.7).
- Only the final tree was built and tested; the intermediate commits were not built one by one.
