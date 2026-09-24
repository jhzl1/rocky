# Rocky — Design Spec

## Context
Personal-use, macOS-only clone of Conductor (parallel coding agents, each in its own git worktree).
Same features as Conductor, with two changes:
1. Much lower energy use while agents run.
2. GitHub account bound per repo (today `gh` has one active account system-wide, so celes repos run as `jhzl1`).
Per-repo env var override is included; low priority.

## Evidence (2026-09-22, read-only)
- Conductor 0.87.3 is Tauri (system WebKit, no Electron). The UI is not the cost.
- macOS power log `/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL`,
  table `PLCoalitionAgent_EventInterval_CoalitionInterval`, 16:54–18:33 (battery 100% → 62%):
  - `com.conductor.app` energy 14349 vs Firefox 4267 (next highest) — ~3.4x.
  - 0.88 CPU cores average for 99 min.
  - 144,939 processes started (~24/s). `tasks_started` is cumulative; energy/cpu_time are per-interval.
- Live 15 s sample of Conductor direct children: 12 `zsh` / `zsh -l`, 3 `gh api graphql`, 2 `git`, 1 `claude`.
- `bin/git-busy-check.sh` spawns bash + ~5 `git rev-parse` per call.
- Conductor DB (`conductor.db`): repos celes-platform, veritas; 13 workspaces; 35 diff comments;
  no setup/run/archive scripts or env vars configured.
- Existing GitHub setup: `gh` keyring accounts `jhzl1` (active), `ocampos-biai`; SSH aliases
  `github.com-personal`, `github-celes`; `includeIf` identity in `~/.gitconfig`.

## Decisions
- Stack: SwiftUI native. Personal use: no notarization, no auto-update.
- Agents: Claude Code, Codex, OpenCode through ACP (Agent Client Protocol, JSON-RPC over stdio).
  One Swift client. `opencode acp` native; `@agentclientprotocol/claude-agent-acp` and `@agentclientprotocol/codex-acp` adapters (M0 ran 0.81.0 and 1.13.0).
  Accepted cost: new Claude/Codex features lag until adapters update.
- v1 scope: chat + worktrees, diff + comments + PR, integrated terminal, setup/run/archive scripts.
- Toolchain: full Xcode 27.0 (build 27A266a), chosen for SwiftUI previews, XCTest/swift-testing and Instruments; active via `xcode-select`.
- Codex is deferred to after M1: M1 ships OpenCode and Claude Code only. Codex requires a login (API key or ChatGPT) and its env propagation is still unverified.
- macOS 15 minimum (2026-09-23): agent replies render with Textual 0.5.0, which needs it.
- Rocky draws its own menus, all in one style, instead of the system's (2026-09-23).
- Rocky tells the agent it can show forms (`clientCapabilities.elicitation.form`), so Claude keeps AskUserQuestion and asks in a card in the conversation (2026-09-23).
- Rocky installs and runs its own copy of each agent (2026-09-23): the Claude adapter and OpenCode (`opencode-ai@1.18.32`), in `~/Library/Application Support/Rocky/agents`. OpenCode keeps its own data in `~/Library/Application Support/Rocky/opencode-data`, because Conductor's unreleased OpenCode 2.0.5 migrated the shared `~/.local/share/opencode` database beyond what published versions read.
- What M2 added beyond its plan is recorded in `docs/superpowers/plans/2026-09-23-m2-terminal-scripts-env.md`, section "Changes during implementation".

## Section 1 — Architecture and energy rules
One app process. Child processes only for: one ACP agent per active session, one PTY per terminal tab.

| Conductor today | Rocky |
| --- | --- |
| repeated `zsh -l` | one `zsh -l -c env` at launch, cached, manual refresh |
| polling `git status` / busy-check script | FSEvents on worktree (excluding `node_modules`, `.git/objects`), 500 ms debounce; busy-check via `FileManager` checks on `rebase-merge`, `rebase-apply`, `MERGE_HEAD`, etc. |
| `gh api graphql` loop | GraphQL via `URLSession`, no `gh` spawn; only visible workspace; backoff 30 s → 5 min; paused when window not key |
| renders all streaming | background sessions buffer events; render on open |

Success criterion: at rest, fewer than 5 app-spawned processes per minute (excluding agent tool calls),
measured from `CurrentPowerlog.PLSQL`.

Exception (user decision, 2026-09-23): the agent of the conversation on screen starts in the background when its
tab is shown, so its settings are ready without a click. Hidden tabs start nothing until they are shown.

## Section 2 — GitHub account per repo
1. Accounts come from `gh`: `gh auth token --user <login>` once per account at launch, kept in memory.
   Account = `ghLogin`, `gitName`, `gitEmail`, optional `sshKey`, `claudeConfigDir`.
2. Repo → account inferred from the remote (SSH alias `github-celes` → celes account), overridable in repo settings.
3. Injected into every workspace process (agent, terminal, scripts): `GH_TOKEN`,
   `GIT_AUTHOR_NAME/EMAIL`, `GIT_COMMITTER_NAME/EMAIL`, `CLAUDE_CONFIG_DIR=<repo's Claude instance dir>`,
   and `GIT_SSH_COMMAND="ssh -F /dev/null -i <key> -o IdentitiesOnly=yes"` for SSH remotes.
4. Rocky's own GraphQL calls use the repo account's token.

## Section 3 — Workspaces, terminal, scripts, env
1. Create: `git fetch`, then `git worktree add <repo>/../<repo>-worktrees/<name> -b <branch> origin/<default>`.
   Auto-generated name, renamable.
2. Scripts: setup once on create; run button (concurrent mode); archive before removal.
   Read from `rocky.json` at the workspace root if present, else repo settings in Rocky. (It was `conductor.json`
   until 2026-09-23, when Rocky dropped Conductor compatibility: no `conductor.json`, no `CONDUCTOR_*` variables.)
3. Env layers (later wins): cached login env < repo vars (secrets in Keychain) < account vars.
4. Each workspace gets its own base `PORT`.
5. Terminal: SwiftTerm, one per tab, `cwd` = worktree, same env.

## Section 4 — Diff, comments, PR
1. Diff vs merge-base with default branch; recomputed only on FSEvents change and diff panel visible.
2. Diff comments stored in SQLite; "send to agent" batches pending comments into one prompt.
3. PR: `git push -u` with account env, then GraphQL `createPullRequest` with account token.
4. PR + checks status via GraphQL with Section 1 backoff; merge button via GraphQL.
5. Out of v1: custom per-repo prompts.

## Section 5 — Persistence, errors, testing
- SQLite via GRDB: repos, repo→account, workspaces, sessions + transcript, diff comments, repo vars. Secrets in Keychain.
- Agent crash → session "stopped" + restart. Resume via ACP `session/load` if supported; else new session, old transcript read-only.
- `gh` token failure → per-account banner with the fix command (`gh auth login --hostname github.com`).
- Script failure → exit code + log in panel; workspace stays usable.
- Tests: XCTest for env merge, remote→account resolution, diff parsing, busy-check; ACP client against a fake
  agent replaying recorded JSON-RPC; energy script reading `CurrentPowerlog.PLSQL` over 30 min.

## Milestones (each gets its own implementation plan)
Status as of 2026-09-24 (after M2.7's merge). **Done** means merged into `development`; each plan's first lines say the same.

| # | What | Done when | Status |
| --- | --- | --- | --- |
| M0 | Spike (throwaway) | Swift CLI talks ACP to all 3 agents; confirms `env` reaches agent tools and `GH_TOKEN` push over HTTPS | **Done** 2026-09-22 (`spikes/2026-09-22-m0-findings.md`) |
| M1 | Repos, workspaces, chat | create workspace, chat with OpenCode or Claude Code | **Done** 2026-09-23 (`m1-verification.md`) |
| M2 | Terminal, scripts, env | terminal tabs, setup/run/archive, repo vars | **Done** 2026-09-23; manual checklist still open (`m2-verification.md`) |
| M2.5 | Visual design | a design spec (palette, type, icons, loading states, motion) applied across the app; replaces `Sources/RockyUI/Theme.swift`'s interim colors (added 2026-09-23) | **Done** 2026-09-23; manual checklist still open (`m2.5-verification.md`) |
| M2.6 | Slash commands | the agent's commands in the message box; terminal-only ones in an embedded terminal (added 2026-09-23) | **Done** 2026-09-23, pushed; Task 9 with real agents still open (`m2.6-verification.md`) |
| M2.7 | GitHub pull request panel | Conductor's right panel, one GitHub account per repository, PR state, checks, merge and agent actions (added 2026-09-23) | **Done** 2026-09-24, pushed; manual checklist on a throwaway repository still open (`m2.7-verification.md`) |
| M2.8 | Conversations and agents | "+" creates at once, the default agent, agents in the model menu (added 2026-09-23) | **Designed**: HTML ready, plan not written; starts after M3 (user decision, 2026-09-24) |
| M3 | Diff, comments, editor, files | review, comment, edit and commit; the All files tab to browse and edit any file (added 2026-09-24); its PR part moved to M2.7 | **Planned, next**: HTML and plan ready, All files being designed; starts once M2.7 is merged |
| M4 | Multi-account + energy | per-repo account everywhere; energy measured vs Conductor | **Not planned**: M2.7 already gives each repository its account and `GH_TOKEN`; left: git identity and SSH key per account, and the energy measurement |

## M0 answers
- `gh auth git-credential` honors `GH_TOKEN` for git over HTTPS (verified with `git ls-remote`; `git push` uses the same credential helper but was not exercised): with `GH_TOKEN` set, `gh`/git-over-HTTPS act as that token's account; without it, they fall back to the active `gh` account via `gh auth git-credential` (not an `osxkeychain` cache). Details: `docs/superpowers/spikes/2026-09-22-m0-findings.md`.
- `claude-agent-acp` (the M0 unknown originally named it `claude-code-acp`) passes process `env` to agent tools: a probe value set in the environment round-tripped through the agent's shell tool and appeared in its response text. OpenCode does the same; Codex is unverified because its run failed on an auth error before its shell tool ran. Details: `docs/superpowers/spikes/2026-09-22-m0-findings.md`.
- All three ACP adapters (`opencode acp`, `claude-agent-acp@0.81.0`, `codex-acp@1.13.0`) report `loadSession: true` in `initialize`; resume itself (`session/load`) was not exercised — M1 must test it for real. Details: `docs/superpowers/spikes/2026-09-22-m0-findings.md`.

## Verification
- Spec self-review: no placeholders, sections consistent, each milestone testable.
- M0 exit: the three answers above, each backed by command output in `docs/superpowers/spikes/2026-09-22-m0-findings.md`.
