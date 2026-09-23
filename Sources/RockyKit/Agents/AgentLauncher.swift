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
    case adapterNotInstalled
}

public enum AgentLauncher {
    public static let claudeAdapterPackage = "@agentclientprotocol/claude-agent-acp"
    public static let claudeAdapterVersion = "0.81.0"

    public static func claudeAdapterScript(prefix: URL) -> URL {
        prefix.appendingPathComponent("node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js")
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
            guard let opencode = resolve("opencode", path: environment["PATH"]) else {
                throw AgentLauncherError.executableNotFound("opencode")
            }
            return AgentLaunch(executable: opencode, arguments: ["acp"], environment: environment, cwd: cwd, stderrLog: log)
        case .claude:
            guard let node = resolve("node", path: environment["PATH"]) else {
                throw AgentLauncherError.executableNotFound("node")
            }
            let script = claudeAdapterScript(prefix: adapterPrefix)
            guard FileManager.default.fileExists(atPath: script.path) else { throw AgentLauncherError.adapterNotInstalled }
            return AgentLaunch(executable: node, arguments: [script.path], environment: environment, cwd: cwd, stderrLog: log)
        }
    }

    /// Installs the pinned Claude adapter into `prefix` with npm. Blocking; needs network once.
    public static func installClaudeAdapter(prefix: URL, environment: [String: String]) throws {
        guard let npm = resolve("npm", path: environment["PATH"]) else { throw AgentLauncherError.executableNotFound("npm") }
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try ProcessRunner.run(
            npm,
            ["install", "--prefix", prefix.path, "--no-audit", "--no-fund", "\(claudeAdapterPackage)@\(claudeAdapterVersion)"],
            in: prefix,
            environment: environment
        )
    }
}
