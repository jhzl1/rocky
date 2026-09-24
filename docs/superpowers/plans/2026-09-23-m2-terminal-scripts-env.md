# M2 Terminal, Scripts and Env Implementation Plan

> **Execution:** task by task, one commit per task. Nothing is compiled or tested before Task 10 (global rule `## Tests` in `~/.claude/CLAUDE.md`). This plan gives decisions, files, public interfaces, required behavior and the tests to write. It does not carry the code: the implementer writes it.

**Goal:** Each workspace gets terminal tabs, setup/run/archive scripts and its own environment (repo variables, secrets in the Keychain, its own ports), with no polling added.

**Architecture:** Same package as M1. RockyKit gains `PTYSession` (one process in a pseudo-terminal, on top of SwiftTerm's `LocalProcess`), the environment layers and port allocation, repo variables in SQLite with secret values in the Keychain, and script resolution from `conductor.json` or repo settings. `AppModel` owns one `WorkspaceProcesses` per workspace. RockyUI adds a bottom panel with one tab per script and per terminal, drawn by SwiftTerm's `TerminalView`.

**Tech stack:** M1 stack plus SwiftTerm 1.20.0 (`https://github.com/migueldeicaza/SwiftTerm`, tag `v1.20.0`).

**Spec:** `docs/superpowers/specs/2026-09-22-rocky-design.md`, M2 row ("terminal tabs, setup/run/archive, repo vars"), Sections 1, 3 and 5. M1 record: `docs/superpowers/m1-verification.md`.

## Decisions

Taken with the user on 2026-09-23:

- Layout: chat on top; a bottom panel with tabs Setup, Run, Archive, one per terminal, and `+`.
- Secrets: macOS Keychain. `scripts/make-app.sh` signs with a self-signed certificate named `Rocky Local`, so every rebuild is the same app to the Keychain and it does not ask again.
- Renaming a workspace (spec Section 3.1): out of M2.

Taken in this plan. Change them here, not during implementation:

- *(Superseded 2026-09-23: Rocky reads its own `rocky.json` and exports no CONDUCTOR_* variable; see Changes during
  implementation.)* Scripts come from `conductor.json` only (Conductor's legacy format, which the spec names). Conductor now prefers `.conductor/settings.toml`; reading it needs a TOML parser, and no repo uses scripts today (spec Evidence: the Conductor database has none configured).
- `conductor.json` is read from the workspace root (the worktree), because the branch may change it. Conductor's docs do not say which copy they read.
- When `conductor.json` exists it replaces all three scripts and the run mode; repo settings are ignored for that workspace, even for keys the file lacks.
- Scripts run as `/bin/zsh -c <script>` in a PTY with cwd = worktree. That matches Conductor's docs: zsh, non-interactive, workspace directory.
- Terminal tabs run the login shell from the captured environment (`$SHELL -l`, `/bin/zsh -l` when unset), cwd = worktree.
- Stopping sends a signal to the process group, then SIGKILL after 5 seconds (Conductor's documented behavior). Scripts get SIGTERM. Terminals get SIGHUP, which is what closing a terminal window sends; an interactive bash ignores SIGTERM.
- Ports: each workspace owns ten, `port` through `port + 9`, in blocks starting at 41000. The lowest free block is reused, the port is stored per workspace, and nobody checks whether another program listens there.
- Environment layers, later wins: login shell < workspace variables < repo variables. `CLAUDE_CONFIG_DIR` comes only from the repo setting; a repo variable cannot set it (M0 finding).
- Workspace variables, exported to agents too (Conductor does the same):
  - `PORT`, `ROCKY_PORT` and `CONDUCTOR_PORT`.
  - `ROCKY_` and `CONDUCTOR_` versions of `WORKSPACE_NAME`, `WORKSPACE_PATH`, `ROOT_PATH` and `DEFAULT_BRANCH`.
  - `CONDUCTOR_IS_LOCAL=1`.

  The `CONDUCTOR_*` names make an existing `conductor.json` (for example `pnpm dev --port $CONDUCTOR_PORT`) run unchanged.
- Running processes keep the environment they started with. Changing variables or refreshing the shell environment applies to new processes only. A Claude instance change still stops running Claude chats (M1 fix `1590453`).
- Setup failure: the exit code shows in its tab and the workspace stays usable. Archive failure: nothing is deleted, and an alert offers "Remove Anyway".
- Run modes: `concurrent` (default) and `nonconcurrent`. In `nonconcurrent`, Run first stops every other workspace's run script, in any repo.
- Each session keeps its last 2 MB of output and replays it when a view attaches. Tabs exist only while Rocky runs; they are not persisted.

## Changes during implementation (2026-09-23)

Everything below was added or changed while M2 was built, at the user's request, beyond Tasks 1–10. It is the
record of what the code does now; where it contradicts a line above or in the M1 plan, this section wins.

### Rules that changed

- **macOS 15 minimum** (was 14). Textual, the Markdown renderer the user chose, needs it; `Package.swift` and
  `Info.plist` (`LSMinimumSystemVersion` 15.0) say so.
- **Dependencies:** Textual 0.5.0 (`exact:`) joins GRDB 7.11.1 and SwiftTerm 1.20.0. They bring transitive
  packages: swift-argument-parser (SwiftTerm), swift-concurrency-extras and swiftui-math (Textual). SwiftTerm's
  Metal shader needs Xcode's Metal Toolchain component, installed with the user's approval.
- **Builds during the work:** the user asked for the app to be rebuilt and relaunched after every change
  (`scripts/make-app.sh`, then `open build/Rocky.app`), even while agents run. Tests are still written with each
  change and run once, at the end, before the merge into `development`.
- **Commits only when the user asks.** The commits made before that rule (up to `799f100`) stay as they are.
- **Energy: the agent of the conversation on screen starts in the background** when its tab is shown, so the
  model menu is ready without pressing anything (user decision, 2026-09-23). Other tabs start nothing until shown.
  This replaces "processes start only on user action" for agents; terminals and scripts still start only on user
  action.
- **Rocky runs its own OpenCode** (user decision, 2026-09-23): `opencode-ai@1.18.32` (the newest published version),
  installed with npm into `~/Library/Application Support/Rocky/agents` like the Claude adapter, the first time an
  OpenCode conversation opens. It runs with `XDG_DATA_HOME` set to `~/Library/Application Support/Rocky/opencode-data`,
  so its database, sessions and login are its own; the user's `auth.json` is copied there once (user decision). The
  `opencode` on the PATH is no longer used. Cost: the tools OpenCode runs see that `XDG_DATA_HOME` too (a `pnpm`
  run through OpenCode, for example, keeps its store there), and OpenCode sessions started in a terminal do not
  show in Rocky.
- **No Conductor compatibility** (user decision, 2026-09-23): Rocky exports only `PORT` and `ROCKY_*` variables, and
  reads scripts from its own `rocky.json` (same shape as conductor.json) instead of `conductor.json`. This replaces
  the Decisions above about `conductor.json` and the `CONDUCTOR_*` variables. No repo used either (doculift,
  its bergen worktree and rocky were checked).
- **Rocky draws all its menus itself**, in the model menu's style: a dark rounded panel, hairline border, rows lit
  on hover, icon and shortcut per row (user decision, 2026-09-23). No `Menu` or `.contextMenu` from SwiftUI.

### Bugs fixed

- **A second agent never answered while another sat idle** ("Starting Claude Code…" forever). Every
  `FileHandle.AsyncBytes` reads on one serial queue, `com.apple.Foundation.AsyncBytesIOActorQueue`, so an idle
  agent's blocked read stopped every other agent's reads. `ACPConnection.start()` (M1 Task 3) now reads with a
  `readabilityHandler` per pipe. Test: `ACPConnectionTests.anIdleAgentDoesNotBlockAnotherAgentsReplies`.
- **SwiftPM resource bundles were missing from `Rocky.app`**, a latent `fatalError` in `Bundle.module`.
  `scripts/make-app.sh` copies every `*.bundle` into `Contents/Resources`.
- **A pasted file showed as blank space, then as a white box, in the message box.** Badges were first TextKit 2
  attachment views; inside SwiftUI, TextKit made the view late or never, and drew its generic attachment image (the
  white box) meanwhile. A badge is now the attachment's image (`FileBadgeLook` rendered when it is inserted), and
  `ComposerTextView` handles its hover (X and preview) and clicks itself.
- **A new terminal tab stayed blank.** SwiftUI built two views of the session and dismantled the second one, and a
  session fed a single view, so the one on screen got nothing. `PTYSession` now feeds every attached view. Test:
  `PTYSessionTests.dismantlingOneViewKeepsTheOtherFed`.
- **Claude said the session was not interactive and could not ask questions.** `claude-agent-acp` removes
  AskUserQuestion (`--disallowedTools AskUserQuestion`) unless the client declares
  `clientCapabilities.elicitation.form` (`acp-agent.js:6013`). Rocky now declares it and answers
  `elicitation/create` (see Chat below).
- **Menus opened about 28 points away from their button** while the terminal panel was folded. Anchors were
  measured in a named coordinate space on `RootView`, which sits under the title bar's safe area; views inside the
  terminal split could not reach it and fell back to window coordinates, which is why that layout looked right.
  Menus now measure in window coordinates (`.global`) everywhere.
- **Blurry borders on a 1x screen:** borders use `strokeBorder` (inside the shape) instead of `stroke`, which
  straddles the edge by half a point.

### Chat and ACP (RockyKit)

- Conversation tabs per workspace: `ChatSessionRecord.title` (from the first message) and `closedAt`; the model
  keeps `chats` by conversation id, `conversations`, `selectedConversationIds`, `showConversation`,
  `newConversation` and `closeConversation`. A closed tab stops its agent and keeps the conversation in the store.
- Session settings: `configOptions` from `session/new` and `session/load` (model, effort, fast, mode), changed
  with `session/set_config_option`; the older `models` field with `session/set_model`. `config_option_update` and
  `current_mode_update` keep them in step when the agent changes them itself.
- Plan mode: the `mode` option's `plan` choice, from the + menu or ⇧Tab; switching it off returns to the mode it
  came from.
- Attachments: images go inside the prompt (`image` block, up to 5 MB) when the agent accepts them, other files as
  `resource_link`. A message marks where each file sits with U+FFFC (`PromptAttachment.marker`), and the prompt keeps
  that order.
- Tool calls keep ACP's `kind`, the files in `locations`, and later updates of title, kind and files. Claude's
  AskUserQuestion gets kind `question`.
- Agent questions: `elicitation/create` forms become `AgentQuestionRequest` (`question_<n>` fields, options,
  multi-select, "Other" text); the answer goes back as `accept`, `decline` (Skip) or `cancel` (turn stopped).
- The time each turn ends (`ChatItem.completedAt`) and when it started (`turnStartedAt`).
- Store migrations: v3 `chatMessage.completedAt`; v4 `chatSession.title`, `closedAt`; v5 `chatMessage.attachments`
  (JSON array of paths), `toolKind`.
- File tabs: `AppModel.openFiles`, `selectedFiles`, `openFile`, `showFile`, `closeFile`. Kept only while Rocky runs.

### Interface (RockyUI), interim until M2.5

- Window: hidden title bar, full-height sidebar panel with the window buttons, hairline divider, background
  #23272E and sidebar #1E2127, dark only.
- App icon and empty state: the beagle logo with rounded corners (`scripts/make-icon.swift` → `Rocky.icns`,
  `Icons/rocky.png`). Claude and OpenCode logos on tabs, menus and reply footers.
- Loading: a Material-style arc (`CircularProgress`, white). While a turn runs the conversation shows only the arc
  and the elapsed time ("1m 5s"); the sidebar row shows the arc.
- Replies: Markdown through Textual, styled like Conductor (headings, lists, code blocks with language and Copy,
  tables), inline code as a bordered badge (`InlineCodeAttachment`), a footer per turn (agent, duration, time,
  Copy).
- Activity rows like Conductor's: an icon per tool kind, a short label ("Read image", "Edit", "Run", "Load
  skill", "User input") and badges for files, commands, thoughts and status (FAILED, ANSWERED). Consecutive tool
  calls fold into "N tool calls"; thinking shows its first line and opens on click.
- Message box: floats over the conversation (opaque, shadow), text with files inside it as badges
  (`ComposerTextView`; each file is a `FileAttachment` drawn as an image of `FileBadgeLook`). Return sends, Shift-Return starts a line, ⇧Tab
  switches plan mode, ⌘U attaches, paste and drop add files where the text is.
- Model menu (models with detail, effort chips, fast switch) and the + menu (Add attachment, Plan mode); the tabs'
  + (new Claude Code or OpenCode conversation); the repo menu and the workspace's right-click menu. All drawn by
  `MenuPresenter` and `MenuHost`.
- File badges: icon colored by file type, name; hover shows a preview (`FilePreviewPanel`: the image, the first
  lines of a text file, or icon and size); click opens the file in a tab of the workspace (`FileTabView`: image,
  rendered Markdown, monospaced text, or Quick Look). The badges of tool calls (files the agent read or edited) open
  the same way, which is where a later "see what the agent changed" belongs.
- The agent's questions show in a card above the message box, one question at a time: a step per question (its
  header) at the top, options (radio or checkboxes), an "Other" box, Skip, Back, Next and Submit on the last. Picking
  a single-choice option moves on.
- Zoom, like a browser's: View ▸ Zoom In (⌘+, also ⌘=), Zoom Out (⌘-), Actual Size (⌘0), with the current
  percentage in the menu; steps from 80% to 180%, remembered (`zoom`). `Zoom` scales every font (`Font.rocky`) and
  the sizes that hold text: badges, inline code, menus, the reading column, icons, the message box and the terminal
  font. It does not scale the rendered window: a scaled AppKit view stopped receiving clicks near its edges
  (`hitTest` returned the hosting view in a test).
- Rocky ▸ Settings… (⌘,), a settings window for what applies to the whole app: zoom, folding the terminal panel,
  the terminal font, refreshing the login shell environment, the Claude adapter and OpenCode paths, and where the
  database and logs are (each path opens in Finder).
- Scroll bars are the overlay kind everywhere (knob only, while scrolling), whatever System Settings says: Rocky
  sets `AppleShowScrollBars` to `WhenScrolling` in its own defaults at launch.
- Agent updates: Settings ▸ Agents shows each agent's installed, newest and tested version (and the Claude Code
  version the adapter bundles), with Update and "Use <tested>" buttons and Check Now. Rocky asks the npm registry
  over HTTPS once a day on its own, at launch or when Settings opens (`lastAgentUpdateCheck`), and never updates
  without a click. A copy older than the tested version is reinstalled at launch, so raising
  `claudeAdapterVersion` or `openCodeVersion` reaches an existing install. On 2026-09-23 npm had the adapter
  0.81.1 (Rocky tests 0.81.0, which bundles Claude Code 2.1.280) and OpenCode 1.18.32.
- The model menu searches when an agent has more than eight models (OpenCode lists every provider's): a search
  field focused on open, models grouped by provider (`ModelGroup`), a list that scrolls, Return picks the first
  match.
- Message history in the message box, like a shell's (`MessageHistory`): with the box empty, ↑ brings back the
  conversation's last message (its files as badges where they were), ↑ again the one before, ↓ forward to an empty
  box. It browses only while the box shows a message untouched and the cursor is on the first line (↑) or the last
  (↓); otherwise the arrows move the cursor.
- The message box and the question card reach 14 points past the conversation's column on each side, so their
  text lines up with the conversation's.
- Terminal tabs are named "Terminal 1", "Terminal 2"… by position, so the numbers run from 1 to the number of
  terminals; scripts keep Setup, Run and Archive.
- The terminal panel folds to its bar and back (chevron in the bar, ⌘J) without stopping its terminals or scripts;
  choosing a tab, opening a terminal or Run unfolds it. The choice is remembered (`terminalPanelCollapsed`).

### Known issues

- **Fixed: OpenCode failed in repos that Conductor opened** (`Agent exited (1). no such column: project_id`).
  Conductor ships its own OpenCode (2.0.5, unreleased on npm) and migrated the shared database
  `~/.local/share/opencode/opencode.db`: its `workspace` table became `(id, provider, binding, created_at,
  last_used_at)`, while 1.18.x expects `project_id` and five more columns. Rocky's own OpenCode with its own data
  folder (see Rules that changed) starts in the `bergen` worktree; checked by hand with 1.18.32.
- **The chat's scroll bar grew and shrank while scrolling:** a `LazyVStack` guesses the height of rows it has not
  drawn. The conversation is now a plain `VStack`, and unchanged rows skip their body (`ChatItemRow` is
  `Equatable`).
- The manual checklist of Task 10 and the energy measurement have not run yet.

## Global constraints

- macOS 14.0 minimum, Swift 6 language mode, Xcode 27.0 active. *(Now macOS 15: see Changes during implementation.)*
- Dependencies: GRDB 7.11.1 and SwiftTerm 1.20.0, both `exact:`. Nothing else. *(Textual 0.5.0 added: see Changes during implementation.)*
- Branch: create `feat/m2-terminal-scripts-env` from `development` after this plan is merged into it. Never commit on `development`. There is no remote: never add one, never push. The work lands by merging into `development` at the end of Task 10, only with the user's approval.
- No `swift build` and no `swift test` before Task 10. `swift package resolve` in Task 1 is allowed: it resolves without compiling. *(The user later asked for a rebuild after every change; tests still run once at the end.)*
- Commits: Conventional Commits, lowercase imperative, no `Co-Authored-By` or AI attribution line. Never `--no-verify`.
- Shell: use `bat`, `eza`, `rg`, `fd`, `sd` (this machine blocks `cat`, `ls`, `grep`, `find`, `sed` in agent shells).
- Energy (spec Section 1): no timers that poll. Processes start only on user action; creating a workspace counts for its setup script. PTY output is event-driven (DispatchIO). *(Exception since 2026-09-23: the agent of the conversation on screen starts in the background.)*
- All code, comments, identifiers and UI copy in English.
- Manual tests use personal repos only (`~/Documents/dev/personal/rocky`). M1 was tested against `~/Documents/dev/rentek/doculift`; do not repeat that.

## Review Focus

1. Quitting Rocky leaves no terminal or script process: `AppDelegate` calls `stopAllProcesses()`. Pinned by `AppModelProcessTests.stopAllProcessesEndsTerminalsAndScripts` and manual item 6.
2. Stop reaches the whole process group and escalates to SIGKILL. Pinned by `PTYSessionTests.stopEndsTheWholeProcessGroup` and `stopEscalatesToSIGKILLWhenTERMIsIgnored`.
3. A secret value never reaches SQLite. Pinned by `AppModelProcessTests.repoVariablesReachAgentsAndTerminalsAndSecretsStayOutOfTheDatabase` and manual item 5.
4. A failed archive script deletes nothing without "Remove Anyway". Pinned by `AppModelProcessTests.failedArchiveKeepsTheWorkspaceUntilRemoveAnyway`.
5. A repo variable cannot set `CLAUDE_CONFIG_DIR`. Pinned by `WorkspaceEnvironmentTests.repoVariableCannotSetClaudeConfigDir`.
6. A rebuilt Rocky reads secrets without a Keychain dialog: manual item 7.

## SwiftTerm facts this plan relies on

Read from the v1.20.0 source on 2026-09-23:

- `LocalProcess(delegate:dispatchQueue:)` and `startProcess(executable:args:environment:execName:currentDirectory:)` take the environment as `["KEY=value"]`. The child comes from `forkpty`, so it is a session leader: its pid is also its process group id.
- `processTerminated(_:exitCode:)` receives the raw `waitpid` status, not the exit code (`LocalProcess.swift`, `processTerminated()`, lines 365–371).
- `terminate()` sends SIGTERM to the pid only and cancels the exit monitor (lines 561–587). After it, no exit callback arrives and the child is never reaped.
- There is no end-of-output callback, so output can still arrive after the exit event. The read handlers hold the `LocalProcess` weakly, so releasing it right after exit drops that late output.
- If `forkpty` fails, `running` stays false and no callback comes. If `execve` fails in the child, it exits 127.
- `LocalProcessDelegate` and `TerminalViewDelegate` are not actor-isolated, because SwiftTerm builds in Swift 5 mode (`Package.swift` line 159). Conform to them with `@preconcurrency`.
- `TerminalViewDelegate` has no default implementation for `sizeChanged`, `setTerminalTitle`, `hostCurrentDirectoryUpdate`, `send`, `scrolled` or `rangeChanged`.
- M1's `LoginEnvironment.capture` runs the shell with `TERM=dumb`, so the captured environment has `TERM=dumb`. PTY sessions must set `TERM=xterm-256color` and `COLORTERM=truecolor`.

## File structure

```
Package.swift                                            + SwiftTerm; GRDB for the test target
Sources/RockyKit/Terminal/PTYSession.swift               new
Sources/RockyKit/Environment/WorkspaceEnvironment.swift  WorkspaceContext + layers
Sources/RockyKit/Environment/PortAllocator.swift         new
Sources/RockyKit/Store/Records.swift                     repo scripts, workspace port/baseRef, RepoVar
Sources/RockyKit/Store/RockyStore.swift                  migration v2, ports, repo variables
Sources/RockyKit/Store/SecretStore.swift                 new
Sources/RockyKit/Scripts/ScriptConfig.swift              new
Sources/RockyKit/App/AppModel.swift                      processes, environment, scripts, variables
Sources/RockyUI/TerminalHostView.swift                   new
Sources/RockyUI/WorkspacePanelView.swift                 new
Sources/RockyUI/WorkspaceDetailView.swift                split view + Run button
Sources/RockyUI/RepoSettingsView.swift                   scripts + variables
Sources/RockyUI/SidebarView.swift                        archive failure alert
Sources/Rocky/RockyApp.swift                             stopAllProcesses, Refresh Shell Environment
scripts/make-app.sh                                      Rocky Local signing
README.md
Tests/RockyKitTests/PTYSessionTests.swift                new
Tests/RockyKitTests/WorkspaceEnvironmentTests.swift      new
Tests/RockyKitTests/RockyStoreV2Tests.swift              new
Tests/RockyKitTests/SecretStoreTests.swift               new
Tests/RockyKitTests/ScriptConfigTests.swift              new
Tests/RockyKitTests/AppModelProcessTests.swift           new
```

---

### Task 1: SwiftTerm and PTY sessions

**Files:** `Package.swift`, `Package.resolved`, `Sources/RockyKit/Terminal/PTYSession.swift`, `Tests/RockyKitTests/PTYSessionTests.swift`.

- [ ] **Step 1:** `git switch development && git switch -c feat/m2-terminal-scripts-env`.
- [ ] **Step 2:** In `Package.swift`, add SwiftTerm `exact: "1.20.0"` as a dependency of `RockyKit` and `RockyUI`. Add the GRDB product to `RockyKitTests`, because Task 3's migration test opens a v1 database directly. Run `swift package resolve`.
- [ ] **Step 3:** Write `PTYSession.swift`:

```
struct PTYCommand: Sendable, Equatable
  executable: String, arguments: [String], environment: [String: String], cwd: URL
  static func script(_ script: String, environment:, cwd:) -> PTYCommand      // /bin/zsh -c <script>

enum PTYState: Equatable, Sendable, CustomStringConvertible
  running | exited(Int32) | signaled(Int32) | failedToStart
  init(waitStatus: Int32)                 // raw waitpid status → exited / signaled
  isRunning: Bool
  description                             // "Running", "Exited 3", "Stopped by signal 15", "Could not start"

@MainActor @Observable final class PTYSession: Identifiable
  init(title:, command:, stopSignal: Int32 = SIGTERM, stopGracePeriod: Duration = .seconds(5),
       maxOutputBytes: Int = 2_000_000)
  id: UUID, title, command, state (observed), output: [UInt8], outputText: String, pid: pid_t
  start()
  send(_ bytes: ArraySlice<UInt8>), send(_ text: String)
  resize(cols: Int, rows: Int)
  attach(_ viewerId: UUID, onOutput: @escaping (ArraySlice<UInt8>) -> Void) -> [UInt8]   // returns the replay
  detach(_ viewerId: UUID)
  waitForExit() async -> PTYState
  stop() async
```

It must:
- Create `LocalProcess` with `dispatchQueue: .main` and conform to `LocalProcessDelegate` with `@preconcurrency`.
- Override `TERM` and `COLORTERM` in the child's environment.
- Report `failedToStart` when `startProcess` leaves no pid. An exec failure shows up as `exited(127)`.
- Decode the exit with `PTYState(waitStatus:)`.
- In `stop()`, run `kill(-pid, stopSignal)`, then `kill(-pid, SIGKILL)` after the grace period if the session is still running, and wait for the exit.
- Never call `LocalProcess.terminate()`, and keep the `LocalProcess` alive after exit (see "SwiftTerm facts").
- When output passes the cap, drop the oldest bytes.
- Allow one viewer. `detach` only clears the viewer when the id matches, because SwiftUI can build the new view before dismantling the old one.

- [ ] **Step 4:** Write `PTYSessionTests` (`@MainActor`). Output can arrive after the exit event, so poll the output for up to about 3 s.
  - `decodesWaitStatus`: `3 << 8` → `exited(3)`; `0` → `exited(0)`; `SIGKILL` → `signaled(SIGKILL)`.
  - `runsAScriptAndReportsItsExitCode`: `printf 'hi from pty'; exit 3` → `exited(3)`, and the output contains the text.
  - `passesEnvironmentWorkingDirectoryAndARealTerm`: prints `$ROCKY_PROBE|$PWD|$TERM`. `TERM=dumb` is passed in, and `xterm-256color` must come out. The cwd comes from `Fixtures.temporaryDirectory`, whose path is already resolved.
  - `inputReachesTheProcess`: `read line; printf 'got:%s' "$line"`, then `send("abc\n")`.
  - `stopEndsTheWholeProcessGroup`: `sleep 30 & printf 'child:%s;' $!; wait`. After `stop()`, the state is `signaled(SIGTERM)` and the background pid is gone (poll `kill(pid, 0)`; launchd reaps it).
  - `stopEscalatesToSIGKILLWhenTERMIsIgnored`: `trap '' TERM; printf ready; sleep 30` with a 300 ms grace. Wait for `ready`, then stop → `signaled(SIGKILL)`.
  - `keepsOnlyTheLastOutputBytes`: 5000 `x` then `END`, with a cap of 1000 → `output.count == 1000` and the output ends in `END`.
  - `missingExecutableExitsWith127`.
- [ ] **Step 5:** Commit `feat(kit): add pty sessions over swiftterm`. Include `Package.resolved`.

### Task 2: Workspace environment and ports

**Files:** `Sources/RockyKit/Environment/WorkspaceEnvironment.swift` (modify), `Sources/RockyKit/Environment/PortAllocator.swift`, `Tests/RockyKitTests/WorkspaceEnvironmentTests.swift`.

```
struct WorkspaceContext: Sendable, Equatable
  name, path, rootPath: String; defaultBranch: String?; port: Int?
  static func branchName(fromBaseRef: String) -> String     // "origin/main" → "main"; "main" stays
  variables: [String: String]                              // the workspace variables in "Decisions"

WorkspaceEnvironment.make(login:, workspace: WorkspaceContext? = nil,
                          repoVariables: [String: String] = [:], claudeConfigDir: String?) -> [String: String]

enum PortAllocator
  firstPort = 41000, blockSize = 10
  static func next(taken: [Int]) -> Int
```

It must:
- Apply the layers in the order given in "Decisions".
- Keep M1's call `make(login:claudeConfigDir:)` compiling with the same result.
- Leave `strippedKeys` and `ClaudeInstances` unchanged.

Tests:
- `workspaceVariablesUseRockyAndConductorNames`: every name in "Decisions", plus `PATH` from the login shell.
- `laterLayersWin`: a repo `PORT` beats the workspace `PORT`, `CONDUCTOR_PORT` keeps the workspace value, and a repo `API_URL` beats the shell's.
- `repoVariableCannotSetClaudeConfigDir`: covers both with and without a repo setting.
- `branchNameDropsOrigin`.
- `portsComeInBlocksOfTenAndReuseGaps`: `[]` → 41000; `[41000, 41010]` → 41020; `[41000, 41020]` → 41010.

Commit `feat(kit): layer workspace environment and allocate ports`.

### Task 3: Store v2

**Files:** `Sources/RockyKit/Store/Records.swift`, `Sources/RockyKit/Store/RockyStore.swift`, `Tests/RockyKitTests/RockyStoreV2Tests.swift`.

Migration `v2`:
- `repo`: add `setupScript`, `runScript`, `archiveScript` and `runScriptMode` (text, nullable).
- `workspace`: add `port` (integer) and `baseRef` (text).
- New table `repoVar`:
  - `id` primary key; `repoId` references `repo` with cascade delete.
  - `name`; `value` (null for a secret); `isSecret` (bool, not null, default false); `createdAt`.
  - Unique on `(repoId, name)`.
- Give each existing workspace a port, oldest first (41000, 41010, …). Its `baseRef` stays null, because M1 did not store it.

Interface:
- `Repo` and `Workspace` get the new fields as init parameters defaulting to nil, so every existing call site keeps compiling.
- `struct RepoVar` record.
- `RockyStore` gets:
  - `update(_ workspace:)` and `nextPort()`.
  - `repoVars(repoId:)`, ordered by name.
  - `save(_ variable:)`: upserts by `(repoId, name)` and keeps the old `id` and `createdAt`.
  - `deleteRepoVar(repoId:name:)`.
- `migrator` goes from `private` to internal, so the test can migrate up to `v1` only.

Tests:
- `migrationGivesExistingWorkspacesTheirOwnPorts`: build a v1 file database with two workspaces inserted by SQL, then open `RockyStore(path:)` → ports `[41000, 41010]`, `nextPort() == 41020`.
- `repoScriptsAndWorkspacePortPersist`.
- `repoVariablesUpsertByNameAndGoWithTheRepo`: the second save replaces the first, delete works, and deleting the repo removes its variables.

Commit `feat(kit): store scripts, ports and repo variables`.

### Task 4: Secrets in the Keychain

**Files:** `Sources/RockyKit/Store/SecretStore.swift`, `Tests/RockyKitTests/SecretStoreTests.swift`.

```
protocol SecretStore: Sendable
  read(account: String) throws -> String?          // nil when missing
  write(_ value: String, account: String) throws
  delete(account: String) throws                    // missing is not an error
struct KeychainSecretStore: SecretStore  { init(service: String = "dev.jhzl.rocky.repo-var") }
final class InMemorySecretStore: SecretStore     // tests
enum SecretStoreError: Error, Equatable { keychain(OSStatus) }
```

It must:
- Store generic passwords in the login Keychain. Not the data-protection keychain: that one needs entitlements an app without an Apple team cannot have.
- Use the account `<repoId>/<NAME>` and the label `Rocky: <account>`.
- In `write`, update the item, and add it on `errSecItemNotFound`.

Tests:
- `inMemoryStoreReadsWritesAndDeletes`.
- `keychainRoundTrip`: a unique service per run, cleaned up in `defer`, covering write, overwrite, read, delete, and read → nil.

Risk: this test uses the real login Keychain. If it ever shows a dialog, `swift test` blocks. Record that in the task report and disable the test with that reason; do not hide it.

Commit `feat(kit): keep repo secrets in the keychain`.

### Task 5: Script configuration

**Files:** `Sources/RockyKit/Scripts/ScriptConfig.swift`, `Tests/RockyKitTests/ScriptConfigTests.swift`.

```
enum RunScriptMode: String, CaseIterable, Identifiable, Sendable { concurrent, nonconcurrent }
struct ScriptConfig: Equatable, Sendable
  setup, run, archive: String?; runMode: RunScriptMode; source: .conductorJSON | .repoSettings
enum ScriptConfigError: Error, Equatable, CustomStringConvertible
  invalidConductorJSON(String)                     // description: "conductor.json is not valid: <reason>"
enum ScriptConfigResolver
  fileName = "conductor.json"
  static func resolve(workspace: URL, repo: Repo) throws -> ScriptConfig
  static func clean(_ script: String?) -> String?  // blank or whitespace → nil
```

It must:
- Read these keys: `scripts.setup`, `scripts.run`, `scripts.archive`, `runScriptMode`.
- Ignore unknown keys, such as `enterpriseDataPrivacy`.
- Reject an unknown `runScriptMode` with a reason that names the value.
- When the file is absent, use the repo settings, with the run mode defaulting to `concurrent`.

Tests:
- `readsTheConductorDocsExample`: use the example below, verbatim.
- `fallsBackToRepoSettingsAndDropsBlankScripts`.
- `rejectsInvalidJSON`.
- `rejectsUnknownRunMode`.

Conductor's example (`https://www.conductor.build/docs/core/conductor-json`):

```json
{
    "scripts": {
        "setup": "pnpm install",
        "run": "pnpm dev --port $CONDUCTOR_PORT",
        "archive": "./script/workspace-archive.sh"
    },
    "runScriptMode": "concurrent",
    "enterpriseDataPrivacy": true
}
```

Commit `feat(kit): resolve scripts from conductor.json or repo settings`.

### Task 6: App model

**Files:** `Sources/RockyKit/App/AppModel.swift`, `Tests/RockyKitTests/AppModelProcessTests.swift`.

```
@MainActor @Observable final class WorkspaceProcesses
  setup, run, archive: PTYSession?; terminals: [PTYSession]
  all: [PTYSession]                                  // scripts first, then terminals: the tab order
struct ArchiveFailure: Equatable, Sendable { workspaceId, workspaceName, message: String }

AppModel
  init(<M1 parameters>, secrets: SecretStore = KeychainSecretStore(),
       terminalShell: @Sendable ([String: String]) -> (executable: String, arguments: [String]) = $SHELL -l,
       processStopGracePeriod: Duration = .seconds(5))     // new parameters last: M1 tests keep compiling
  var archiveFailure: ArchiveFailure?
  func workspace(id: String) -> Workspace?
  func existingProcesses(for workspaceId: String) -> WorkspaceProcesses?   // never creates: views call it
  func environment(for workspace: Workspace) -> [String: String]
  func setScripts(repoId:, setup:, run:, archive:, runMode:)
  func repoVars(repoId:) -> [RepoVar]
  func setRepoVar(repoId:, name:, value:, isSecret:)
  func deleteRepoVar(repoId:, name:)
  func startRun(workspaceId:) async, stopRun(workspaceId:) async
  func openTerminal(workspaceId:) -> PTYSession?, closeTerminal(workspaceId:, sessionId:) async
  func removeWorkspace(id:, skipArchive: Bool = false) async
  func stopAllProcesses() async
```

It must:
- **Environment:** `openChat`, scripts and terminals all use `environment(for:)`; it replaces M1's direct `WorkspaceEnvironment.make` call in `openChat`. If a secret cannot be read, set `errorMessage` and skip that variable.
- **Creating a workspace:** `createWorkspace` stores `port = store.nextPort()` and `baseRef` from `CreatedWorktree`. Once the workspace is saved and selected, it starts Setup when there is a setup script. An invalid `conductor.json` sets `errorMessage` and keeps the workspace.
- **Run:**
  - With no run script, `startRun` sets `"<name> has no run script. Add one in the repo settings or in conductor.json."`.
  - A Run that is already running is a no-op.
  - In `nonconcurrent` mode it first stops every other running Run.
- **Terminals:** titled `<shell name> <n>`, with `stopSignal: SIGHUP`.
- **`removeWorkspace`:**
  1. Stop the chat and every session.
  2. Unless `skipArchive`, resolve the scripts. An error sets `archiveFailure` with the error text and stops here.
  3. Run the Archive script with its tab visible and `busyMessage` set. If it does not end in `exited(0)`, set `archiveFailure` and return. The messages are "The archive script exited with 7.", "The archive script was stopped by signal N." and "The archive script could not start.".
  4. `git worktree remove`, as in M1, then forget the processes.
- **`removeRepo`:** stops its workspaces' chats and sessions, and deletes its secrets from the `SecretStore` before deleting the repo.
- **`setRepoVar`:**
  - The name must match `[A-Za-z_][A-Za-z0-9_]*`; otherwise set `errorMessage` and save nothing.
  - A secret goes to the `SecretStore`, and its row has value nil.
  - A plain value goes in the row, and any old secret with that name is deleted.
- **Implementation details:**
  - Write `self.workspace(id:)` and `self.environment(for:)` wherever a parameter or local has the same name.
  - `processes` is observed, like `chats`, and is created only inside actions.
  - `stopAllProcesses` stops chats and every session concurrently (task group), each one bounded by the grace period.

Tests in `AppModelProcessTests`:
- **Setup:** give it its own `makeModel` with `InMemorySecretStore`, `terminalShell: { _ in ("/bin/zsh", ["-f"]) }` (so this machine's rc files do not run) and a 500 ms grace. Reuse `LaunchBox` from `AppModelTests.swift`.
- `setupRunsOnceInTheNewWorkspaceWithItsOwnPort`: setup writes `$PORT` to a file → `41000`; `workspace.port == 41000`, `baseRef == "main"`.
- `conductorJSONInTheWorkspaceWinsOverRepoSettings`: a committed `conductor.json` with setup `touch from-json`, against the setting `touch from-settings`.
- `nonconcurrentRunStopsTheOtherWorkspacesRun`: two workspaces with run `sleep 30`. The first becomes `signaled(SIGTERM)` and the second stays running; then `stopRun` on the second.
- `runWithoutAScriptExplainsWhereToAddOne`.
- `failedArchiveKeepsTheWorkspaceUntilRemoveAnyway`: archive `exit 7` → the exact message, and the folder still exists. With `skipArchive` → the folder is gone.
- `repoVariablesReachAgentsAndTerminalsAndSecretsStayOutOfTheDatabase`:
  - One plain and one secret variable. The launch environment has both, plus `CONDUCTOR_PORT`.
  - The secret's row has value nil, and the secret store holds the value.
  - In a terminal, `printf '<%s>' "$API_TOKEN"; exit` outputs `<s3cret>`.
  - After `removeRepo`, the secret is gone.
- `stopAllProcessesEndsTerminalsAndScripts`.
- `rejectsInvalidVariableNames`: `1ABC`, `A-B` and an empty name → `errorMessage`, nothing saved.

Commit `feat(kit): run workspace scripts and terminals with layered env`.

### Task 7: Repo settings

**Files:** `Sources/RockyUI/RepoSettingsView.swift`.

It must:
- Have these sections:
  - **Claude instance**, as in M1.
  - **Scripts:** multi-line setup, run and archive fields with example prompts, a run mode picker, and a note that a `conductor.json` at the workspace root replaces them.
  - **Variables:** rows with name, value, a Secret checkbox and remove; an Add Variable button; and a note that secrets go to the Keychain and running processes keep their old values.
- Never read a saved secret's value back into the form. Its field shows "unchanged", and leaving it empty keeps the stored value.
- On Save, apply in this order: scripts, then removed variables, then renamed ones (delete the old name), then changed ones, then the Claude instance (async, as in M1). Skip empty names.

No automated test (UI only); covered by manual items 1 and 5.

Commit `feat(ui): edit repo scripts and variables`.

### Task 8: Terminal panel

**Files:** `Sources/RockyUI/TerminalHostView.swift`, `Sources/RockyUI/WorkspacePanelView.swift`, `Sources/RockyUI/WorkspaceDetailView.swift`, `Sources/RockyUI/SidebarView.swift`.

It must:
- **`TerminalHostView`**, an `NSViewRepresentable` around SwiftTerm's `TerminalView` with a monospaced 12 pt font:
  - Attach and feed the replay in `makeNSView`; detach in `dismantleNSView`.
  - Send keystrokes to `session.send`, and `sizeChanged` to `session.resize`.
  - Implement the six delegate methods that have no default.
  - Use `.id(session.id)`, so each session gets its own view.
- **Panel:**
  - One tab per `processes.all`, with a dot that is green while running.
  - A close button on terminal tabs only; `+` opens a terminal and selects it.
  - The status of the selected tab (`PTYState.description`).
  - Empty state: "Press + to open a terminal in <name>."
  - With nothing chosen, the newest tab is selected.
- **Detail view:**
  - The header adds `PORT 41000` (help text: ports 41000–41009) and a Run/Stop button. Run selects the Run tab.
  - Below the header, a `VSplitView` with the chat (min height 200) over the panel (min 120, ideal 240). The chat is still read from the model, as in M1.
  - Write port numbers into `Text` with `String(port)`: interpolating an `Int` in `Text` localizes it as "41,000".
- **Sidebar:**
  - The removal confirmation mentions the archive script.
  - An alert "Archive script failed" with Remove Anyway and Cancel, and the message "<message> <name> was not removed; the Archive tab shows its output."

No automated test (UI only); covered by manual items 2–4 and 8.

Commit `feat(ui): add terminal and script panel to workspaces`.

### Task 9: App wiring, signing, README

**Files:** `Sources/Rocky/RockyApp.swift`, `scripts/make-app.sh`, `README.md`.

It must:
- Make `applicationShouldTerminate` call `stopAllProcesses()`.
- Add the command "Refresh Shell Environment" after the app settings group; it calls `model.refreshEnvironment()`.
- In `make-app.sh`, use the identity `${ROCKY_SIGN_IDENTITY:-Rocky Local}`. If `security find-identity -p codesigning` lists `"<identity>"`, sign with it. Otherwise print a warning on stderr and sign ad hoc. Match with bash `[[ … == *…* ]]`, not `grep`.
- Add to the README: the one-time certificate steps, a short summary of terminals, scripts and variables, and Refresh Shell Environment.

The user runs this step before item 7 of Task 10:
1. `open -a "Keychain Access"`.
2. Keychain Access → Certificate Assistant → Create a Certificate…
3. Name `Rocky Local`, Identity Type `Self Signed Root`, Certificate Type `Code Signing`, then Create.
4. `security find-identity -p codesigning` lists `"Rocky Local"`.
5. On the first `scripts/make-app.sh` with it, macOS asks to let `codesign` use the key: choose Always Allow. If `codesign` rejects the identity as untrusted, open the certificate → Trust → Code Signing: Always Trust.

Commit `feat(app): stop terminals on quit and sign with a stable identity`.

### Task 10: Build, tests and M2 verification

The only task that compiles or runs tests. It runs once all code from Tasks 1–9 is committed.

- [ ] **Step 1:** `swift build && swift test`. Fix each error in the smallest way that keeps the task's interfaces and tests, commit the fix with that task's scope, and run again until everything passes. Where problems are expected: Swift 6 isolation around the SwiftTerm delegates, and SwiftUI type-checking in the panel.
- [ ] **Step 2:** Run `PTYSessionTests` and `AppModelProcessTests` three times each, to catch timing failures.
- [ ] **Step 3:** `scripts/make-app.sh && open build/Rocky.app`.
- [ ] **Step 4:** Manual checklist, run by the user on `~/Documents/dev/personal/rocky`:
  1. In repo settings, set:
     - setup `echo "setup on $PORT"; sleep 1`
     - run `python3 -m http.server $PORT`
     - archive `echo archived`
     - variables `ROCKY_DEMO=hello` (plain) and `ROCKY_SECRET=s3cret` (secret)

     Then Save.
  2. New Workspace → the Setup tab shows `setup on 41xxx` and `Exited 0`.
  3. Open a terminal with `+`. `pwd` → the worktree path. `echo $ROCKY_DEMO $ROCKY_SECRET $ROCKY_PORT` → `hello s3cret 41xxx`. *(Was `$CONDUCTOR_PORT` before Rocky dropped Conductor's names.)*
  4. Run → the Run tab shows `Serving HTTP on … port 41xxx`. In the terminal, `curl -sI localhost:$PORT | head -1` → `HTTP/1.0 200 OK`. Stop → `Stopped by signal 15`.
  5. `sqlite3 -readonly ~/Library/Application\ Support/Rocky/rocky.sqlite "SELECT name, value, isSecret FROM repoVar"` → `ROCKY_SECRET` has an empty value. Searching `Rocky:` in Keychain Access shows it.
  6. Run again, open a terminal, and quit with ⌘Q. Then `pgrep -fl http.server` → no output.
  7. `scripts/make-app.sh`, reopen Rocky, open a new terminal. `echo $ROCKY_SECRET` → `s3cret`, with no Keychain dialog.
  8. Set the archive to `exit 3`, then Remove Workspace → the alert appears → Remove Anyway → the folder is gone and the branch is kept.
  9. Energy at rest: leave Rocky idle for 30 min, then `scripts/energy-report.sh 30` → `processes_per_min` below 5.
- [ ] **Step 5:** Write `docs/superpowers/m2-verification.md` with:
  - The date and the `swift test` summary line.
  - A pointer to "Changes during implementation", and a manual check of what it added: conversation tabs, the model
    and + menus, plan mode, a pasted image inside the message box and in the sent message, a file badge's hover
    preview and file tab, an agent question answered in its card.
  - Each item as pass, fail or not run, with the literal output for items 3, 5 and 6.
  - The energy report output.
  - Known issues, with the exact error text.
- [ ] **Step 6:** Commit `docs(m2): add verification record`.
- [ ] **Step 7:** Only with the user's approval: `git switch development && git merge --ff-only feat/m2-terminal-scripts-env`.

## Known risks

- **Nothing here is compiled.** The interfaces were checked against the SwiftTerm source and the M1 code, not against the compiler.
- **SwiftTerm ships a build-tool plugin** (`SwiftTermBuildInfoPlugin`). `swift build` runs it; opening the package in Xcode asks to trust it.
- **Some processes survive Stop and Quit:** those that leave the process group, such as `nohup`, `setsid`, or daemons started by `docker compose up -d`. The archive script is the place to stop them.
- **The 2 MB cap loses older output.** A replay can also start in the middle of an escape sequence, which garbles one line.
- **The user's rc files can override repo variables in terminals.** `$SHELL -l` runs them after Rocky sets the environment, so a variable they export wins over the repo variable of the same name in terminals (not in scripts or agents).
- **Secrets saved before the `Rocky Local` certificate exists** (from an ad hoc build) ask once after the switch.
- **Keychain reads run on the main actor.** With the stable identity they do not block; without it, a dialog freezes the UI until answered.
- **Ports from 41000 up may already be in use** by another program; Rocky does not check.
- **M1 workspaces get ports in the migration, but no `baseRef`**, so `ROCKY_DEFAULT_BRANCH` and `CONDUCTOR_DEFAULT_BRANCH` are not set for them.
