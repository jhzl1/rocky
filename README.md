# Rocky

Personal macOS app for running coding agents (Claude Code, OpenCode) in parallel, one git worktree per workspace.
Design: `docs/superpowers/specs/2026-09-22-rocky-design.md`.

## Build and run

    swift test                     # logic tests
    scripts/make-app.sh            # builds build/Rocky.app (release)
    open build/Rocky.app

Requirements: Xcode 27, `git`, `node` + `npm` (Claude adapter), `opencode` on your login-shell PATH.
The Claude adapter (`@agentclientprotocol/claude-agent-acp@0.81.0`) installs itself on first use into
`~/Library/Application Support/Rocky/agents`. Agent logs: `~/Library/Logs/Rocky`.

## Energy

    scripts/energy-report.sh 30    # Rocky vs Conductor over the last 30 minutes, from the macOS power log
