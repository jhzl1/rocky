import Foundation

public enum GitHubError: Error, Equatable, Sendable {
    /// No connection to api.github.com.
    case offline
    /// 401: the token was refused.
    case unauthorized
    /// GraphQL NOT_FOUND for the repository or the pull request, or a REST 404.
    case notFound
    case rateLimited(resetAt: Date?)
    case graphQL([String])
    case http(Int)
}

/// Rocky's GitHub reads and writes over `URLSession` (`PR-07`: never a `gh` process per refresh). GraphQL goes to
/// `https://api.github.com/graphql`, REST to `https://api.github.com`. The token goes only in the `Authorization`
/// header and only to api.github.com: a job log's redirect to its storage host is requested without it.
public actor GitHubClient {
    public static let apiHost = "api.github.com"
    static let graphQLURL = URL(string: "https://api.github.com/graphql")!
    static let restAPIVersion = "2022-11-28"

    private let session: URLSession
    private let token: @Sendable () async throws -> String

    public init(session: URLSession, token: @escaping @Sendable () async throws -> String) {
        self.session = session
        self.token = token
    }

    /// Rocky's one GitHub session: ephemeral, so no response, cookie or credential reaches the disk.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    // MARK: GraphQL

    /// `PR-01`: the repository, the branch's newest open or merged pull request, and the compare with the base.
    /// Without a base (a workspace made before M2), the compare is against the repository's default branch.
    public func snapshot(repository: GitHubRepository, branch: String, base: String?) async throws -> PullRequestSnapshot {
        let variables = SnapshotVariables(owner: repository.owner, name: repository.name, branch: branch, base: base)
        let query = base == nil ? Self.snapshotQueryWithoutBase : Self.snapshotQuery
        let data: Wire.SnapshotData = try await graphQL(query, variables: variables)
        return try Wire.snapshot(from: data)
    }

    /// `REV-01`'s second query, asked only while the Comments section is visible.
    public func pendingComments(repository: GitHubRepository, number: Int) async throws -> [PendingComment] {
        let variables = CommentsVariables(owner: repository.owner, name: repository.name, number: number)
        let data: Wire.CommentsData = try await graphQL(Self.commentsQuery, variables: variables)
        return try Wire.pendingComments(from: data)
    }

    /// `PR-08`.
    public func markReadyForReview(id: String) async throws {
        let _: JSONValue = try await graphQL(Self.markReadyForReviewMutation, variables: IdVariables(id: id))
    }

    /// `PR-05`.
    public func merge(id: String, method: MergeMethod) async throws {
        let _: JSONValue = try await graphQL(Self.mergeMutation, variables: MergeVariables(id: id, method: method))
    }

    // MARK: REST

    /// `ACC-01`'s probe: whether this client's token can read the repository, from one `GET /repos/{owner}/{name}`
    /// whose body is not read. 404 (GitHub's answer to a private repository the account cannot see), 401 and a 403
    /// that is not the rate limit (an organization's SSO, for example) are false; being offline, rate limited or any
    /// other failure throws, since it says nothing about the account.
    public func canRead(repository: GitHubRepository) async throws -> Bool {
        let request = try await apiRequest(path: "/repos/\(repository.owner)/\(repository.name)")
        let (_, response) = try await send { try await self.session.data(for: request) }
        do {
            try Self.check(response)
            return true
        } catch GitHubError.notFound, GitHubError.unauthorized, GitHubError.http(403) {
            return false
        }
    }

    /// `CHK-02`: re-runs the failed jobs of one workflow run.
    public func rerunFailedJobs(repository: GitHubRepository, runId: Int) async throws {
        var request = try await apiRequest(path: "/repos/\(repository.owner)/\(repository.name)/actions/runs/\(runId)/rerun-failed-jobs")
        request.httpMethod = "POST"
        let (_, response) = try await send { try await self.session.data(for: request) }
        try Self.check(response)
    }

    /// `AGT-03`: downloads a job's log to a temporary file, never into memory. GitHub answers with a redirect to
    /// the log's storage; it is requested again without the token.
    public func jobLog(repository: GitHubRepository, jobId: Int) async throws -> URL {
        let request = try await apiRequest(path: "/repos/\(repository.owner)/\(repository.name)/actions/jobs/\(jobId)/logs")
        let (first, firstResponse) = try await send { try await self.session.download(for: request, delegate: NoRedirects()) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocky-job-\(jobId)-\(UUID().uuidString).log")
        guard let http = firstResponse as? HTTPURLResponse, (300..<400).contains(http.statusCode) else {
            do {
                try Self.check(firstResponse)
                try FileManager.default.moveItem(at: first, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: first)
                throw error
            }
            return destination
        }
        try? FileManager.default.removeItem(at: first)
        guard let location = http.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: request.url)?.absoluteURL else { throw GitHubError.http(http.statusCode) }
        // A plain request: no Authorization, whatever the host.
        var logRequest = URLRequest(url: target)
        logRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let (log, logResponse) = try await send { try await self.session.download(for: logRequest, delegate: NoRedirects()) }
        do {
            try Self.check(logResponse)
            try FileManager.default.moveItem(at: log, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: log)
            throw error
        }
        return destination
    }

    /// `AGT-03`: the annotations of a check run, for a job that never started and so has no log.
    public func annotations(repository: GitHubRepository, checkRunId: Int) async throws -> [String] {
        let request = try await apiRequest(
            path: "/repos/\(repository.owner)/\(repository.name)/check-runs/\(checkRunId)/annotations",
            query: [URLQueryItem(name: "per_page", value: "100")]
        )
        let (data, response) = try await send { try await self.session.data(for: request) }
        try Self.check(response)
        struct Annotation: Decodable { let message: String? }
        return try JSONDecoder().decode([Annotation].self, from: data).compactMap(\.message)
    }

    // MARK: Requests

    private func graphQL<Variables: Encodable, Payload: Decodable>(_ query: String, variables: Variables) async throws -> Payload {
        var request = URLRequest(url: Self.graphQLURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        try await authorize(&request)
        let (data, response) = try await send { try await self.session.data(for: request) }
        try Self.check(response)
        let decoded: Wire.Response<Payload>
        do {
            decoded = try Wire.decoder.decode(Wire.Response<Payload>.self, from: data)
        } catch {
            throw GitHubError.graphQL(["GitHub answered with data Rocky could not read."])
        }
        try Wire.check(decoded.errors, resetAt: Self.resetDate(response))
        guard let payload = decoded.data else { throw GitHubError.graphQL(["GitHub answered without data."]) }
        return payload
    }

    private func apiRequest(path: String, query: [URLQueryItem] = []) async throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.apiHost
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.restAPIVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        try await authorize(&request)
        return request
    }

    /// Puts the token in the `Authorization` header, and only for api.github.com over https.
    private func authorize(_ request: inout URLRequest) async throws {
        guard request.url?.scheme == "https", request.url?.host == Self.apiHost else { return }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Rocky", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
    }

    /// Runs a request, mapping a lost connection to `offline`.
    private func send<Value: Sendable>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            throw GitHubError.offline
        }
    }

    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .timedOut, .internationalRoamingOff, .dataNotAllowed,
    ]

    /// 401 is `unauthorized`; 429, or 403 with the rate limit spent, is `rateLimited`; 404 is `notFound`.
    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw GitHubError.unauthorized
        case 403, 429:
            let spent = http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
                || http.value(forHTTPHeaderField: "retry-after") != nil
            if http.statusCode == 429 || spent { throw GitHubError.rateLimited(resetAt: resetDate(http)) }
            throw GitHubError.http(http.statusCode)
        case 404:
            throw GitHubError.notFound
        default:
            throw GitHubError.http(http.statusCode)
        }
    }

    /// `x-ratelimit-reset` (epoch seconds), else now plus `retry-after` (seconds).
    static func resetDate(_ response: URLResponse) -> Date? {
        guard let http = response as? HTTPURLResponse else { return nil }
        if let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap({ TimeInterval($0) }) {
            return Date(timeIntervalSince1970: reset)
        }
        if let wait = http.value(forHTTPHeaderField: "retry-after").flatMap({ TimeInterval($0) }) {
            return Date().addingTimeInterval(wait)
        }
        return nil
    }
}

/// Stops URLSession from following a redirect, so Rocky follows it itself without the token.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

// MARK: Queries

extension GitHubClient {
    /// `PR-01`, with every field checked against GitHub's schema on 2026-09-23. Deployments are the last commit's:
    /// `PullRequest` has no `deployments` field.
    static let snapshotQuery = """
        query($owner: String!, $name: String!, $branch: String!, $base: String!) {
          repository(owner: $owner, name: $name) {
            \(repositoryFields)
            defaultBranchRef { name }
            ref(qualifiedName: $base) { compare(headRef: $branch) { aheadBy behindBy } }
          }
        }
        """

    static let snapshotQueryWithoutBase = """
        query($owner: String!, $name: String!, $branch: String!) {
          repository(owner: $owner, name: $name) {
            \(repositoryFields)
            defaultBranchRef { name compare(headRef: $branch) { aheadBy behindBy } }
          }
        }
        """

    private static let repositoryFields = """
        id squashMergeAllowed rebaseMergeAllowed mergeCommitAllowed viewerDefaultMergeMethod
            pullRequests(headRefName: $branch, states: [OPEN, MERGED], first: 1, orderBy: {field: CREATED_AT, direction: DESC}) {
              nodes {
                id number url title body isDraft state mergedAt baseRefName headRefName headRefOid
                mergeable mergeStateStatus reviewDecision canBeRebased
                reviewRequests(first: 10) { totalCount }
                autoMergeRequest { enabledAt }
                mergeQueueEntry { state }
                commits(last: 1) {
                  nodes {
                    commit {
                      statusCheckRollup {
                        contexts(first: 100) {
                          nodes {
                            __typename
                            ... on CheckRun {
                              name status conclusion startedAt completedAt detailsUrl databaseId
                              checkSuite { workflowRun { databaseId } }
                            }
                            ... on StatusContext { context state targetUrl }
                          }
                        }
                      }
                      deployments(first: 20, orderBy: {field: CREATED_AT, direction: DESC}) {
                        nodes { environment state latestStatus { state environmentUrl } }
                      }
                    }
                  }
                }
              }
            }
        """

    /// `REV-01`.
    static let commentsQuery = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: 50) {
                nodes {
                  id isResolved isOutdated path line
                  comments(first: 20) { nodes { author { login } body } }
                }
              }
              comments(last: 50) { nodes { id author { login } body } }
              latestReviews(first: 20) { nodes { id author { login } state body } }
            }
          }
        }
        """

    static let markReadyForReviewMutation = """
        mutation($id: ID!) {
          markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { id } }
        }
        """

    static let mergeMutation = """
        mutation($id: ID!, $method: PullRequestMergeMethod!) {
          mergePullRequest(input: {pullRequestId: $id, mergeMethod: $method}) { pullRequest { id } }
        }
        """
}

struct GraphQLRequest<Variables: Encodable>: Encodable {
    let query: String
    let variables: Variables
}

struct SnapshotVariables: Encodable {
    let owner: String
    let name: String
    let branch: String
    /// Left out of the JSON when nil, with the query that does not declare it.
    let base: String?
}

struct CommentsVariables: Encodable {
    let owner: String
    let name: String
    let number: Int
}

struct IdVariables: Encodable {
    let id: String
}

struct MergeVariables: Encodable {
    let id: String
    let method: MergeMethod
}

// MARK: Responses

/// GitHub's JSON as it comes, turned into Rocky's types by `snapshot(from:)` and `pendingComments(from:)`.
enum Wire {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    struct Response<Payload: Decodable>: Decodable {
        let data: Payload?
        let errors: [ErrorEntry]?
    }

    struct ErrorEntry: Decodable {
        let type: String?
        let message: String
        /// Field names and list indexes.
        let path: [JSONValue]?

        var pathNames: [String] {
            (path ?? []).compactMap(\.stringValue)
        }
    }

    /// NOT_FOUND for the repository or the pull request is `notFound`; RATE_LIMITED is `rateLimited`. A NOT_FOUND
    /// on `compare` only means the branch is not on GitHub yet (checked on 2026-09-23: "Could not resolve head ref"),
    /// and leaves the compare nil. Any other error fails the request.
    static func check(_ errors: [ErrorEntry]?, resetAt: Date?) throws {
        let failures = (errors ?? []).filter { !($0.type == "NOT_FOUND" && $0.pathNames.last == "compare") }
        guard !failures.isEmpty else { return }
        if failures.contains(where: { $0.type == "RATE_LIMITED" }) { throw GitHubError.rateLimited(resetAt: resetAt) }
        let missing = failures.contains { failure in
            let names = failure.pathNames
            return failure.type == "NOT_FOUND" && names.first == "repository" && (names.count == 1 || names == ["repository", "pullRequest"])
        }
        if missing { throw GitHubError.notFound }
        throw GitHubError.graphQL(failures.map(\.message))
    }

    struct Nodes<Node: Decodable>: Decodable {
        let nodes: [Node?]?

        var items: [Node] { (nodes ?? []).compactMap { $0 } }
    }

    struct Author: Decodable {
        let login: String
    }

    struct SnapshotData: Decodable {
        let repository: Repository?
    }

    struct Repository: Decodable {
        let id: String
        let squashMergeAllowed: Bool
        let rebaseMergeAllowed: Bool
        let mergeCommitAllowed: Bool
        let viewerDefaultMergeMethod: String?
        let defaultBranchRef: Ref?
        let pullRequests: Nodes<PullRequest>
        let ref: Ref?
    }

    struct Ref: Decodable {
        let name: String?
        let compare: Compare?
    }

    struct Compare: Decodable {
        let aheadBy: Int
        let behindBy: Int
    }

    struct PullRequest: Decodable {
        let id: String
        let number: Int
        let url: URL
        let title: String
        let body: String
        let isDraft: Bool
        let state: String
        let mergedAt: Date?
        let baseRefName: String
        let headRefName: String
        let headRefOid: String
        let mergeable: String?
        let mergeStateStatus: String?
        let reviewDecision: String?
        let canBeRebased: Bool
        let reviewRequests: Count?
        let autoMergeRequest: AutoMerge?
        let mergeQueueEntry: QueueEntry?
        let commits: Nodes<CommitNode>
    }

    struct Count: Decodable {
        let totalCount: Int
    }

    struct AutoMerge: Decodable {
        let enabledAt: Date?
    }

    struct QueueEntry: Decodable {
        let state: String?
    }

    struct CommitNode: Decodable {
        let commit: Commit
    }

    struct Commit: Decodable {
        let statusCheckRollup: Rollup?
        let deployments: Nodes<Deployment>?
    }

    struct Rollup: Decodable {
        let contexts: Nodes<Context>
    }

    /// A `CheckRun` or a `StatusContext`, told apart by `__typename`.
    struct Context: Decodable {
        let typename: String
        let name: String?
        let status: String?
        let conclusion: String?
        let startedAt: Date?
        let completedAt: Date?
        let detailsUrl: String?
        let databaseId: Int?
        let checkSuite: CheckSuite?
        let context: String?
        let state: String?
        let targetUrl: String?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case name, status, conclusion, startedAt, completedAt, detailsUrl, databaseId, checkSuite, context, state, targetUrl
        }
    }

    struct CheckSuite: Decodable {
        let workflowRun: WorkflowRun?
    }

    struct WorkflowRun: Decodable {
        let databaseId: Int?
    }

    struct Deployment: Decodable {
        let environment: String?
        let state: String?
        let latestStatus: DeploymentStatus?
    }

    struct DeploymentStatus: Decodable {
        let state: String?
        let environmentUrl: String?
    }

    struct CommentsData: Decodable {
        let repository: CommentsRepository?
    }

    struct CommentsRepository: Decodable {
        let pullRequest: CommentsPullRequest?
    }

    struct CommentsPullRequest: Decodable {
        let reviewThreads: Nodes<ReviewThread>
        let comments: Nodes<IssueComment>
        let latestReviews: Nodes<Review>
    }

    struct ReviewThread: Decodable {
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
        let path: String?
        let line: Int?
        let comments: Nodes<ThreadComment>
    }

    struct ThreadComment: Decodable {
        let author: Author?
        let body: String
    }

    struct IssueComment: Decodable {
        let id: String
        let author: Author?
        let body: String
    }

    struct Review: Decodable {
        let id: String
        let author: Author?
        let state: String
        let body: String?
    }

    /// A deleted account's comments have no author; GitHub shows them as "ghost".
    static func login(_ author: Author?) -> String {
        author?.login ?? "ghost"
    }

    static func snapshot(from data: SnapshotData) throws -> PullRequestSnapshot {
        guard let repository = data.repository else { throw GitHubError.notFound }
        let settings = RepositorySettings(
            id: repository.id,
            squashMergeAllowed: repository.squashMergeAllowed,
            rebaseMergeAllowed: repository.rebaseMergeAllowed,
            mergeCommitAllowed: repository.mergeCommitAllowed,
            viewerDefaultMergeMethod: repository.viewerDefaultMergeMethod.flatMap(MergeMethod.init(rawValue:)),
            defaultBranchName: repository.defaultBranchRef?.name
        )
        let compare = repository.ref?.compare ?? repository.defaultBranchRef?.compare
        return PullRequestSnapshot(
            repository: settings,
            pullRequest: repository.pullRequests.items.first.map(pullRequest(from:)),
            baseAheadBy: compare?.aheadBy,
            baseBehindBy: compare?.behindBy
        )
    }

    static func pullRequest(from node: PullRequest) -> PullRequestInfo {
        let commit = node.commits.items.last?.commit
        let checks = (commit?.statusCheckRollup?.contexts.items ?? []).compactMap(check(from:))
        let deployments = (commit?.deployments?.items ?? []).map { deployment in
            PullRequestDeployment(
                environment: deployment.environment ?? "",
                state: deployment.latestStatus?.state ?? deployment.state ?? "",
                url: deployment.latestStatus?.environmentUrl.flatMap { URL(string: $0) }
            )
        }
        return PullRequestInfo(
            id: node.id,
            number: node.number,
            url: node.url,
            title: node.title,
            body: node.body,
            isDraft: node.isDraft,
            isMerged: node.state == "MERGED",
            mergedAt: node.mergedAt,
            baseRefName: node.baseRefName,
            headRefName: node.headRefName,
            headRefOid: node.headRefOid,
            mergeable: node.mergeable,
            mergeStateStatus: node.mergeStateStatus,
            reviewDecision: node.reviewDecision,
            reviewRequestCount: node.reviewRequests?.totalCount ?? 0,
            canBeRebased: node.canBeRebased,
            autoMergeEnabled: node.autoMergeRequest != nil,
            mergeQueueState: node.mergeQueueEntry?.state,
            checks: checks,
            deployments: deployments
        )
    }

    static func check(from context: Context) -> PullRequestCheck? {
        switch context.typename {
        case "CheckRun":
            return PullRequestCheck(
                name: context.name ?? "",
                state: .checkRun(status: context.status, conclusion: context.conclusion),
                startedAt: context.startedAt,
                completedAt: context.completedAt,
                url: context.detailsUrl.flatMap { URL(string: $0) },
                checkRunId: context.databaseId,
                workflowRunId: context.checkSuite?.workflowRun?.databaseId
            )
        case "StatusContext":
            return PullRequestCheck(
                name: context.context ?? "",
                state: .statusContext(state: context.state),
                url: context.targetUrl.flatMap { URL(string: $0) }
            )
        default:
            return nil
        }
    }

    /// `REV-01`'s pending comments in `AGT-05`'s order: threads, then the conversation, then review bodies.
    static func pendingComments(from data: CommentsData) throws -> [PendingComment] {
        guard let pullRequest = data.repository?.pullRequest else { throw GitHubError.notFound }
        let threads = pullRequest.reviewThreads.items
            .filter { !$0.isResolved && !$0.isOutdated }
            .compactMap { thread -> PendingComment? in
                let comments = thread.comments.items
                guard let first = comments.first else { return nil }
                return PendingComment(
                    id: thread.id,
                    kind: .thread,
                    author: login(first.author),
                    body: first.body,
                    path: thread.path,
                    line: thread.line,
                    replies: comments.dropFirst().map { PendingComment.Reply(author: login($0.author), body: $0.body) }
                )
            }
        let conversation = pullRequest.comments.items.map {
            PendingComment(id: $0.id, kind: .conversation, author: login($0.author), body: $0.body)
        }
        let reviews = pullRequest.latestReviews.items
            .filter { $0.state == "CHANGES_REQUESTED" && !($0.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { PendingComment(id: $0.id, kind: .review, author: login($0.author), body: $0.body ?? "") }
        return threads + conversation + reviews
    }
}
