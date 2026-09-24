# Rocky — project instructions

Rocky is a personal macOS app that runs coding agents (Claude Code, OpenCode) in parallel over ACP, one git
worktree per workspace, modelled on Conductor. Product spec: `docs/superpowers/specs/2026-09-22-rocky-design.md`.

## Build, run, check

```
swift build                  # compile
swift build --build-tests    # compile the tests without running them
swift test                   # the full suite: once, at the end of a milestone (see Workflow)
scripts/make-app.sh          # build/Rocky.app, release, signed with "Rocky Local" when it exists
open build/Rocky.app
```

- After a UI change: `scripts/make-app.sh`, quit and relaunch Rocky, then look at it. `screencapture -x -o -l
  <window id>` of Rocky's window is the way to check alignment and colors, and measuring pixels settles "looks
  wider/brighter" reports.
- Never add temporary debug hooks to the app (environment-gated code, auto-opening menus, file logs). Reproduce
  with the real app, or with a test.

## Code layout

- `Sources/RockyKit`: all logic, Foundation only (no AppKit, no SwiftUI). `AppModel`, `ChatSessionModel`, ACP,
  git, store (GRDB), environment, scripts, terminals (`PTYSession`). Everything testable lives here.
- `Sources/RockyUI`: SwiftUI views and the AppKit views they need (composer, terminal, spinner).
- `Sources/Rocky`: the app, its scenes and menu commands.
- `Tests/RockyKitTests`: Swift Testing. Only RockyKit is unit tested; UI behavior goes on the plan's manual
  checklist.
- Search before creating: reuse the existing view, style, token or helper by behavior, not only by name.

## Workflow

- **Milestones** (M1, M2, M2.5, M2.7, M3…) have two documents:
  - a design HTML in `docs/superpowers/design/`, the visual and behavioral source of truth, with requirement ids
    (`TB-01`, `PR-05`, …). When the mock and a requirement's text disagree, the text wins.
  - an implementation plan in `docs/superpowers/plans/`, with tasks naming those ids.
- **Two sessions** share this working tree:
  - dev-2 designs: writes the design HTML and the requirement ids.
  - dev-1 implements and writes the plans.
  - They coordinate through cross-session messages, and neither edits the other's documents.
- **Every departure from a plan** is recorded in that plan's "Changes during implementation": date, what changed,
  why (for example "user decision"), and the tests that pin it.
- **Tests** are written with each change and run once: right before merging the milestone's branch. Build once
  at the end of a plan's tasks, not after each task. Run tests mid-work only when the user asks.
- **Store migrations** are numbered in the order they land; plans say "the next free migration", never a number.
- **The user guide, `docs/README.md`, is in Spanish** (the user's request, 2026-09-24; the one exception to English
  docs): plain, neutral Spanish, with UI labels, commands and identifiers kept as they are. Every change that adds
  or changes something the user sees or configures updates it in the same work, before the milestone merges, and
  moves its "Última actualización" date.

## Git

- Remote: `origin` = `git@github.com:jhzl1/rocky.git`.
- Branches: `feat/m<N>-<name>` from `development`. Never commit on `development` or `main`. A milestone merges
  into `development` after its final test run, with the user's approval.
- Commit only when the user asks. Conventional Commits in English (`feat(kit): …`, `fix(ui): …`), lowercase,
  imperative, no trailing period, no AI attribution line.
- Never commit `.atl/` or `.superpowers/` (agent tooling).

## UI standards

- **Menus are Rocky's own**: `MenuButton`, `MenuItem`, `MenuDivider`, `rockyContextMenu`, drawn by
  `MenuPresenter` / `MenuHost` in the style of the model menu. Never SwiftUI `Menu`, `.contextMenu` or a native
  pop-up menu. An item without an icon takes no icon column; only menus whose items have icons keep the gutter.
- **Zoom** (⌘+ ⌘- ⌘0): text through `Font.rocky(_:weight:design:)`, sizes of anything holding text or icons
  through `Zoom.shared(_:)`. Never `scaleEffect`: a scaled AppKit view loses its hit testing.
- **Colors and motion** come from `Theme`:
  - text: `textPrimary`, `textSecondary`, `textTertiary`
  - fills: `fillHover`, `fillSelected`, …
  - states: `accent`, `attention`, `danger`, `success`
  - lines: `hairline`
  - motion: `Theme.Motion.hover` / `.state` / `.enter`
  - A translucent hairline sits on an opaque Rocky color, never on the window's own background.
- **Buttons**: `RockyIconButtonStyle`, `RockyTextButtonStyle`, `RockyFilledButtonStyle`. Every custom button gets
  `.clickable()` (the pointing-hand cursor).
- **Window metrics**: `WindowMetrics.titleBarHeight` (38) and `bottomBarHeight` (36), shared by the sidebar footer
  and the terminal panel bar so their lines align.
- **Chat**: a plain `VStack` of `.equatable()` rows, never a `LazyVStack`, whose estimated heights made the scroll
  bar grow and shrink. Queued messages sit at the end of the transcript, after "Working", as one group with one
  caption.
- **Live feedback**: `CircularProgress` (Core Animation), `ShimmerText` for live labels, elapsed times in the
  monospaced font. Honor Reduce Motion. Animations pause only while the window cannot be seen
  (`NSWindow.occlusionState`: minimized, hidden, covered, another Space), never just because another app is active,
  or a working agent looks stuck. "Is the user looking at Rocky" (unread marks, the alert sound, the Dock badge) is
  `appearsActive`.
- **Settings** is an in-app modal (`SettingsPresenter`, ⌘,), not a window.
- **Key monitors**: an `NSEvent` monitor added from a SwiftUI view keeps the view as it was when it was added;
  read live state through a reference (`LiveFlag`). Esc goes first to an open menu, the settings modal or a sheet,
  then stops the agent's turn.
- **Copy**: all UI copy, code, identifiers, comments and docs in English, except the Spanish user guide
  (`docs/README.md`). Comments say why, in full sentences, at
  the density of the surrounding code.

## Energy (spec Section 1)

- Nothing polls at rest. No timers on the disk or the network: file changes come from FSEvents, and git runs only
  after a change, debounced.
- Per-frame work goes to Core Animation, not a SwiftUI `TimelineView` redrawing every frame. `TimelineView`s pause
  while the window cannot be seen; the 30 fps shimmer is the one visible-but-inactive cost.
- The agent of the conversation on screen starts in the background; the others start on their first message.
- GitHub goes over `URLSession` (GraphQL/REST), never a `gh` process per refresh. Rocky polls only the selected
  workspace, only while the window can be seen: every 30 s, every 15 s while checks run. No manual refresh button.
- Agent updates are checked once a day against the npm registry over `URLSession`, plus a manual check.

## Agents and environment

- **Rocky owns its agents**: its own OpenCode (its own data folder through `XDG_DATA_HOME`) and the Claude ACP
  adapter, at the versions Rocky was tested with, installed under `~/Library/Application Support/Rocky/agents`.
  No Conductor variables anywhere; per-repo config is `rocky.json` (`scripts`, `links`).
- **Environment**:
  - The login shell's environment is read once per launch (Rocky → Refresh Shell Environment re-reads it).
  - `CLAUDE_CONFIG_DIR` is never inherited; it comes only from the repo setting.
  - Layers, later wins: login shell < repo variables < GitHub account variables.
  - Every process gets `PORT`, `ROCKY_PORT` and the `ROCKY_*` variables. Ports are not shown in the UI.
- **Worktrees**:
  - A worktree lives at `<repo>-worktrees/<city>` on branch `rocky/<city>`.
  - A new worktree gets the main clone's ignored environment files as symlinks (`WorktreeLinker`: `.env`,
    `.env.*`, `.envrc`, `.dev.vars*`, `.claude/settings.local.json`, plus the repo's extra `links`), then its
    Setup script.
- **GitHub**:
  - Each repository has one account (`gh auth token --user <login>`).
  - Tokens stay in memory: never stored, logged or put in a URL.
  - Agents get the repo account's `GH_TOKEN`.
- **Notifications**: when the user is not watching a workspace (another workspace is selected, or the window is in
  the background), what happens there plays the alert sound and counts in the Dock badge. There is no system
  notification.

## Safety

- Manual tests run only on personal repositories. Pull request flows run only on a throwaway personal
  repository, never a work repository.
- Production data is read-only, and any write needs the user's explicit authorization first (global rule).

## Shell

Use `bat`, `rg`, `fd`, `sd` and `eza`; `cat`, `grep`, `find`, `sed` and `ls` are blocked by a hook.
