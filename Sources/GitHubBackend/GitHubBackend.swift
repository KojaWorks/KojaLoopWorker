import Foundation
import LoopWorkerCore
import TOMLDecoder
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GitHubBackend {
    /// Builds the GitHub forge from `[forge.github]`:
    ///
    /// ```toml
    /// [forge]
    /// kind = "github"
    /// [forge.github]                     # optional; defaults shown
    /// api_base  = "https://api.github.com"  # GitHub Enterprise: "https://ghe.example.com/api/v3"
    /// token_env = "GITHUB_TOKEN"            # a token that can push and open pull requests
    /// ```
    ///
    /// Writes the git askpass helper into `config.stateDir`; does no network I/O.
    /// - Parameters:
    ///   - config: The host config.
    ///   - log: Receives retry notes for rate limits and server errors.
    ///   - environment: The Manager's `secrets.env` values overlaid on its process
    ///     environment; the token is looked up here only.
    /// - Throws: `ConfigError` naming the key for an invalid `api_base` or an unset token
    ///   variable; a file error if the askpass helper can't be written.
    public static func makeForge(config: HostConfig, log: LogSink, environment: [String: String]) throws -> GitHubForge {
        try makeForge(config: config, log: log, environment: environment, transport: urlSessionTransport)
    }

    /// The environment variables that `makeForge` reads credentials from for this config.
    /// - Throws: `ConfigError` when `[forge.github]` doesn't decode.
    public static func credentialVariables(config: HostConfig) throws -> [String] {
        [try section(config)?.token_env ?? "GITHUB_TOKEN"]
    }

    private struct Raw: Decodable {
        var forge: Forge?
        struct Forge: Decodable { var github: Section? }
        struct Section: Decodable {
            var api_base: String?
            var token_env: String?
        }
    }

    private static func section(_ config: HostConfig) throws -> Raw.Section? {
        do { return try TOMLDecoder().decode(Raw.self, from: config.toml).forge?.github }
        catch { throw ConfigError("config.toml: [forge.github]: \(error)") }
    }

    static func makeForge(
        config: HostConfig, log: LogSink, environment: [String: String], transport: @escaping HTTPTransport,
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> GitHubForge {
        let section = try section(config)

        let base = section?.api_base ?? "https://api.github.com"
        guard let apiBase = URL(string: base), let host = apiBase.host, let scheme = apiBase.scheme else {
            throw ConfigError("config.toml: [forge.github] api_base must be an absolute URL, got \(base)")
        }
        let tokenEnv = section?.token_env ?? "GITHUB_TOKEN"
        guard let token = environment[tokenEnv], !token.isEmpty else {
            throw ConfigError("\(tokenEnv) is not set: put a GitHub token that can push and open pull requests in secrets.env ([forge.github] token_env)")
        }
        let webHost = host.hasPrefix("api.") ? String(host.dropFirst(4)) : host
        let webBase = "\(scheme)://\(webHost)" + (apiBase.port.map { ":\($0)" } ?? "")
        let gitEnv = try GitAskPass.environment(scriptDirectory: config.stateDir, username: "x-access-token", password: token)
        return GitHubForge(apiBase: apiBase, webBase: webBase, tokenEnv: tokenEnv, token: token, gitEnv: gitEnv,
                           projects: config.projects.map(\.path), log: log, transport: transport, sleep: sleep, now: now)
    }
}

/// Sends one HTTP request. Injected so that tests serve fabricated responses.
typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

let urlSessionTransport: HTTPTransport = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw GitHubError.transport(request.url?.absoluteString ?? "?", "not an HTTP response")
    }
    return (data, http)
}

/// Failures of the GitHub forge other than `BackendRejection`.
public enum GitHubError: Error, CustomStringConvertible, Equatable {
    /// 401, or a 403 that isn't a rate limit: the token is invalid or lacks a permission.
    case unauthorized(tokenEnv: String, request: String, status: Int, message: String)
    /// Still 408, 429 or 5xx after the retries; a later finish may succeed.
    case unavailable(request: String, status: Int, message: String)
    case transport(String, String)
    case malformed(String)

    public var description: String {
        switch self {
        case .unauthorized(let env, let request, let status, let message):
            "\(request): \(status) \(message); check that the token in \(env) is valid and can push and open pull requests"
        case .unavailable(let request, let status, let message): "\(request): \(status) \(message)"
        case .transport(let request, let detail): "\(request): \(detail)"
        case .malformed(let detail): "GitHub returned malformed data: \(detail)"
        }
    }
}

/// GitHub (or GitHub Enterprise) as a `Forge`. Pull requests are opened through the REST API
/// with the token from `[forge.github] token_env`; git gets the same token through askpass.
public struct GitHubForge: Forge {
    static let maxRetries = 3

    let apiBase: URL
    let webBase: String
    let tokenEnv: String
    private let token: String
    private let gitEnv: [String: String]
    /// The configured projects' paths, for doctor's repository checks.
    let projects: [String]
    private let log: LogSink
    private let transport: HTTPTransport
    private let sleep: @Sendable (Double) async throws -> Void
    private let now: @Sendable () -> Date

    init(apiBase: URL, webBase: String, tokenEnv: String, token: String, gitEnv: [String: String], projects: [String], log: LogSink,
         transport: @escaping HTTPTransport, sleep: @escaping @Sendable (Double) async throws -> Void,
         now: @escaping @Sendable () -> Date) {
        self.apiBase = apiBase
        self.webBase = webBase
        self.tokenEnv = tokenEnv
        self.token = token
        self.gitEnv = gitEnv
        self.projects = projects
        self.log = log
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    public func cloneURL(for project: ProjectSpec) -> String { "\(webBase)/\(project.path).git" }

    public func gitEnvironment() -> [String: String] { gitEnv }

    public func defaultBranch(for project: ProjectSpec) async throws -> String {
        struct Repo: Decodable { var default_branch: String }
        return try await request("GET", "repos/\(project.path)", as: Repo.self).default_branch
    }

    public func openReviewRequest(for project: ProjectSpec, sourceBranch: String) async throws -> ReviewRequest? {
        try await openPulls(project.path, sourceBranch).first?.reviewRequest(project.path)
    }

    private func openPulls(_ path: String, _ sourceBranch: String) async throws -> [Pull] {
        let owner = path.split(separator: "/").first.map(String.init) ?? path
        return try await request("GET", "repos/\(path)/pulls", query: [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "head", value: "\(owner):\(sourceBranch)"),
        ], as: [Pull].self)
    }

    public func openReviewRequest(_ draft: ReviewRequestDraft) async throws -> ReviewRequest {
        let path = draft.project.path
        let open = try await openPulls(path, draft.sourceBranch)
        if let existing = open.first {
            let review = existing.reviewRequest(path)
            if draft.assignToOwner, existing.assignees?.isEmpty ?? true { await assignOwner(path, existing.number, review) }
            return review
        }

        var body = NewPull(title: draft.title, head: draft.sourceBranch, base: draft.targetBranch,
                           body: draft.body + (draft.marker.map { "\n\n" + $0 } ?? ""), draft: draft.draft)
        let pull: Pull
        do {
            pull = try await request("POST", "repos/\(path)/pulls", body: body, as: Pull.self)
        } catch let e as BackendRejection where body.draft && e.description.localizedCaseInsensitiveContains("draft") {
            // Private repos on free plans refuse drafts; a ready pull request beats a stuck card.
            log.warning("\(path) refuses draft pull requests; opening \(draft.sourceBranch) as ready for review")
            body.draft = false
            pull = try await request("POST", "repos/\(path)/pulls", body: body, as: Pull.self)
        }
        let review = pull.reviewRequest(path)
        if draft.assignToOwner { await assignOwner(path, pull.number, review) }
        return review
    }

    /// Assigns pull request `number` to the token's user, or logs why it can't.
    private func assignOwner(_ path: String, _ number: Int, _ review: ReviewRequest) async {
        struct Assignees: Encodable { var assignees: [String] }
        do {
            let me = try await request("GET", "user", as: User.self)
            _ = try await request("POST", "repos/\(path)/issues/\(number)/assignees", body: Assignees(assignees: [me.login]), as: Ignored.self)
        } catch {
            log.warning("can't assign \(review.display) (\(review.url.absoluteString)) to the token's user: \(error); leaving it unassigned")
        }
    }

    /// Reads the pull request's review threads, its conversation comments and the bodies of its
    /// submitted reviews over GraphQL; a review body counts like a conversation comment. A
    /// thread keeps its 100 newest comments; `cut` says when older ones were left out. A note's
    /// time is `publishedAt`, because a comment in a review keeps its draft's `createdAt`.
    public func reviewFeedback(for review: ReviewRequest, project: ProjectSpec, vouchedAt: Date?) async throws -> ReviewFeedback {
        let number = try pullNumber(review)
        let me = try await request("GET", "user", as: User.self).login
        let parts = project.path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw GitHubError.malformed("\(project.path) is not <owner>/<repo>") }
        func note(_ c: GQLComment) -> ReviewFeedback.RawNote {
            let edit: ReviewFeedback.Edit = c.lastEditedAt.map {
                .edited(by: c.editor?.login ?? "ghost", owner: c.editor?.login.lowercased() == me.lowercased(), at: $0)
            } ?? .never
            return .init(id: c.id, author: c.author?.login ?? "ghost", byOwner: c.author?.login.lowercased() == me.lowercased(),
                         createdAt: c.publishedAt ?? c.createdAt, body: c.body, edit: edit)
        }
        var threads: [ReviewFeedback.RawThread] = [], cut: [String] = [], opened: Date?
        for query in [Self.reviewThreadsQuery, Self.commentsQuery, Self.reviewsQuery] {
            var after: String?
            repeat {
                let data: GQLPullPage = try await graphQL("review feedback on \(review.display)", query, [
                    "owner": parts[0], "name": parts[1], "number": number, "after": after ?? NSNull(),
                ])
                guard let pull = data.repository?.pullRequest else {
                    throw GitHubError.malformed("GraphQL returned no pull request for \(review.display)")
                }
                opened = pull.createdAt
                let info = pull.reviewThreads?.pageInfo ?? pull.comments?.pageInfo ?? pull.reviews?.pageInfo
                if let t = pull.reviewThreads {
                    for thread in t.nodes {
                        let first = thread.comments.nodes.first
                        let current = thread.line != nil
                        let position = thread.path.map {
                            ReviewFeedback.Position(path: $0, line: thread.line ?? thread.originalLine, side: thread.diffSide == "LEFT" ? .old : .new,
                                                    commit: current ? first?.commit?.oid : first?.originalCommit?.oid)
                        }
                        if thread.comments.totalCount > thread.comments.nodes.count {
                            cut.append("the \(thread.comments.totalCount - thread.comments.nodes.count) oldest comments of thread \(thread.id) were left out")
                        }
                        threads.append(.init(id: thread.id, position: position, resolvable: true, resolved: thread.isResolved,
                                             notes: thread.comments.nodes.map(note)))
                    }
                }
                let reviews = (pull.reviews?.nodes ?? []).filter { $0.state != "PENDING" && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                for c in (pull.comments?.nodes ?? []) + reviews {
                    threads.append(.init(id: c.id, position: nil, resolvable: false, resolved: false, notes: [note(c)]))
                }
                after = info?.hasNextPage == true ? info?.endCursor : nil
            } while after != nil
        }
        guard let opened else { throw GitHubError.malformed("GraphQL returned no createdAt for \(review.display)") }
        var feedback = ReviewFeedback.build(threads, owner: me, openedAt: opened, vouchedAt: vouchedAt)
        feedback.cut += cut
        return feedback
    }

    static let reviewThreadsQuery = """
        query($owner: String!, $name: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              createdAt
              reviewThreads(first: 50, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id isResolved path line originalLine diffSide
                  comments(last: 100) {
                    totalCount
                    nodes { id author { login } body createdAt publishedAt lastEditedAt editor { login } commit { oid } originalCommit { oid } }
                  }
                }
              }
            }
          }
        }
        """

    static let commentsQuery = """
        query($owner: String!, $name: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              createdAt
              comments(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { id author { login } body createdAt publishedAt lastEditedAt editor { login } }
              }
            }
          }
        }
        """

    static let reviewsQuery = """
        query($owner: String!, $name: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              createdAt
              reviews(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { id state author { login } body createdAt publishedAt lastEditedAt editor { login } }
              }
            }
          }
        }
        """

    struct GQLLogin: Decodable { var login: String }
    struct GQLCommit: Decodable { var oid: String }
    struct GQLComment: Decodable {
        var id: String
        var author: GQLLogin?
        var body: String
        var createdAt: Date
        /// Nil while the comment sits in a pending review.
        var publishedAt: Date?
        var lastEditedAt: Date?
        var editor: GQLLogin?
        /// A review's state; `PENDING` until it is submitted.
        var state: String?
        var commit: GQLCommit?
        var originalCommit: GQLCommit?
    }
    struct GQLThread: Decodable {
        struct Comments: Decodable {
            var totalCount: Int
            var nodes: [GQLComment]
        }
        var id: String
        var isResolved: Bool
        var path: String?
        var line: Int?
        var originalLine: Int?
        var diffSide: String?
        var comments: Comments
    }
    struct GQLPullPage: Decodable {
        struct PageInfo: Decodable {
            var hasNextPage: Bool
            var endCursor: String?
        }
        struct Connection<Node: Decodable>: Decodable {
            var pageInfo: PageInfo
            var nodes: [Node]
        }
        struct Pull: Decodable {
            var createdAt: Date
            var reviewThreads: Connection<GQLThread>?
            var comments: Connection<GQLComment>?
            var reviews: Connection<GQLComment>?
        }
        struct Repository: Decodable { var pullRequest: Pull? }
        var repository: Repository?
    }

    public func postReviewNote(_ text: String, marker: String, on review: ReviewRequest, project: ProjectSpec) async throws -> Bool {
        struct PullBody: Decodable { var body: String? }
        let number = try pullNumber(review)
        if try await request("GET", "repos/\(project.path)/pulls/\(number)", as: PullBody.self).body?.contains(marker) == true { return false }
        if try await myConversationComments(project, number).contains(where: { ReviewMarker.has(marker, $0) }) { return false }
        try await postComment(project, number, ReviewMarker.note(text, markers: [marker]))
        return true
    }

    /// A review thread gets a reply to its first comment. A conversation comment or a review
    /// body has no thread, so its reply is a new conversation comment that links it.
    public func replyToThread(_ thread: String, text: String, marker: String, on review: ReviewRequest, project: ProjectSpec) async throws -> ThreadReply {
        let number = try pullNumber(review)
        let result = try await graphQLEnvelope("thread \(thread) of \(review.display)", Self.threadQuery, ["id": thread], as: GQLNodeData.self)
        if result.errors.contains(where: { $0.type == "NOT_FOUND" }) { return .noSuchThread }
        guard let node = try result.get().node, node.repository?.nameWithOwner.lowercased() == project.path.lowercased(),
              node.pullRequest?.number == number else { return .noSuchThread }
        let body = ReviewMarker.note(text, markers: [marker])
        let me = try await login()
        switch node.typename {
        case "PullRequestReviewThread":
            if node.comments?.nodes.contains(where: { $0.author?.login.lowercased() == me.lowercased() && ReviewMarker.has(marker, $0.body ?? "") }) == true {
                return .alreadyPosted
            }
            guard let first = node.first?.nodes.first?.databaseId else {
                throw GitHubError.malformed("thread \(thread) of \(review.display) has no comment to reply to")
            }
            struct Reply: Encodable { var body: String }
            _ = try await request("POST", "repos/\(project.path)/pulls/\(number)/comments/\(first)/replies", body: Reply(body: body), as: Ignored.self)
        case "IssueComment", "PullRequestReview":
            if try await myConversationComments(project, number).contains(where: { ReviewMarker.has(marker, $0) }) { return .alreadyPosted }
            let link = node.url.map { "[@\(node.author?.login ?? "ghost")'s comment](\($0.absoluteString))" } ?? "a comment"
            try await postComment(project, number, ReviewMarker.note("In reply to \(link):\n\n\(text)", markers: [marker]))
        default:
            return .noSuchThread
        }
        return .posted
    }

    static let threadQuery = """
        query($id: ID!) {
          node(id: $id) {
            __typename
            ... on PullRequestReviewThread {
              repository { nameWithOwner }
              pullRequest { number }
              first: comments(first: 1) { nodes { databaseId } }
              comments(last: 100) { nodes { author { login } body } }
            }
            ... on IssueComment {
              repository { nameWithOwner }
              pullRequest { number }
              url
              author { login }
            }
            ... on PullRequestReview {
              repository { nameWithOwner }
              pullRequest { number }
              url
              author { login }
            }
          }
        }
        """

    struct GQLNodeData: Decodable {
        struct Node: Decodable {
            struct Repository: Decodable { var nameWithOwner: String }
            struct Pull: Decodable { var number: Int }
            struct Comments: Decodable {
                struct Comment: Decodable {
                    var databaseId: Int?
                    var author: GQLLogin?
                    var body: String?
                }
                var nodes: [Comment]
            }
            var typename: String
            var repository: Repository?
            var pullRequest: Pull?
            var first: Comments?
            var comments: Comments?
            var url: URL?
            var author: GQLLogin?
            enum CodingKeys: String, CodingKey {
                case typename = "__typename", repository, pullRequest, first, comments, url, author
            }
        }
        var node: Node?
    }

    private func login() async throws -> String { try await request("GET", "user", as: User.self).login }

    /// The bodies of every conversation comment on pull request `number` that the token's user wrote.
    private func myConversationComments(_ project: ProjectSpec, _ number: Int) async throws -> [String] {
        struct Comment: Decodable {
            var body: String?
            var user: User?
        }
        let me = try await login().lowercased()
        var mine: [String] = []
        for page in 1... {
            let comments = try await request("GET", "repos/\(project.path)/issues/\(number)/comments", query: [
                URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: "\(page)"),
            ], as: [Comment].self)
            mine += comments.filter { $0.user?.login.lowercased() == me }.compactMap(\.body)
            if comments.count < 100 { break }
        }
        return mine
    }

    private func postComment(_ project: ProjectSpec, _ number: Int, _ body: String) async throws {
        struct Body: Encodable { var body: String }
        _ = try await request("POST", "repos/\(project.path)/issues/\(number)/comments", body: Body(body: body), as: Ignored.self)
    }

    /// The number in a display that `Pull.reviewRequest` made, `<path>#<number>`.
    private func pullNumber(_ review: ReviewRequest) throws -> Int {
        guard let n = review.display.split(separator: "#").last.flatMap({ Int($0) }) else {
            throw GitHubError.malformed("\(review.display) (\(review.url.absoluteString)) doesn't name a pull request as <path>#<number>")
        }
        return n
    }

    /// The commit's latest check runs (GitHub Actions and other apps), read as one pipeline:
    /// none is nil; any run not completed is running; any `failure` or `timed_out` is failed;
    /// any `cancelled` is canceled; all `success`, `neutral` or `skipped` pass. Other
    /// conclusions (`action_required`, `stale`) count as running, so the Manager's CI timeout
    /// ends the wait. Commit statuses from the older status API are not read. `url` is the
    /// commit's checks page.
    public func pipeline(for project: ProjectSpec, commit: String) async throws -> PipelineStatus? {
        let runs = try await checkRuns(project, ref: commit)
        guard !runs.isEmpty else { return nil }
        let url = URL(string: "\(webBase)/\(project.path)/commit/\(commit)/checks")
        if runs.contains(where: { $0.status != "completed" }) { return PipelineStatus(state: .running, url: url) }
        let failed = runs.filter { $0.conclusion == "failure" || $0.conclusion == "timed_out" }
        if !failed.isEmpty {
            return PipelineStatus(state: .failed, url: url, failedJobs: failed.map {
                CIJob(name: $0.name, stage: "", url: $0.html_url, logTail: CIJob.tail($0.output?.text ?? $0.output?.summary ?? ""),
                      id: $0.app?.slug == "github-actions" ? $0.id.map(String.init) : nil)
            })
        }
        if runs.contains(where: { $0.conclusion == "cancelled" }) { return PipelineStatus(state: .canceled, url: url) }
        let passing: Set<String?> = ["success", "neutral", "skipped"]
        return PipelineStatus(state: runs.allSatisfy { passing.contains($0.conclusion) } ? .passed : .running, url: url)
    }

    /// Reads the latest completed check runs on the head commit of branch `ref`: `success` passed,
    /// `failure` or `timed_out` failed, other conclusions unknown. When several runs share a
    /// name, a passed one wins.
    public func baselineJobs(for project: ProjectSpec, ref: String, names: [String]) async throws -> [String: CIJobBaseline] {
        var result = Dictionary(names.map { ($0, CIJobBaseline.unknown) }, uniquingKeysWith: { a, _ in a })
        for run in try await checkRuns(project, ref: "heads/\(ref)", status: "completed") where result[run.name] != nil {
            switch (result[run.name]!, run.conclusion) {
            case (.passed, _): continue
            case (_, "success"): result[run.name] = .passed(run.html_url)
            case (_, "failure"), (_, "timed_out"): result[run.name] = .failed(run.html_url)
            default: continue
            }
        }
        return result
    }

    /// Re-runs each job through `POST /repos/{repo}/actions/jobs/{id}/rerun`. Only GitHub
    /// Actions jobs can be re-run; a check run of any other app makes this return false.
    public func retryJobs(project: ProjectSpec, jobs: [CIJob]) async throws -> Bool {
        let ids = jobs.compactMap(\.id)
        guard ids.count == jobs.count else { return false }
        for id in ids {
            _ = try await request("POST", "repos/\(project.path)/actions/jobs/\(id)/rerun", as: NoBody.self)
        }
        return true
    }

    /// `PUT .../pulls/:n/merge` with `merge_method` `merge` and `sha`. A refusal (403, 405, 409,
    /// 422) re-reads the pull request: merged is merged; closed, a moved head (409), a missing
    /// merge right (403) or a draft is blocked; a null `mergeable` is pending; otherwise
    /// `mergeable_state` decides, `blocked` being pending while the head's checks run.
    public func merge(_ review: ReviewRequest, project: ProjectSpec, head: String) async throws -> MergeResult {
        guard let number = Int(review.url.lastPathComponent), number > 0 else {
            throw BackendRejection("can't merge \(review.display): \(review.url.absoluteString) doesn't end in a pull request number")
        }
        struct Merge: Encodable { var merge_method = "merge"; var sha: String }
        struct Merged: Decodable { var merged: Bool?; var sha: String? }
        let path = "repos/\(project.path)/pulls/\(number)"
        var refusal: Refusal?
        do {
            let answer = try await request("PUT", path + "/merge", body: Merge(sha: head), refusals: [403, 405, 409, 422], as: Merged.self)
            if answer.merged == true { return .merged(commit: answer.sha) }
        } catch let r as Refusal { refusal = r }
        struct State: Decodable {
            var merged: Bool?
            var merge_commit_sha: String?
            var state: String
            var draft: Bool?
            var mergeable: Bool?
            var mergeable_state: String?
        }
        let pull = try await request("GET", path, as: State.self)
        if pull.merged == true { return .merged(commit: pull.merge_commit_sha) }
        if pull.state != "open" { return .blocked("GitHub: \(pull.state) (the pull request isn't open)") }
        if let r = refusal, r.status == 409 { return .blocked("GitHub: the source branch's head moved past \(head.prefix(12)) (\(r.message))") }
        // The GET with the same token worked, so a 403 is the token's user lacking merge rights, not a bad token.
        if let r = refusal, r.status == 403 { return .blocked("GitHub: the token's user may not merge this pull request (the merge answered 403 \(r.message))") }
        if pull.draft == true { return .blocked("GitHub: draft (the pull request is a draft)") }
        guard pull.mergeable != nil else { return .pending("GitHub: mergeable unknown (GitHub is still computing it)") }
        let answered = "the merge answered " + (refusal.map { "\($0.status) \($0.message)" } ?? "unmerged")
        switch pull.mergeable_state ?? "no mergeable_state" {
        case "dirty": return .outdated("GitHub: dirty (it conflicts with the base branch)")
        case "behind": return .outdated("GitHub: behind (branch protection requires it to be up to date with the base branch)")
        case "blocked":
            // GitHub also says blocked while required checks still run.
            if try await pipeline(for: project, commit: head)?.state == .running {
                return .pending("GitHub: blocked while the head's checks run (\(answered))")
            }
            return .blocked("GitHub: blocked (required reviews, checks or branch protection; \(answered))")
        case let s where ["unknown", "unstable", "clean", "has_hooks"].contains(s):
            // A refusal on a mergeable pull request is a repository rule (no merge commits, say), unless the base just moved.
            if let r = refusal, !r.message.contains("Base branch was modified") { return .blocked("GitHub: \(s) (\(answered))") }
            return .pending("GitHub: \(s) (\(answered))")
        case let s: return .blocked("GitHub: \(s) (\(answered))")
        }
    }

    /// Always nil: GitHub's API has no way to attach a file to a pull request.
    public func attach(_ file: URL, to project: ProjectSpec) async throws -> URL? { nil }

    // MARK: HTTP

    private struct User: Decodable { var login: String }
    private struct Ignored: Decodable {}

    private struct CheckRun: Decodable {
        /// For a GitHub Actions run, also its job id.
        var id: Int?
        var app: App?
        struct App: Decodable { var slug: String? }
        var name: String
        var status: String
        var conclusion: String?
        var html_url: URL?
        var output: Output?
        struct Output: Decodable {
            var summary: String?
            var text: String?
        }
    }

    /// Every latest check run on `ref` (a commit, or `heads/<branch>`), optionally only those with `status`.
    private func checkRuns(_ project: ProjectSpec, ref: String, status: String? = nil) async throws -> [CheckRun] {
        struct Page: Decodable {
            var total_count: Int
            var check_runs: [CheckRun]
        }
        var runs: [CheckRun] = []
        for page in 1... {
            let p = try await request("GET", "repos/\(project.path)/commits/\(ref)/check-runs", query: [
                URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: "\(page)"),
            ] + (status.map { [URLQueryItem(name: "status", value: $0)] } ?? []), as: Page.self)
            runs += p.check_runs
            if p.check_runs.isEmpty || runs.count >= p.total_count { break }
        }
        return runs
    }

    private struct Pull: Decodable {
        var number: Int
        var html_url: URL
        var assignees: [User]?
        func reviewRequest(_ path: String) -> ReviewRequest { ReviewRequest(url: html_url, display: "\(path)#\(number)") }
    }

    private struct NewPull: Encodable {
        var title: String
        var head: String
        var base: String
        var body: String
        var draft: Bool
    }

    private struct NoBody: Codable {}

    /// A status that the caller listed in `refusals`, thrown instead of a `BackendRejection`.
    private struct Refusal: Error {
        var status: Int
        var message: String
    }

    private func request<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], as: T.Type) async throws -> T {
        try await request(method, path, query: query, body: Optional<NoBody>.none, as: T.self)
    }

    /// Sends one API request, retrying 408, 429, 5xx and rate-limit 403s up to three times. A
    /// status in `refusals` throws `Refusal`.
    private func request<B: Encodable, T: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: B?, refusals: Set<Int> = [], as: T.Type
    ) async throws -> T {
        var comps = URLComponents(url: apiBase.appending(path: path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query.isEmpty ? nil : query
        return try await send(method, comps.url!, label: "\(method) /\(path)", body: try body.map { try JSONEncoder().encode($0) },
                              refusals: refusals, as: T.self)
    }

    /// The GraphQL endpoint: `/graphql` on api.github.com, `/api/graphql` on Enterprise.
    var graphQLURL: URL {
        apiBase.path.hasSuffix("/v3") ? apiBase.deletingLastPathComponent().appending(path: "graphql") : apiBase.appending(path: "graphql")
    }

    /// Runs a GraphQL operation and returns its `data`; any `errors` throw.
    private func graphQL<T: Decodable>(_ operation: String, _ query: String, _ variables: [String: Any]) async throws -> T {
        try await graphQLEnvelope(operation, query, variables, as: T.self).get()
    }

    private func graphQLEnvelope<T: Decodable>(_ operation: String, _ query: String, _ variables: [String: Any], as: T.Type) async throws -> GraphQLResult<T> {
        let label = "POST graphql \(operation)"
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables], options: [.sortedKeys])
        let envelope = try await send("POST", graphQLURL, label: label, body: body, as: GraphQLEnvelope<T>.self)
        return GraphQLResult(label: label, data: envelope.data, errors: envelope.errors ?? [])
    }

    private func send<T: Decodable>(_ method: String, _ url: URL, label: String, body: Data?, refusals: Set<Int> = [], as: T.Type) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("loopworker", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }

        var attempt = 0
        while true {
            let data: Data, resp: HTTPURLResponse
            do { (data, resp) = try await transport(req) }
            catch { throw GitHubError.transport(label, error.localizedDescription) }
            let status = resp.statusCode
            if (200..<300).contains(status) {
                if data.isEmpty, let none = NoBody() as? T { return none }
                do { return try Self.decoder.decode(T.self, from: data) }
                catch { throw GitHubError.malformed("\(label): \(error)") }
            }
            let message = Self.message(data)
            let rateLimited = status == 429 || (status == 403 && (resp.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
                || resp.value(forHTTPHeaderField: "retry-after") != nil))
            let transient = rateLimited || status == 408 || status >= 500
            if transient, attempt < Self.maxRetries {
                let wait = retryDelay(resp, attempt: attempt)
                log.warning("\(label): \(status) \(message); retrying in \(Int(wait)) s")
                try await sleep(wait)
                attempt += 1
                continue
            }
            if transient { throw GitHubError.unavailable(request: label, status: status, message: message) }
            if refusals.contains(status) { throw Refusal(status: status, message: message) }
            if status == 401 || status == 403 {
                throw GitHubError.unauthorized(tokenEnv: tokenEnv, request: label, status: status, message: message)
            }
            throw BackendRejection("\(label): \(status) \(message)")
        }
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    struct GraphQLError: Decodable {
        var message: String
        /// `NOT_FOUND` for an id that names nothing.
        var type: String?
    }

    private struct GraphQLEnvelope<T: Decodable>: Decodable {
        var data: T?
        var errors: [GraphQLError]?
    }

    struct GraphQLResult<T> {
        var label: String
        var data: T?
        var errors: [GraphQLError]

        func get() throws -> T {
            if !errors.isEmpty { throw GitHubError.malformed("\(label): \(errors.map(\.message).joined(separator: "; "))") }
            guard let data else { throw GitHubError.malformed("\(label): response has no data") }
            return data
        }
    }

    /// `Retry-After`, else the rate-limit reset when the limit is spent, else 2 s doubling; at most 60 s.
    private func retryDelay(_ resp: HTTPURLResponse, attempt: Int) -> Double {
        if let s = resp.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) { return min(max(s, 0), 60) }
        if resp.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0",
           let reset = resp.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init) {
            return min(max(reset - now().timeIntervalSince1970, 1), 60)
        }
        return min(2 * pow(2, Double(attempt)), 60)
    }

    /// GitHub's `message` plus each `errors[].message`, else the start of the body.
    static func message(_ data: Data) -> String {
        struct Body: Decodable {
            var message: String?
            var errors: [Detail]?
            struct Detail: Decodable { var message: String? }
        }
        guard let b = try? JSONDecoder().decode(Body.self, from: data), let m = b.message else {
            return String(decoding: data.prefix(300), as: UTF8.self)
        }
        let details = (b.errors ?? []).compactMap(\.message)
        return details.isEmpty ? m : "\(m): \(details.joined(separator: "; "))"
    }
}

extension GitHubForge: Diagnosable {
    /// Reads the token's user (`GET /user`), then each project's repository: the token must
    /// see it, and its user must be allowed to push. A fine-grained token's own permissions
    /// aren't readable, so a repository that passes can still refuse the push.
    public func diagnose() async -> [DoctorCheck] {
        let user: String
        do { user = try await login() } catch {
            return [DoctorCheck("forge github", .fail, "\(error)",
                                remedy: "check that this host reaches \(apiBase.absoluteString) and that \(tokenEnv) holds a GitHub token that can push and open pull requests")]
        }
        var checks = [DoctorCheck("forge github", .ok, "\(tokenEnv) belongs to @\(user) on \(apiBase.absoluteString)")]
        for path in projects { checks.append(await repositoryCheck(path, user: user)) }
        return checks
    }

    private func repositoryCheck(_ path: String, user: String) async -> DoctorCheck {
        struct Repo: Decodable {
            struct Permissions: Decodable { var push: Bool? }
            var permissions: Permissions?
        }
        let name = "forge github \(path)"
        do {
            let repo = try await request("GET", "repos/\(path)", body: Optional<NoBody>.none, refusals: [404], as: Repo.self)
            guard repo.permissions?.push != false else {
                return DoctorCheck(name, .fail, "@\(user) may not push to \(path)", remedy: "give @\(user) write access to \(path)")
            }
            return DoctorCheck(name, .ok, "@\(user) can see \(path) and push to it")
        } catch is Refusal {
            return DoctorCheck(name, .fail, "\(tokenEnv) can't see \(path)",
                               remedy: "give the token access to \(path): a fine-grained token needs the repository selected, with Contents and Pull requests set to read and write; a classic token needs the repo scope")
        } catch {
            return DoctorCheck(name, .fail, "\(error)", remedy: "check that \(path) is the repository's owner/name on GitHub")
        }
    }
}
