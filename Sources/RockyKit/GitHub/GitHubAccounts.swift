import Foundation

public enum GitHubAccountError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case ghNotFound
    /// gh has no token for this login, or no account at all (nil).
    case notLoggedIn(String?)
    /// gh failed: its exit status and the last lines of its stderr, with anything that looks like a token removed.
    case failed(String)

    public static let loginCommand = "gh auth login --hostname github.com"

    public var description: String {
        switch self {
        case .ghNotFound:
            "The GitHub CLI (gh) is not on your PATH. Install it, then run \(Self.loginCommand)."
        case .notLoggedIn(let login?):
            "gh has no token for \(login). Run \(Self.loginCommand)."
        case .notLoggedIn(nil):
            "gh is not logged in to github.com. Run \(Self.loginCommand)."
        case .failed(let detail):
            "\(detail). Run \(Self.loginCommand) if the account is missing."
        }
    }

    public var errorDescription: String? { description }
}

/// One `gh` login on github.com, from `gh auth status --json hosts`.
struct GitHubLogin: Equatable, Sendable {
    let login: String
    let isActive: Bool
}

/// The GitHub accounts `gh` knows (`ACC-01`) and their tokens. Each login's token comes from
/// `gh auth token --user <login>` once per launch, on first need, and stays in memory: it is never stored, logged or
/// put in an error. The account list is read once per launch too, unless the caller asks to read it again.
@MainActor
public final class GitHubAccounts {
    private let runGH: @Sendable ([String]) throws -> String
    private var tokens: [String: String] = [:]
    private var tokenFetches: [String: Task<String, Error>] = [:]
    private var status: [GitHubLogin]?
    private var statusRead: Task<[GitHubLogin], Error>?

    /// `runGH` runs `gh` with these arguments and returns its stdout; it throws `ProcessFailure` when gh exits
    /// non-zero and `GitHubAccountError.ghNotFound` when there is no gh. It is called off the main actor.
    public init(runGH: @escaping @Sendable ([String]) throws -> String) {
        self.runGH = runGH
    }

    /// The logins on github.com, in gh's order.
    public func logins(reload: Bool = false) async throws -> [String] {
        try await readStatus(reload: reload).map(\.login)
    }

    /// gh's active account on github.com.
    public func activeLogin() async throws -> String? {
        try await readStatus(reload: false).first(where: \.isActive)?.login
    }

    /// The login's token. Concurrent callers share one `gh` run; a failure is not kept, so a retry after
    /// `gh auth login` runs gh again.
    public func token(for login: String) async throws -> String {
        if let cached = tokens[login] { return cached }
        let fetch: Task<String, Error>
        if let running = tokenFetches[login] {
            fetch = running
        } else {
            let runGH = self.runGH
            fetch = Task.blocking {
                let output = try runGH(["auth", "token", "--user", login, "--hostname", GitHubRemote.host])
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            tokenFetches[login] = fetch
        }
        do {
            let token = try await fetch.value
            tokenFetches[login] = nil
            guard !token.isEmpty else { throw GitHubAccountError.notLoggedIn(login) }
            tokens[login] = token
            return token
        } catch {
            tokenFetches[login] = nil
            throw accountError(error, login: login)
        }
    }

    /// The token fetched earlier in this launch, if any; never runs gh.
    public func cachedToken(for login: String) -> String? {
        tokens[login]
    }

    /// `ACC-01`: the login equal to the remote's owner (case-insensitive); else the first login of
    /// `readProbeOrder(owner:logins:active:)` that `canRead` says can read the repository; else gh's active account.
    /// `canRead` holds the probe's answers (`GitHubClient.canRead(repository:)`); a login missing from it has no
    /// answer (offline, rate limited) and is skipped. An organization's repository matches no login, and the active
    /// account may not see it (user report, 2026-09-23: celes-app's repository, 404 for the active jhzl1).
    public nonisolated static func defaultLogin(
        owner: String,
        logins: [String],
        active: String?,
        canRead: [String: Bool] = [:]
    ) -> String? {
        if let match = ownerLogin(owner: owner, logins: logins) { return match }
        return readProbeOrder(owner: owner, logins: logins, active: active).first { canRead[$0] == true } ?? active
    }

    /// The logins to ask, in order, whether they can read a repository of `owner`: the active one first, then gh's
    /// order. Empty when a login is the owner, or with fewer than two logins, where no answer changes the default.
    public nonisolated static func readProbeOrder(owner: String, logins: [String], active: String?) -> [String] {
        guard ownerLogin(owner: owner, logins: logins) == nil, logins.count > 1 else { return [] }
        let first = logins.filter { $0 == active }
        return first + logins.filter { $0 != active }
    }

    private nonisolated static func ownerLogin(owner: String, logins: [String]) -> String? {
        logins.first { $0.caseInsensitiveCompare(owner) == .orderedSame }
    }

    /// Parses `gh auth status --json hosts`: `{"hosts": {"github.com": [{"login": …, "active": …}, …]}}`. That
    /// output never holds a token (only `--show-token` adds one, and Rocky never passes it).
    nonisolated static func parseStatus(_ output: String) throws -> [GitHubLogin] {
        struct Status: Decodable {
            struct Account: Decodable {
                let login: String
                let active: Bool?
            }
            let hosts: [String: [Account]]
        }
        let status = try JSONDecoder().decode(Status.self, from: Data(output.utf8))
        return (status.hosts[GitHubRemote.host] ?? []).map { GitHubLogin(login: $0.login, isActive: $0.active ?? false) }
    }

    private func readStatus(reload: Bool) async throws -> [GitHubLogin] {
        if !reload, let status { return status }
        let read: Task<[GitHubLogin], Error>
        if let running = statusRead {
            read = running
        } else {
            let runGH = self.runGH
            read = Task.blocking {
                try GitHubAccounts.parseStatus(try runGH(["auth", "status", "--json", "hosts", "--hostname", GitHubRemote.host]))
            }
            statusRead = read
        }
        do {
            let logins = try await read.value
            statusRead = nil
            status = logins
            return logins
        } catch {
            statusRead = nil
            throw accountError(error, login: nil)
        }
    }

    /// Maps what `runGH` threw to a `GitHubAccountError` whose text holds no token: only gh's exit status and the
    /// last lines of its stderr, with token-like words and every token of this launch removed.
    private func accountError(_ error: Error, login: String?) -> GitHubAccountError {
        if let error = error as? GitHubAccountError { return error }
        guard let failure = error as? ProcessFailure else {
            if error is DecodingError { return .failed("gh auth status printed something Rocky could not read") }
            return .failed(redacted("gh could not run: \(error.localizedDescription)"))
        }
        if failure.stderr.localizedCaseInsensitiveContains("no oauth token")
            || failure.stderr.localizedCaseInsensitiveContains("not logged in") {
            return .notLoggedIn(login)
        }
        let tail = failure.stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .joined(separator: " ")
        let detail = tail.isEmpty ? "gh exited \(failure.status)" : "gh exited \(failure.status): \(tail)"
        return .failed(redacted(detail))
    }

    /// Replaces every word shaped like a GitHub token with "[token]". `GitBranchError` uses it on git's stderr too.
    nonisolated static func withoutTokenShapes(_ text: String) -> String {
        text.replacing(/gh[opsur]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+/, with: "[token]")
    }

    private func redacted(_ text: String) -> String {
        var text = Self.withoutTokenShapes(text)
        for token in tokens.values where !token.isEmpty {
            text = text.replacingOccurrences(of: token, with: "[token]")
        }
        return text
    }
}

/// Rocky's own `gh` runs: the account list and the tokens, never a refresh (`PR-07`).
public enum GitHubCLI {
    /// The login shell's environment without `GH_TOKEN` and `GITHUB_TOKEN`: with either set, gh reports that
    /// variable's account instead of the keyring's.
    public static func environment(from login: [String: String]) -> [String: String] {
        login.filter { $0.key != "GH_TOKEN" && $0.key != "GITHUB_TOKEN" }
    }

    /// Runs `gh` from the environment's PATH. Blocking: call it off the main actor.
    public static func run(_ arguments: [String], environment: [String: String]) throws -> String {
        guard let gh = AgentLauncher.resolve("gh", path: environment["PATH"]) else { throw GitHubAccountError.ghNotFound }
        return try ProcessRunner.run(gh, arguments, environment: environment)
    }
}
