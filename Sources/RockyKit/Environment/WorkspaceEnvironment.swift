import Foundation

/// What a workspace process knows about its workspace, exported as `PORT` and ROCKY_* variables. Rocky exported
/// Conductor's CONDUCTOR_* names too until 2026-09-23, when it stopped reading conductor.json (user decision).
public struct WorkspaceContext: Sendable, Equatable {
    public let name: String
    public let path: String
    public let rootPath: String
    public let defaultBranch: String?
    public let port: Int?

    public init(name: String, path: String, rootPath: String, defaultBranch: String?, port: Int?) {
        self.name = name
        self.path = path
        self.rootPath = rootPath
        self.defaultBranch = defaultBranch
        self.port = port
    }

    /// `origin/main` → `main`; a local base ref is already a branch name.
    public static func branchName(fromBaseRef ref: String) -> String {
        ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
    }

    public var variables: [String: String] {
        var values = [
            "ROCKY_WORKSPACE_NAME": name,
            "ROCKY_WORKSPACE_PATH": path,
            "ROCKY_ROOT_PATH": rootPath,
        ]
        if let defaultBranch {
            values["ROCKY_DEFAULT_BRANCH"] = defaultBranch
        }
        if let port {
            for key in ["PORT", "ROCKY_PORT"] { values[key] = String(port) }
        }
        return values
    }
}

public enum WorkspaceEnvironment {
    /// Never inherited from the login shell. A stray CLAUDE_CONFIG_DIR made the Claude adapter
    /// load another Claude instance's hooks (M0 finding); the repo setting decides it instead.
    public static let strippedKeys: Set<String> = ["CLAUDE_CONFIG_DIR", "PWD", "OLDPWD", "SHLVL", "_"]

    /// Layers, later wins (spec Section 3): login shell < workspace variables < repo variables < the GitHub
    /// account's `GH_TOKEN` (`ENV-01`). Without a token, a `GH_TOKEN` of the shell or of a repo variable stays.
    /// CLAUDE_CONFIG_DIR comes only from the repo setting, never from the shell or a repo variable.
    public static func make(
        login: [String: String],
        workspace: WorkspaceContext? = nil,
        githubToken: String? = nil,
        repoVariables: [String: String] = [:],
        claudeConfigDir: String?
    ) -> [String: String] {
        var environment = login.filter { !strippedKeys.contains($0.key) }
        environment.merge(workspace?.variables ?? [:]) { _, new in new }
        environment.merge(repoVariables.filter { $0.key != "CLAUDE_CONFIG_DIR" }) { _, new in new }
        if let githubToken, !githubToken.isEmpty {
            environment["GH_TOKEN"] = githubToken
        }
        if let claudeConfigDir, !claudeConfigDir.isEmpty {
            environment["CLAUDE_CONFIG_DIR"] = claudeConfigDir
        }
        return environment
    }
}

public enum ClaudeInstances {
    /// Claude Code config directories in `home`: `.claude` plus any `.claude-<name>` holding a `settings.json`.
    public static func detect(home: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .map { home.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("settings.json").path) }
            .sorted()
    }
}
