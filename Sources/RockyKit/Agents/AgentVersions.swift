import Foundation

/// What Rocky knows about one of its agents' versions: the one installed in its agents folder, the newest one on
/// npm (checked once a day or on demand), and the one this build of Rocky was tested with.
public struct AgentVersion: Sendable, Equatable {
    public var installed: String?
    public var latest: String?
    public let tested: String
    /// For Claude: the Claude Code version the installed adapter bundles.
    public var claudeCode: String?

    public init(installed: String?, latest: String? = nil, tested: String, claudeCode: String? = nil) {
        self.installed = installed
        self.latest = latest
        self.tested = tested
        self.claudeCode = claudeCode
    }

    public var updateAvailable: Bool {
        guard let installed, let latest else { return false }
        return SemanticVersion.isNewer(latest, than: installed)
    }

    /// The installed version is not the tested one, so "use the tested version" can go back to it.
    public var isOffTested: Bool {
        installed.map { $0 != tested } ?? false
    }
}

/// Compares `1.18.32`-style versions by their numbers; a pre-release suffix (`-beta.1`) is ignored.
public enum SemanticVersion {
    static func numbers(_ version: String) -> [Int] {
        let core = version.split(separator: "-").first.map(String.init) ?? version
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    public static func isNewer(_ version: String, than other: String) -> Bool {
        let left = numbers(version)
        let right = numbers(other)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

extension AgentLauncher {
    public static func package(for kind: AgentKind) -> String {
        switch kind {
        case .claude: claudeAdapterPackage
        case .opencode: openCodePackage
        }
    }

    public static func testedVersion(for kind: AgentKind) -> String {
        switch kind {
        case .claude: claudeAdapterVersion
        case .opencode: openCodeVersion
        }
    }

    /// The version in the installed package's package.json; nil when it is not installed.
    public static func installedVersion(_ kind: AgentKind, prefix: URL) -> String? {
        packageField("version", in: prefix.appendingPathComponent("node_modules/\(package(for: kind))/package.json"))
    }

    /// The Claude Code version the installed adapter runs (its SDK's `claudeCodeVersion`).
    public static func bundledClaudeCodeVersion(prefix: URL) -> String? {
        packageField("claudeCodeVersion", in: prefix.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk/package.json"))
    }

    private static func packageField(_ field: String, in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json[field] as? String
    }

    /// The newest published version of `package`, from the npm registry over HTTPS: no process is started.
    public static func latestVersion(of package: String) async throws -> String {
        let name = package.replacingOccurrences(of: "/", with: "%2F")
        guard let url = URL(string: "https://registry.npmjs.org/\(name)/latest") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else { throw URLError(.badServerResponse) }
        return version
    }
}
