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

## One-time: signing certificate

Repo secrets live in the macOS Keychain, which recognises an app by its signature. `scripts/make-app.sh` signs
with a certificate named `Rocky Local` when it exists, so every rebuild is the same app to the Keychain:

1. `open -a "Keychain Access"`
2. Keychain Access → Certificate Assistant → Create a Certificate…
3. Name `Rocky Local`, Identity Type `Self Signed Root`, Certificate Type `Code Signing`, then Create.
4. Check: `security find-identity -p codesigning` lists `"Rocky Local"`.

The first `scripts/make-app.sh` after that asks to let `codesign` use the key: choose Always Allow. If `codesign`
rejects the identity as untrusted, open the certificate in Keychain Access → Trust → Code Signing: Always Trust.
Without the certificate the script signs ad hoc, and macOS asks again for each secret after every build.

## Workspaces

- Terminal tabs (`+` in the bottom panel) open your login shell in the worktree.
- Scripts: setup runs once when a workspace is created, run starts from the Run button, archive runs before a
  workspace is removed. They come from `rocky.json` at the workspace root when it exists (`scripts.setup`,
  `scripts.run`, `scripts.archive`, `runScriptMode`), else from the repo settings.
- Every agent, terminal and script gets the repo variables, `PORT` (the first of ten ports the workspace owns),
  and `ROCKY_*` variables: `WORKSPACE_NAME`, `WORKSPACE_PATH`, `ROOT_PATH`, `DEFAULT_BRANCH`, `PORT`.
- Rocky → Refresh Shell Environment re-reads your login shell after you edit `~/.zshrc`. Running processes keep
  the environment they started with.

## Energy

    scripts/energy-report.sh 30    # Rocky vs Conductor over the last 30 minutes, from the macOS power log

## Third-party code

- Prism 1.30.0 (https://prismjs.com, MIT License, Copyright (c) 2012 Lea Verou), vendored as
  `Sources/RockyUI/Resources/Prism/prism-bundle.js`: its core and 17 language components, which highlight the diff and
  the editor.
- Material Icon Theme 5.38.1 (https://github.com/material-extensions/vscode-material-icon-theme, MIT License,
  Copyright (c) 2025 Material Extensions), vendored in `Sources/RockyUI/Resources/FileIcons/`: the 586 file icons that
  its file names, file extensions and default reference, plus its GitHub Actions workflow icon (587 SVGs), with a
  trimmed `manifest.json` and the package's `LICENSE`. Folders keep Rocky's own icon.
  `scripts/vendor-file-icons.py` downloads the pinned npm tarball, checks its integrity and version, and writes the
  folder again.
