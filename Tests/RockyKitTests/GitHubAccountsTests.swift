import Foundation
import Testing
@testable import RockyKit

/// A fake `gh`: answers `auth status` and `auth token`, and records every call.
final class FakeGH: @unchecked Sendable {
    static let twoAccounts = """
        {"hosts":{"github.com":[\
        {"state":"success","active":true,"host":"github.com","login":"jhzl1","tokenSource":"keyring","scopes":"repo, workflow","gitProtocol":"ssh"},\
        {"state":"success","active":false,"host":"github.com","login":"ocampos-biai","tokenSource":"keyring","scopes":"repo, workflow","gitProtocol":"ssh"}\
        ]}}
        """

    private let lock = NSLock()
    private var recorded: [(arguments: [String], environment: [String: String])] = []
    private let status: String
    private let tokens: [String: String]
    private let delay: TimeInterval
    private let tokenFailure: ProcessFailure?

    init(status: String = FakeGH.twoAccounts, tokens: [String: String] = [:], delay: TimeInterval = 0, tokenFailure: ProcessFailure? = nil) {
        self.status = status
        self.tokens = tokens
        self.delay = delay
        self.tokenFailure = tokenFailure
    }

    var calls: [[String]] {
        lock.withLock { recorded.map { $0.arguments } }
    }

    var environments: [[String: String]] {
        lock.withLock { recorded.map { $0.environment } }
    }

    func tokenCalls(for login: String) -> Int {
        calls.filter { $0.starts(with: ["auth", "token"]) && $0.contains(login) }.count
    }

    /// The `runGH` of `AppModel`, which gets the environment too.
    func run(_ arguments: [String], environment: [String: String]) throws -> String {
        lock.withLock { recorded.append((arguments: arguments, environment: environment)) }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if arguments.starts(with: ["auth", "status"]) { return status }
        if arguments.starts(with: ["auth", "token"]), let index = arguments.firstIndex(of: "--user") {
            let login = arguments[index + 1]
            if let token = tokens[login] { return token + "\n" }
            if let tokenFailure { throw tokenFailure }
            throw ProcessFailure(command: "gh auth token", status: 1, stderr: "no oauth token found for github.com account \(login)")
        }
        throw ProcessFailure(command: "gh", status: 1, stderr: "unknown command")
    }

    /// The `runGH` of `GitHubAccounts`.
    var runGH: @Sendable ([String]) throws -> String {
        { [self] arguments in try run(arguments, environment: [:]) }
    }
}

@MainActor
struct GitHubAccountsTests {
    @Test func parsesTheAccountsAndTheActiveOne() async throws {
        let accounts = GitHubAccounts(runGH: FakeGH().runGH)
        #expect(try await accounts.logins() == ["jhzl1", "ocampos-biai"])
        #expect(try await accounts.activeLogin() == "jhzl1")
    }

    @Test func noAccountIsAnEmptyList() async throws {
        let accounts = GitHubAccounts(runGH: FakeGH(status: #"{"hosts":{}}"#).runGH)
        #expect(try await accounts.logins().isEmpty)
        #expect(try await accounts.activeLogin() == nil)
    }

    /// The account list is read once per launch unless asked again (the settings sheet).
    @Test func accountListIsReadOncePerLaunch() async throws {
        let gh = FakeGH()
        let accounts = GitHubAccounts(runGH: gh.runGH)
        _ = try await accounts.logins()
        _ = try await accounts.activeLogin()
        #expect(gh.calls.count == 1)
        _ = try await accounts.logins(reload: true)
        #expect(gh.calls.count == 2)
        #expect(gh.calls.allSatisfy { $0 == ["auth", "status", "--json", "hosts", "--hostname", "github.com"] })
    }

    @Test func tokenIsFetchedOncePerLogin() async throws {
        let gh = FakeGH(tokens: ["jhzl1": "gho_one", "ocampos-biai": "gho_two"])
        let accounts = GitHubAccounts(runGH: gh.runGH)
        #expect(accounts.cachedToken(for: "jhzl1") == nil)
        #expect(try await accounts.token(for: "jhzl1") == "gho_one")
        #expect(try await accounts.token(for: "jhzl1") == "gho_one")
        #expect(try await accounts.token(for: "ocampos-biai") == "gho_two")
        #expect(accounts.cachedToken(for: "jhzl1") == "gho_one")
        #expect(gh.tokenCalls(for: "jhzl1") == 1)
        #expect(gh.calls.contains(["auth", "token", "--user", "jhzl1", "--hostname", "github.com"]))
        // Never --show-token, never -t.
        #expect(!gh.calls.joined().contains { $0 == "--show-token" || $0 == "-t" })
    }

    @Test func concurrentCallersShareOneFetch() async throws {
        let gh = FakeGH(tokens: ["jhzl1": "gho_one"], delay: 0.2)
        let accounts = GitHubAccounts(runGH: gh.runGH)
        async let first = accounts.token(for: "jhzl1")
        async let second = accounts.token(for: "jhzl1")
        #expect(try await [first, second] == ["gho_one", "gho_one"])
        #expect(gh.tokenCalls(for: "jhzl1") == 1)
    }

    /// A failure is not kept: Retry after `gh auth login` runs gh again.
    @Test func aFailedFetchIsNotCached() async throws {
        let gh = FakeGH()
        let accounts = GitHubAccounts(runGH: gh.runGH)
        await #expect(throws: GitHubAccountError.notLoggedIn("ana")) { try await accounts.token(for: "ana") }
        await #expect(throws: GitHubAccountError.notLoggedIn("ana")) { try await accounts.token(for: "ana") }
        #expect(gh.tokenCalls(for: "ana") == 2)
        #expect(accounts.cachedToken(for: "ana") == nil)
    }

    @Test func defaultLoginMatchesTheOwnerElseTheActiveAccount() {
        let logins = ["jhzl1", "ocampos-biai"]
        #expect(GitHubAccounts.defaultLogin(owner: "ocampos-biai", logins: logins, active: "jhzl1") == "ocampos-biai")
        #expect(GitHubAccounts.defaultLogin(owner: "OCampos-BIAI", logins: logins, active: "jhzl1") == "ocampos-biai")
        #expect(GitHubAccounts.defaultLogin(owner: "celes-dev", logins: logins, active: "jhzl1") == "jhzl1")
        #expect(GitHubAccounts.defaultLogin(owner: "celes-dev", logins: [], active: nil) == nil)
    }

    /// ACC-01 for an organization's repository (user report, 2026-09-23): no login is the owner, so the first account
    /// that can read it, the active one first; an account without an answer is skipped; nobody can, the active one.
    @Test func defaultLoginOfAnOrganizationIsTheFirstAccountThatCanReadIt() {
        let logins = ["jhzl1", "ocampos-biai"]
        func pick(_ canRead: [String: Bool], owner: String = "celes-app") -> String? {
            GitHubAccounts.defaultLogin(owner: owner, logins: logins, active: "jhzl1", canRead: canRead)
        }
        #expect(pick(["jhzl1": false, "ocampos-biai": true]) == "ocampos-biai")
        #expect(pick(["jhzl1": true, "ocampos-biai": true]) == "jhzl1")
        #expect(pick(["ocampos-biai": true]) == "ocampos-biai")
        #expect(pick(["jhzl1": false, "ocampos-biai": false]) == "jhzl1")
        #expect(pick([:]) == "jhzl1")
        // The owner's login wins whatever the probe said.
        #expect(pick(["jhzl1": true], owner: "ocampos-biai") == "ocampos-biai")
    }

    @Test func readProbeOrderAsksTheActiveAccountFirstAndOnlyWhenItMatters() {
        let logins = ["ocampos-biai", "jhzl1", "ana"]
        #expect(GitHubAccounts.readProbeOrder(owner: "celes-app", logins: logins, active: "jhzl1") == ["jhzl1", "ocampos-biai", "ana"])
        #expect(GitHubAccounts.readProbeOrder(owner: "celes-app", logins: logins, active: nil) == logins)
        #expect(GitHubAccounts.readProbeOrder(owner: "JHZL1", logins: logins, active: "ana").isEmpty)
        #expect(GitHubAccounts.readProbeOrder(owner: "celes-app", logins: ["jhzl1"], active: "jhzl1").isEmpty)
        #expect(GitHubAccounts.readProbeOrder(owner: "celes-app", logins: [], active: nil).isEmpty)
    }

    /// Review Focus 2: gh printed a token and then failed; the error names the status and suggests the login
    /// command, and carries neither that token nor any token fetched earlier.
    @Test func errorsNeverCarryTheToken() async throws {
        let failure = ProcessFailure(
            command: "gh auth token --user ocampos-biai --hostname github.com",
            status: 1,
            stderr: "gho_leakedByABrokenKeyring\nkeyring read gho_fetchedEarlier: permission denied"
        )
        let gh = FakeGH(tokens: ["jhzl1": "gho_fetchedEarlier"], tokenFailure: failure)
        let accounts = GitHubAccounts(runGH: gh.runGH)
        _ = try await accounts.token(for: "jhzl1")

        do {
            _ = try await accounts.token(for: "ocampos-biai")
            Issue.record("the token fetch should have failed")
        } catch {
            let texts = ["\(error)", error.localizedDescription, String(reflecting: error)]
            for text in texts {
                #expect(!text.contains("gho_leakedByABrokenKeyring"))
                #expect(!text.contains("gho_fetchedEarlier"))
            }
            #expect("\(error)".contains("exited 1"))
            #expect("\(error)".contains("gh auth login --hostname github.com"))
        }
    }

    @Test func missingGHSaysHowToInstallAndLogIn() async throws {
        let accounts = GitHubAccounts(runGH: { _ in throw GitHubAccountError.ghNotFound })
        await #expect(throws: GitHubAccountError.ghNotFound) { try await accounts.logins() }
        #expect(GitHubAccountError.ghNotFound.description.contains("gh auth login --hostname github.com"))
    }

    @Test func ghRunsWithoutTheTokenVariablesOfTheShell() {
        let environment = GitHubCLI.environment(from: ["PATH": "/opt/homebrew/bin", "GH_TOKEN": "gho_shell", "GITHUB_TOKEN": "ghp_shell"])
        #expect(environment == ["PATH": "/opt/homebrew/bin"])
    }
}
