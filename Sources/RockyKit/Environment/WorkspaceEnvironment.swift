import Foundation

public enum WorkspaceEnvironment {
    /// Never inherited from the login shell. A stray CLAUDE_CONFIG_DIR made the Claude adapter
    /// load another Claude instance's hooks (M0 finding); the repo setting decides it instead.
    public static let strippedKeys: Set<String> = ["CLAUDE_CONFIG_DIR", "PWD", "OLDPWD", "SHLVL", "_"]

    public static func make(login: [String: String], claudeConfigDir: String?) -> [String: String] {
        var environment = login.filter { !strippedKeys.contains($0.key) }
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
