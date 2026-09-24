import Foundation
import Testing
@testable import RockyKit

/// Answers every request of a stubbed session and records it with its body. One suite uses it at a time
/// (`GitHubClientTests` is serialized).
final class StubURLProtocol: URLProtocol {
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    struct Sent: Sendable {
        let request: URLRequest
        let body: Data?

        var authorization: String? { request.value(forHTTPHeaderField: "Authorization") }

        /// The GraphQL request: its query and its variables.
        var graphQL: (query: String, variables: [String: JSONValue])? {
            struct Body: Decodable {
                let query: String
                let variables: [String: JSONValue]
            }
            guard let body, let decoded = try? JSONDecoder().decode(Body.self, from: body) else { return nil }
            return (decoded.query, decoded.variables)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: @Sendable (URLRequest) throws -> Reply = { _ in Reply() }
    nonisolated(unsafe) private static var sent: [Sent] = []

    static func reset(_ handler: @escaping @Sendable (URLRequest) throws -> Reply) {
        lock.withLock {
            self.handler = handler
            sent = []
        }
    }

    static var requests: [Sent] {
        lock.withLock { sent }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let handler = Self.lock.withLock {
            Self.sent.append(Sent(request: request, body: body))
            return Self.handler
        }
        do {
            let reply = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite(.serialized)
struct GitHubClientTests {
    private let repository = GitHubRepository(owner: "jhzl1", name: "rocky")

    private func client() -> GitHubClient {
        GitHubClient(session: StubURLProtocol.session(), token: { "gho_test" })
    }

    private func answer(_ fixture: String) {
        let body = Fixtures.json(fixture)
        StubURLProtocol.reset { _ in .init(body: body) }
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    // MARK: Requests

    @Test func snapshotSendsTheQueryItsVariablesAndTheBearerToken() async throws {
        answer("github-open")
        _ = try await client().snapshot(repository: repository, branch: "rocky/tokyo", base: "development")

        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.request.url == URL(string: "https://api.github.com/graphql"))
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.authorization == "Bearer gho_test")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let graphQL = try #require(sent.graphQL)
        #expect(graphQL.variables == ["owner": "jhzl1", "name": "rocky", "branch": "rocky/tokyo", "base": "development"])
        #expect(graphQL.query.contains("pullRequests(headRefName: $branch, states: [OPEN, MERGED], first: 1"))
        #expect(graphQL.query.contains("ref(qualifiedName: $base) { compare(headRef: $branch) { aheadBy behindBy } }"))
        #expect(graphQL.query.contains("... on CheckRun"))
        #expect(graphQL.query.contains("... on StatusContext { context state targetUrl }"))
        #expect(graphQL.query.contains("deployments(first: 20, orderBy: {field: CREATED_AT, direction: DESC})"))
        // The token is only in the header.
        #expect(!(sent.request.url?.absoluteString.contains("gho_test") ?? true))
        #expect(!graphQL.query.contains("gho_test"))
    }

    /// Open question 9: a workspace without a base compares with the default branch in the same query.
    @Test func withoutABaseTheCompareIsAgainstTheDefaultBranch() async throws {
        let body = Data(#"""
            {"data":{"repository":{"id":"R_1","squashMergeAllowed":true,"rebaseMergeAllowed":true,"mergeCommitAllowed":true,
            "viewerDefaultMergeMethod":null,"defaultBranchRef":{"name":"main","compare":{"aheadBy":5,"behindBy":1}},
            "pullRequests":{"nodes":[]}}}}
            """#.utf8)
        StubURLProtocol.reset { _ in .init(body: body) }
        let snapshot = try await client().snapshot(repository: repository, branch: "rocky/kyoto", base: nil)

        let graphQL = try #require(StubURLProtocol.requests.first?.graphQL)
        #expect(graphQL.variables == ["owner": "jhzl1", "name": "rocky", "branch": "rocky/kyoto"])
        #expect(!graphQL.query.contains("$base"))
        #expect(graphQL.query.contains("defaultBranchRef { name compare(headRef: $branch) { aheadBy behindBy } }"))
        #expect(snapshot.repository.defaultBranchName == "main")
        #expect(snapshot.baseAheadBy == 5)
        #expect(snapshot.baseBehindBy == 1)
        #expect(snapshot.pullRequest == nil)
    }

    // MARK: Parsing

    @Test func parsesAnOpenPullRequestWithEveryCheckKindAndDeployments() async throws {
        answer("github-open")
        let snapshot = try await client().snapshot(repository: repository, branch: "rocky/tokyo", base: "development")

        #expect(snapshot.repository == RepositorySettings(
            id: "R_kgDOrepo", squashMergeAllowed: true, rebaseMergeAllowed: false, mergeCommitAllowed: true,
            viewerDefaultMergeMethod: .squash, defaultBranchName: "development"
        ))
        #expect(snapshot.baseAheadBy == 3)
        #expect(snapshot.baseBehindBy == 2)
        let pr = try #require(snapshot.pullRequest)
        #expect(pr.id == "PR_kwDOpr4525")
        #expect(pr.number == 4525)
        #expect(pr.url == URL(string: "https://github.com/jhzl1/rocky/pull/4525"))
        #expect(pr.title == "Retry OCR uploads")
        #expect(pr.body == "Retries failed uploads with backoff.")
        #expect(!pr.isDraft)
        #expect(!pr.isMerged)
        #expect(pr.baseRefName == "development")
        #expect(pr.headRefName == "rocky/tokyo")
        #expect(pr.headRefOid == "3f2a9c1d0e8b7a6f5e4d3c2b1a09f8e7d6c5b4a3")
        #expect(pr.mergeable == "MERGEABLE")
        #expect(pr.mergeStateStatus == "BLOCKED")
        #expect(pr.reviewDecision == "REVIEW_REQUIRED")
        #expect(pr.reviewRequestCount == 2)
        #expect(pr.canBeRebased)
        #expect(pr.autoMergeEnabled)
        #expect(pr.mergeQueueState == nil)

        #expect(pr.checks.map(\.name) == ["build", "e2e / chromium", "lint", "deploy-docs", "codecov/patch", "Vercel", "ci/circleci: test"])
        #expect(pr.checks.map(\.state) == [.passed, .failed, .running, .pending, .passed, .pending, .failed])
        let failed = pr.checks[1]
        #expect(failed.checkRunId == 7002)
        #expect(failed.workflowRunId == 901)
        #expect(failed.url == URL(string: "https://github.com/jhzl1/rocky/actions/runs/901/job/7002"))
        #expect(failed.startedAt == date("2026-09-23T10:00:00Z"))
        #expect(failed.completedAt == date("2026-09-23T11:04:00Z"))
        #expect(pr.checks[3].url == nil)
        #expect(pr.checks[4].workflowRunId == nil)
        let status = pr.checks[6]
        #expect(status.url == URL(string: "https://circleci.com/gh/jhzl1/rocky/12"))
        #expect(status.checkRunId == nil)
        #expect(status.workflowRunId == nil)

        #expect(pr.deployments == [
            PullRequestDeployment(environment: "Preview", state: "IN_PROGRESS", url: nil),
            PullRequestDeployment(environment: "Production", state: "SUCCESS", url: URL(string: "https://rocky.example.com")),
            PullRequestDeployment(environment: "Preview", state: "SUCCESS", url: URL(string: "https://rocky-git-tokyo-jhzl1.vercel.app")),
            PullRequestDeployment(environment: "Staging", state: "QUEUED", url: nil),
        ])
        #expect(pr.latestDeployments.map(\.environment) == ["Preview", "Production", "Staging"])
        #expect(pr.latestDeployments.first?.state == "IN_PROGRESS")
    }

    @Test func parsesADraftPullRequestWithoutChecks() async throws {
        answer("github-draft")
        let pr = try #require(try await client().snapshot(repository: repository, branch: "rocky/oslo", base: "development").pullRequest)
        #expect(pr.isDraft)
        #expect(!pr.isMerged)
        #expect(pr.body == "")
        #expect(pr.checks.isEmpty)
        #expect(pr.deployments.isEmpty)
        #expect(!pr.canBeRebased)
        #expect(!pr.autoMergeEnabled)
        #expect(pr.reviewDecision == nil)
    }

    @Test func parsesAMergedPullRequest() async throws {
        answer("github-merged")
        let snapshot = try await client().snapshot(repository: repository, branch: "rocky/lisbon", base: "development")
        let pr = try #require(snapshot.pullRequest)
        #expect(pr.isMerged)
        #expect(pr.mergedAt == date("2026-09-22T18:30:00Z"))
        #expect(pr.checks.map(\.state) == [.passed])
        #expect(snapshot.repository.mergeCommitAllowed == false)
        #expect(snapshot.baseBehindBy == 4)
    }

    /// A branch that was never pushed: no pull request, and GitHub's NOT_FOUND on `compare` leaves it nil instead of
    /// failing (checked against GitHub on 2026-09-23).
    @Test func aBranchWithoutPullRequestHasNoneAndNoCompare() async throws {
        answer("github-missing")
        let snapshot = try await client().snapshot(repository: repository, branch: "rocky/kyoto", base: "development")
        #expect(snapshot.pullRequest == nil)
        #expect(snapshot.baseAheadBy == nil)
        #expect(snapshot.baseBehindBy == nil)
        #expect(snapshot.repository.defaultBranchName == "development")
    }

    /// `REV-01` and Open question 8: unresolved current threads with their replies, the conversation, and the
    /// non-empty bodies of changes-requested reviews, in that order.
    @Test func pendingCommentsKeepOnlyWhatWaitsForTheAuthor() async throws {
        answer("github-comments")
        let comments = try await client().pendingComments(repository: repository, number: 4512)

        #expect(comments == [
            PendingComment(
                id: "PRRT_retry", kind: .thread, author: "ana", body: "Use exponential backoff instead of a fixed delay.",
                path: "src/ocr/retry.ts", line: 42,
                replies: [.init(author: "jhzl", body: "Would a jitter help too?"), .init(author: "ana", body: "Yes, add full jitter.")]
            ),
            PendingComment(id: "PRRT_file", kind: .thread, author: "ghost", body: "Mention the retry policy.", path: "README.md", line: nil),
            PendingComment(id: "IC_timeout", kind: .conversation, author: "ana", body: "Please add a test for the timeout path."),
            PendingComment(id: "PRR_split", kind: .review, author: "ana", body: "Split the retry policy out of the OCR client."),
        ])
        let graphQL = try #require(StubURLProtocol.requests.first?.graphQL)
        #expect(graphQL.variables == ["owner": "jhzl1", "name": "rocky", "number": 4512])
        #expect(graphQL.query.contains("reviewThreads(first: 50)"))
        #expect(graphQL.query.contains("comments(last: 50)"))
        #expect(graphQL.query.contains("latestReviews(first: 20) { nodes { id author { login } state body } }"))
    }

    // MARK: Errors

    private func snapshotError(_ reply: @escaping @Sendable (URLRequest) throws -> StubURLProtocol.Reply) async -> Error? {
        StubURLProtocol.reset(reply)
        do {
            _ = try await client().snapshot(repository: repository, branch: "rocky/tokyo", base: "development")
            return nil
        } catch {
            return error
        }
    }

    @Test func noConnectionIsOffline() async {
        let error = await snapshotError { _ in throw URLError(.notConnectedToInternet) }
        #expect(error as? GitHubError == .offline)
    }

    @Test func refusedTokenIsUnauthorized() async {
        let error = await snapshotError { _ in .init(status: 401, body: Data(#"{"message":"Bad credentials"}"#.utf8)) }
        #expect(error as? GitHubError == .unauthorized)
    }

    /// ERR-01: GitHub answers NOT_FOUND for the repository.
    @Test func missingRepositoryIsNotFound() async {
        let body = Data(#"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","path":["repository"],"message":"Could not resolve to a Repository with the name 'jhzl1/rocky'."}]}"#.utf8)
        let error = await snapshotError { _ in .init(body: body) }
        #expect(error as? GitHubError == .notFound)
    }

    @Test func spentRateLimitIsRateLimitedUntilTheReset() async {
        let spent = await snapshotError { _ in
            .init(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1790000000"], body: Data(#"{"message":"API rate limit exceeded"}"#.utf8))
        }
        #expect(spent as? GitHubError == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_790_000_000)))

        let tooMany = await snapshotError { _ in .init(status: 429, headers: ["x-ratelimit-reset": "1790000060"]) }
        #expect(tooMany as? GitHubError == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_790_000_060)))

        let graphQLLimit = Data(#"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded for user."}]}"#.utf8)
        let limited = await snapshotError { _ in .init(headers: ["x-ratelimit-reset": "1790000120"], body: graphQLLimit) }
        #expect(limited as? GitHubError == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_790_000_120)))
    }

    @Test func forbiddenWithoutRateLimitIsAnHTTPError() async {
        let error = await snapshotError { _ in .init(status: 403, headers: ["x-ratelimit-remaining": "4990"]) }
        #expect(error as? GitHubError == .http(403))
    }

    @Test func otherGraphQLErrorsKeepTheirMessages() async {
        let body = Data(#"{"data":{"repository":null},"errors":[{"type":"FORBIDDEN","path":["repository"],"message":"Resource protected by organization SAML enforcement."}]}"#.utf8)
        let error = await snapshotError { _ in .init(body: body) }
        #expect(error as? GitHubError == .graphQL(["Resource protected by organization SAML enforcement."]))
    }

    @Test func serverErrorIsAnHTTPError() async {
        let error = await snapshotError { _ in .init(status: 502) }
        #expect(error as? GitHubError == .http(502))
    }

    // MARK: REST

    /// The log goes to a file, and its redirect to the storage host is requested without the token.
    @Test func jobLogRedirectIsRequestedWithoutAuthorization() async throws {
        let log = Data("step 1\nstep 2\nError: timeout\n".utf8)
        StubURLProtocol.reset { request in
            if request.url?.host == "api.github.com" {
                return .init(status: 302, headers: ["Location": "https://productionresultssa1.blob.core.windows.net/logs/7002.txt?sig=abc"])
            }
            return .init(body: log)
        }
        let file = try await client().jobLog(repository: repository, jobId: 7002)
        defer { try? FileManager.default.removeItem(at: file) }

        let sent = StubURLProtocol.requests
        #expect(sent.count == 2)
        #expect(sent[0].request.url == URL(string: "https://api.github.com/repos/jhzl1/rocky/actions/jobs/7002/logs"))
        #expect(sent[0].authorization == "Bearer gho_test")
        #expect(sent[1].request.url?.host == "productionresultssa1.blob.core.windows.net")
        #expect(sent[1].authorization == nil)
        #expect(try Data(contentsOf: file) == log)
    }

    @Test func rerunPostsToTheWorkflowRun() async throws {
        StubURLProtocol.reset { _ in .init(status: 201) }
        try await client().rerunFailedJobs(repository: repository, runId: 901)

        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.request.url == URL(string: "https://api.github.com/repos/jhzl1/rocky/actions/runs/901/rerun-failed-jobs"))
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.authorization == "Bearer gho_test")
        #expect(sent.request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(sent.request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    /// ACC-01's probe: one GET of the repository; 200 reads, 404, 401 and a plain 403 do not, and a failure that says
    /// nothing about the account throws.
    @Test func canReadAsksForTheRepositoryOnce() async throws {
        StubURLProtocol.reset { _ in .init() }
        #expect(try await client().canRead(repository: repository))
        let sent = try #require(StubURLProtocol.requests.first)
        #expect(StubURLProtocol.requests.count == 1)
        #expect(sent.request.url == URL(string: "https://api.github.com/repos/jhzl1/rocky"))
        #expect(sent.request.httpMethod == "GET")
        #expect(sent.authorization == "Bearer gho_test")

        for status in [404, 401, 403] {
            StubURLProtocol.reset { _ in .init(status: status) }
            #expect(try await client().canRead(repository: repository) == false)
        }

        StubURLProtocol.reset { _ in .init(status: 403, headers: ["x-ratelimit-remaining": "0"]) }
        await #expect(throws: GitHubError.rateLimited(resetAt: nil)) { try await self.client().canRead(repository: self.repository) }
        StubURLProtocol.reset { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: GitHubError.offline) { try await self.client().canRead(repository: self.repository) }
    }

    @Test func annotationsAreTheirMessages() async throws {
        let body = Data(#"[{"path":".github","message":"The job was not started because your account is locked due to a billing issue."}]"#.utf8)
        StubURLProtocol.reset { _ in .init(body: body) }
        let messages = try await client().annotations(repository: repository, checkRunId: 7004)
        #expect(messages == ["The job was not started because your account is locked due to a billing issue."])
        #expect(StubURLProtocol.requests.first?.request.url == URL(string: "https://api.github.com/repos/jhzl1/rocky/check-runs/7004/annotations?per_page=100"))
    }

    // MARK: Mutations

    @Test func eachMutationSendsItsInput() async throws {
        let ok = Data(#"{"data":{"result":{"pullRequest":{"id":"PR_1"}}}}"#.utf8)
        StubURLProtocol.reset { _ in .init(body: ok) }
        let github = client()
        try await github.markReadyForReview(id: "PR_1")
        try await github.merge(id: "PR_1", method: .squash)

        let sent = StubURLProtocol.requests.compactMap(\.graphQL)
        try #require(sent.count == 2)
        #expect(sent[0].query.contains("markPullRequestReadyForReview(input: {pullRequestId: $id})"))
        #expect(sent[0].variables == ["id": "PR_1"])
        #expect(sent[1].query.contains("mergePullRequest(input: {pullRequestId: $id, mergeMethod: $method})"))
        #expect(sent[1].query.contains("$method: PullRequestMergeMethod!"))
        #expect(sent[1].variables == ["id": "PR_1", "method": "SQUASH"])
        #expect(StubURLProtocol.requests.allSatisfy { $0.authorization == "Bearer gho_test" })
    }

    @Test func aRefusedMutationThrowsGitHubsMessage() async {
        let refused = Data(#"{"data":{"mergePullRequest":null},"errors":[{"type":"UNPROCESSABLE","path":["mergePullRequest"],"message":"Pull Request is not mergeable"}]}"#.utf8)
        StubURLProtocol.reset { _ in .init(body: refused) }
        await #expect(throws: GitHubError.graphQL(["Pull Request is not mergeable"])) {
            try await client().merge(id: "PR_1", method: .merge)
        }
    }
}
