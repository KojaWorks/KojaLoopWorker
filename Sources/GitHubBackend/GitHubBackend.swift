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
                           log: log, transport: transport, sleep: sleep, now: now)
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
    private let log: LogSink
    private let transport: HTTPTransport
    private let sleep: @Sendable (Double) async throws -> Void
    private let now: @Sendable () -> Date

    init(apiBase: URL, webBase: String, tokenEnv: String, token: String, gitEnv: [String: String], log: LogSink,
         transport: @escaping HTTPTransport, sleep: @escaping @Sendable (Double) async throws -> Void,
         now: @escaping @Sendable () -> Date) {
        self.apiBase = apiBase
        self.webBase = webBase
        self.tokenEnv = tokenEnv
        self.token = token
        self.gitEnv = gitEnv
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

    public func openReviewRequest(_ draft: ReviewRequestDraft) async throws -> ReviewRequest {
        let path = draft.project.path
        let owner = path.split(separator: "/").first.map(String.init) ?? path
        let open = try await request("GET", "repos/\(path)/pulls", query: [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "head", value: "\(owner):\(draft.sourceBranch)"),
        ], as: [Pull].self)
        if let existing = open.first {
            let review = existing.reviewRequest(path)
            if draft.assignToOwner, existing.assignees?.isEmpty ?? true { await assignOwner(path, existing.number, review) }
            return review
        }

        var body = NewPull(title: draft.title, head: draft.sourceBranch, base: draft.targetBranch, body: draft.body, draft: draft.draft)
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

    /// `PUT .../pulls/:n/merge` with `merge_method` `merge` and `sha`. A 409 is a moved head. A 405
    /// or 422 re-reads the pull request: merged is merged; closed or a draft is blocked; a null
    /// `mergeable` is pending; otherwise `mergeable_state` decides.
    public func merge(_ review: ReviewRequest, project: ProjectSpec, head: String) async throws -> MergeResult {
        guard let number = Int(review.url.lastPathComponent), number > 0 else {
            throw BackendRejection("can't merge \(review.display): \(review.url.absoluteString) doesn't end in a pull request number")
        }
        struct Merge: Encodable { var merge_method = "merge"; var sha: String }
        struct Merged: Decodable { var merged: Bool?; var sha: String? }
        let path = "repos/\(project.path)/pulls/\(number)"
        var refusal: Refusal?
        do {
            let answer = try await request("PUT", path + "/merge", body: Merge(sha: head), refusals: [405, 409, 422], as: Merged.self)
            if answer.merged == true { return .merged(commit: answer.sha) }
        } catch let r as Refusal {
            if r.status == 409 { return .blocked("GitHub: the source branch's head moved past \(head.prefix(12)) (\(r.message))") }
            refusal = r
        }
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
        if pull.draft == true { return .blocked("GitHub: draft (the pull request is a draft)") }
        guard pull.mergeable != nil else { return .pending("GitHub: mergeable unknown (GitHub is still computing it)") }
        let answered = "the merge answered " + (refusal.map { "\($0.status) \($0.message)" } ?? "unmerged")
        switch pull.mergeable_state ?? "no mergeable_state" {
        case "dirty": return .outdated("GitHub: dirty (it conflicts with the base branch)")
        case "behind": return .outdated("GitHub: behind (branch protection requires it to be up to date with the base branch)")
        case "blocked": return .blocked("GitHub: blocked (required reviews, checks or branch protection; \(answered))")
        case let s where ["unknown", "unstable", "clean", "has_hooks"].contains(s): return .pending("GitHub: \(s) (\(answered))")
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
        let label = "\(method) /\(path)"
        var comps = URLComponents(url: apiBase.appending(path: path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query.isEmpty ? nil : query
        var req = URLRequest(url: comps.url!, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("loopworker", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }

        var attempt = 0
        while true {
            let data: Data, resp: HTTPURLResponse
            do { (data, resp) = try await transport(req) }
            catch { throw GitHubError.transport(label, error.localizedDescription) }
            let status = resp.statusCode
            if (200..<300).contains(status) {
                if data.isEmpty, let none = NoBody() as? T { return none }
                do { return try JSONDecoder().decode(T.self, from: data) }
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
            if refusals.contains(status) { throw Refusal(status: status, message: message) }
            if transient { throw GitHubError.unavailable(request: label, status: status, message: message) }
            if status == 401 || status == 403 {
                throw GitHubError.unauthorized(tokenEnv: tokenEnv, request: label, status: status, message: message)
            }
            throw BackendRejection("\(label): \(status) \(message)")
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
