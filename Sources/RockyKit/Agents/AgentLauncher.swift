import Foundation

public enum AgentKind: String, CaseIterable, Sendable, Codable, Identifiable {
    case claude
    case opencode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        }
    }
}

public struct AgentLaunch: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let cwd: URL
    public let stderrLog: URL

    public init(executable: URL, arguments: [String], environment: [String: String], cwd: URL, stderrLog: URL) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.stderrLog = stderrLog
    }
}

public enum AgentLauncherError: Error, Equatable {
    case executableNotFound(String)
    /// Rocky's copy of the agent is not installed yet: the Claude adapter or OpenCode.
    case adapterNotInstalled(AgentKind)
}

public enum AgentLauncher {
    public static let claudeAdapterPackage = "@agentclientprotocol/claude-agent-acp"
    public static let claudeAdapterVersion = "0.81.0"

    /// Rocky runs its own OpenCode, installed next to the Claude adapter, not the one on the PATH (user decision,
    /// 2026-09-23). The shared data folder `~/.local/share/opencode` was migrated by Conductor's unreleased
    /// OpenCode 2.0.5, and published versions fail on it ("no such column: project_id").
    public static let openCodePackage = "opencode-ai"
    public static let openCodeVersion = "1.18.32"

    public static func claudeAdapterScript(prefix: URL) -> URL {
        prefix.appendingPathComponent("node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js")
    }

    /// The Claude Code executable the adapter runs: its Agent SDK's native package for this Mac's architecture, which
    /// npm hoists next to the adapter. CMD-08's embedded terminal runs it directly.
    public static func claudeCodeBinary(prefix: URL) -> URL {
        prefix.appendingPathComponent("node_modules/\(claudeCodePackage)/claude")
    }

    /// Where Node would find it from the adapter: in the adapter's own node_modules when npm did not hoist it, else
    /// next to the adapter. nil while neither is there.
    public static func installedClaudeCodeBinary(prefix: URL) -> URL? {
        let nested = prefix.appendingPathComponent("node_modules/\(claudeAdapterPackage)/node_modules/\(claudeCodePackage)/claude")
        return [nested, claudeCodeBinary(prefix: prefix)].first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var claudeCodePackage: String {
        #if arch(arm64)
        "@anthropic-ai/claude-agent-sdk-darwin-arm64"
        #else
        "@anthropic-ai/claude-agent-sdk-darwin-x64"
        #endif
    }

    /// The native binary the package's install script puts in place for this Mac's architecture.
    public static func openCodeBinary(prefix: URL) -> URL {
        prefix.appendingPathComponent("node_modules/opencode-ai/bin/opencode.exe")
    }

    /// Rocky's own OpenCode data (its database, sessions and login), given to OpenCode as `XDG_DATA_HOME`, next to
    /// the agents folder: `~/Library/Application Support/Rocky/opencode-data`.
    public static func openCodeDataHome(prefix: URL) -> URL {
        prefix.deletingLastPathComponent().appendingPathComponent("opencode-data")
    }

    /// Copies your OpenCode login (`auth.json`, your providers' keys) into Rocky's OpenCode data once, the first
    /// time Rocky's copy has none (user decision, 2026-09-23). It stays on this Mac.
    static func copyOpenCodeLogin(into dataHome: URL, environment: [String: String]) {
        let sharedData = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        let source = sharedData.appendingPathComponent("opencode/auth.json")
        let destination = dataHome.appendingPathComponent("opencode/auth.json")
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path), files.fileExists(atPath: source.path) else { return }
        do {
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: source, to: destination)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            // Without it OpenCode still starts, with its free models; the user can log in from a terminal.
        }
    }

    /// First executable named `name` in a PATH string.
    public static func resolve(_ name: String, path: String?) -> URL? {
        for directory in (path ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Resolves how to start `kind`. The Claude adapter runs from `adapterPrefix` with `node`
    /// instead of `npx`, so starting a session never hits the npm registry.
    public static func launch(
        _ kind: AgentKind,
        cwd: URL,
        environment: [String: String],
        adapterPrefix: URL,
        logsDirectory: URL
    ) throws -> AgentLaunch {
        let log = logsDirectory.appendingPathComponent("\(kind.rawValue)-\(UUID().uuidString.prefix(8)).log")
        switch kind {
        case .opencode:
            let binary = openCodeBinary(prefix: adapterPrefix)
            guard FileManager.default.isExecutableFile(atPath: binary.path), !isOlderThanTested(.opencode, prefix: adapterPrefix) else {
                throw AgentLauncherError.adapterNotInstalled(.opencode)
            }
            let dataHome = openCodeDataHome(prefix: adapterPrefix)
            copyOpenCodeLogin(into: dataHome, environment: environment)
            var environment = environment
            // Tools the agent runs see it too; OpenCode has no setting of its own for its data folder.
            environment["XDG_DATA_HOME"] = dataHome.path
            return AgentLaunch(executable: binary, arguments: ["acp"], environment: environment, cwd: cwd, stderrLog: log)
        case .claude:
            guard let node = resolve("node", path: environment["PATH"]) else {
                throw AgentLauncherError.executableNotFound("node")
            }
            let script = claudeAdapterScript(prefix: adapterPrefix)
            guard FileManager.default.fileExists(atPath: script.path), !isOlderThanTested(.claude, prefix: adapterPrefix) else {
                throw AgentLauncherError.adapterNotInstalled(.claude)
            }
            return AgentLaunch(executable: node, arguments: [script.path], environment: environment, cwd: cwd, stderrLog: log)
        }
    }

    /// Installs the pinned Claude adapter into `prefix` with npm. Blocking; needs network once.
    /// An installed copy older than the version this build was tested with is installed again at that version, so
    /// raising `claudeAdapterVersion` or `openCodeVersion` reaches Macs that already have an older one. A newer
    /// copy (updated from the settings) is kept.
    static func isOlderThanTested(_ kind: AgentKind, prefix: URL) -> Bool {
        guard let installed = installedVersion(kind, prefix: prefix) else { return false }
        return SemanticVersion.isNewer(testedVersion(for: kind), than: installed)
    }

    /// Installs Rocky's copy of an agent into `prefix` with npm: the Claude adapter, or OpenCode, at `version`
    /// (the tested one unless the settings ask for another).
    public static func install(_ kind: AgentKind, version: String? = nil, prefix: URL, environment: [String: String]) throws {
        guard let npm = resolve("npm", path: environment["PATH"]) else { throw AgentLauncherError.executableNotFound("npm") }
        let package = "\(Self.package(for: kind))@\(version ?? testedVersion(for: kind))"
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try ProcessRunner.run(
            npm,
            ["install", "--prefix", prefix.path, "--no-audit", "--no-fund", package],
            in: prefix,
            environment: environment
        )
    }
}
