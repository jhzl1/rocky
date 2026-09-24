import Foundation

/// A git remote's host and repository path, from `git remote get-url origin`: `https://host/owner/name(.git)`,
/// `ssh://[user@]host[:port]/owner/name(.git)` or scp-like `[user@]host:owner/name(.git)`.
public struct RemoteURL: Equatable, Sendable {
    public let host: String
    public let owner: String
    public let name: String
    /// Reached over SSH, so `host` may be an alias of `~/.ssh/config` (`github-celes`).
    public let isSSH: Bool

    public init(host: String, owner: String, name: String, isSSH: Bool) {
        self.host = host
        self.owner = owner
        self.name = name
        self.isSSH = isSSH
    }

    public static func parse(_ url: String) -> RemoteURL? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if text.contains("://") {
            guard let components = URLComponents(string: text),
                  let scheme = components.scheme?.lowercased(),
                  ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme),
                  let host = components.host, !host.isEmpty, !host.hasPrefix("-") else { return nil }
            return make(host: host, path: components.path, isSSH: scheme.contains("ssh"))
        }
        // scp-like: `[user@]host:path`. A local path has no colon before its first slash.
        guard let match = text.wholeMatch(of: /(?:[^@\/:]+@)?([^@\/:]+):(.+)/) else { return nil }
        // A host starting with "-" would reach `ssh -G` as an option.
        guard !match.1.hasPrefix("-") else { return nil }
        return make(host: String(match.1), path: String(match.2), isSSH: true)
    }

    private static func make(host: String, path: String, isSSH: Bool) -> RemoteURL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else { return nil }
        var name = parts[1]
        if name.hasSuffix(".git") { name.removeLast(".git".count) }
        guard !parts[0].isEmpty, !name.isEmpty else { return nil }
        return RemoteURL(host: host, owner: parts[0], name: name, isSSH: isSSH)
    }
}

/// A repository on github.com (`ACC-01`): the owner decides the default account.
public struct GitHubRepository: Hashable, Sendable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }
}

public enum GitHubRemote {
    public static let host = "github.com"

    /// The GitHub repository a remote points at, or nil when it is not on github.com. An SSH host other than
    /// `github.com` is an alias, accepted when `sshHostName` (backed by `ssh -G <host>`) answers `github.com`. An
    /// https host other than `github.com` is not GitHub (GitHub Enterprise is not supported).
    public static func repository(from remote: RemoteURL, sshHostName: (String) throws -> String?) rethrows -> GitHubRepository? {
        let repository = GitHubRepository(owner: remote.owner, name: remote.name)
        if remote.host.lowercased() == host { return repository }
        guard remote.isSSH, let resolved = try sshHostName(remote.host), resolved.lowercased() == host else { return nil }
        return repository
    }

    /// The `hostname` line of `ssh -G <host>`, which prints the configuration ssh would use for that host.
    public static func hostName(fromSSHConfig output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if fields.count == 2, fields[0].lowercased() == "hostname" {
                return fields[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

extension GitHubRemote {
    /// The GitHub repository of a clone's `origin`: `git remote get-url origin`, then `ssh -G <host>` for an SSH host
    /// other than github.com. nil without an origin or when it is not on GitHub. Blocking: call it off the main actor,
    /// once per repository per launch (`PR-07`).
    public static func repository(ofClone clone: URL, environment: [String: String]) -> GitHubRepository? {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard let url = try? ProcessRunner.run(git, ["remote", "get-url", "origin"], in: clone, environment: environment),
              let remote = RemoteURL.parse(url) else { return nil }
        let ssh = AgentLauncher.resolve("ssh", path: environment["PATH"]) ?? URL(fileURLWithPath: "/usr/bin/ssh")
        return try? repository(from: remote) { host in
            try hostName(fromSSHConfig: ProcessRunner.run(ssh, ["-G", host], environment: environment))
        }
    }
}
