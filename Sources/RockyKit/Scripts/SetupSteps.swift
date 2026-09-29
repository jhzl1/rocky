import Foundation

/// WSC-05: what a new workspace's Setup tab runs, in order: the repository's own post-checkout hook, where and as git
/// would have run it for a new worktree, then the Setup script (`rocky.json` or the repository settings). Git itself runs
/// no hook any more (`WorktreeService.create`), so a hook that installs dependencies shows its progress here instead of
/// holding the creation.
///
/// It is one zsh script in one tab. Each step opens with its line in ANSI bright black, the terminal's `textTertiary`
/// ("▸ post-checkout hook · .husky/post-checkout"), and a step that is not the last closes with its end line
/// ("post-checkout exited with code 0"); the last one's end is the panel's own TERM-03 line. A step that exits non-zero
/// ends the script with its code, so the next never runs, as the hook's exit decides `git checkout`'s.
public struct SetupSteps: Sendable, Equatable {
    /// The repository's post-checkout hook, as `WorktreeService.postCheckoutHook` found it.
    public struct Hook: Sendable, Equatable {
        public let path: URL
        /// The path its step line shows: under the worktree (`.husky/post-checkout`), else under the main clone
        /// (`.git/hooks/post-checkout`), else in full.
        public let label: String
        /// The commit the worktree checked out, git's second argument.
        public let head: String

        public init(path: URL, label: String, head: String) {
            self.path = path
            self.label = label
            self.head = head
        }

        /// `label` for a hook at `path` in a workspace's `worktree`, made from `mainClone`.
        public static func label(of path: URL, worktree: URL, mainClone: URL) -> String {
            let hook = path.resolvingSymlinksInPath().path
            for root in [worktree, mainClone] {
                let prefix = root.resolvingSymlinksInPath().path + "/"
                if hook.hasPrefix(prefix) { return String(hook.dropFirst(prefix.count)) }
            }
            return path.path
        }
    }

    public enum Step: Sendable, Equatable {
        case hook, script
    }

    /// git's first argument for a new worktree: there was no HEAD before.
    public static let nullCommit = String(repeating: "0", count: 40)

    public let hook: Hook?
    public let script: String?

    /// `script` is kept only when it has something to run.
    public init(hook: Hook?, script: String?) {
        self.hook = hook
        let trimmed = script?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.script = trimmed?.isEmpty == false ? script : nil
    }

    /// The steps in the order they run; none means there is no Setup tab.
    public var steps: [Step] {
        (hook == nil ? [] : [.hook]) + (script == nil ? [] : [.script])
    }

    public var isEmpty: Bool {
        steps.isEmpty
    }

    /// "▸ post-checkout hook · .husky/post-checkout".
    public var hookLine: String? {
        hook.map { "▸ post-checkout hook · \($0.label)" }
    }

    /// "▸ Setup · pnpm db:migrate": the script's first line, with "…" when more follow.
    public var scriptLine: String? {
        guard let script else { return nil }
        let lines = script.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let first = lines.first ?? ""
        return "▸ Setup · " + first + (lines.count > 1 ? " …" : "")
    }

    /// The zsh script of the Setup tab (`PTYCommand.script`). The last step is `exec`ed, so the tab's process ends
    /// with its code; a step before it runs, prints its end line, and ends the script when it failed. The Setup script
    /// runs in its own non-interactive zsh, as it did alone.
    public var command: String {
        var lines: [String] = []
        let steps = self.steps
        for (index, step) in steps.enumerated() {
            let isLast = index == steps.count - 1
            switch step {
            case .hook:
                guard let hook, let line = hookLine else { continue }
                lines.append(TaskRunner.echoCommand(line))
                let run = [hook.path.path, Self.nullCommit, hook.head, "1"].map(VSCodeTasks.quoted).joined(separator: " ")
                if isLast {
                    lines.append("exec " + run)
                } else {
                    lines.append(run)
                    // `status` is zsh's own read-only name for `$?`.
                    lines.append("code=$?")
                    lines.append(#"printf '\033[90mpost-checkout exited with code %d\033[0m\n' "$code""#)
                    lines.append(#"if [ "$code" -ne 0 ]; then exit "$code"; fi"#)
                }
            case .script:
                guard let script, let line = scriptLine else { continue }
                lines.append(TaskRunner.echoCommand(line))
                let run = "/bin/zsh -c " + VSCodeTasks.quoted(script)
                lines.append(isLast ? "exec " + run : run)
            }
        }
        return lines.joined(separator: "\n")
    }
}
