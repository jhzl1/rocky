# M2 verification

Date: 2026-09-23. Branch `feat/m2-terminal-scripts-env`, merged into `development` with the user's approval on the
same day, before the manual checklist (user decision: M2.5 starts on its own branch now; the checklist runs later on
`development`).

## Automated

`swift test`, the one full run (global rule: tests run last, before the merge):

```
✔ Test run with 129 tests in 19 suites passed after 1.715 seconds.
```

`PTYSessionTests`, `AppModelProcessTests` and `ACPConnectionTests` three more times, for timing failures:

```
✔ Test run with 22 tests in 3 suites passed after 1.194 seconds.
✔ Test run with 22 tests in 3 suites passed after 0.777 seconds.
✔ Test run with 22 tests in 3 suites passed after 0.914 seconds.
```

## Manual checklist (Task 10, Step 4)

Not run yet. Items 1 to 8 as written in the plan, with two updates from "Changes during implementation":

- Item 3 reads `echo $ROCKY_DEMO $ROCKY_SECRET $ROCKY_PORT` (Rocky no longer exports `CONDUCTOR_*`).
- Scripts can also come from a `rocky.json` at the workspace root (it replaced `conductor.json`).

Also to check by hand, from what M2 added beyond its plan: conversation tabs, the model menu (search with
OpenCode's list) and the + menu, plan mode, a pasted image inside the message box and in the sent message, ↑ to
bring back the last message, a file badge's preview and file tab, an agent question answered in its card, zoom
(⌘+ ⌘- ⌘0), Settings (⌘,) with agent updates, folding the terminal panel (⌘J), a new OpenCode conversation in a
repo Conductor opened.

What was checked by hand during the work, in the real app or an isolated harness, is recorded with each change in
the plan's "Changes during implementation".

## Energy (item 9)

Not measured yet: `scripts/energy-report.sh 30` after 30 idle minutes, target `processes_per_min` below 5. Since
2026-09-23 the agent of the conversation on screen starts in the background (user decision), and Rocky asks npm
for agent updates once a day (one HTTPS request per agent, no process).

## Known issues

- None open from M2's own scope. The OpenCode failure (`no such column: project_id`) is fixed by Rocky's own
  OpenCode with its own data folder.
- `XDG_DATA_HOME` points at Rocky's OpenCode data for the tools OpenCode runs (for example a `pnpm` run through
  OpenCode keeps its store there).
- Only the final tree was built and tested; the intermediate M2 commits were not built one by one.
