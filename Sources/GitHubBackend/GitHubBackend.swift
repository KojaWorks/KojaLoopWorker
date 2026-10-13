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
        if let existing = open.first { return existing.reviewRequest(path) }

        var body = NewPull(title: draft.title, head: draft.sourceBranch, base: draft.targetBranch, body: draft.body, draft: draft.draft)
        do {
            return try await request("POST", "repos/\(path)/pulls", body: body, as: Pull.self).reviewRequest(path)
        } catch let e as BackendRejection where body.draft && e.description.localizedCaseInsensitiveContains("draft") {
            // Private repos on free plans refuse drafts; a ready pull request beats a stuck card.
            log.warning("\(path) refuses draft pull requests; opening \(draft.sourceBranch) as ready for review")
            body.draft = false
            return try await request("POST", "repos/\(path)/pulls", body: body, as: Pull.self).reviewRequest(path)
        }
    }

    /// Always nil: GitHub's API has no way to attach a file to a pull request.
    public func attach(_ file: URL, to project: ProjectSpec) async throws -> URL? { nil }

    // MARK: HTTP

    private struct Pull: Decodable {
        var number: Int
        var html_url: URL
        func reviewRequest(_ path: String) -> ReviewRequest { ReviewRequest(url: html_url, display: "\(path)#\(number)") }
    }

    private struct NewPull: Encodable {
        var title: String
        var head: String
        var base: String
        var body: String
        var draft: Bool
    }

    private struct NoBody: Encodable {}

    private func request<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], as: T.Type) async throws -> T {
        try await request(method, path, query: query, body: Optional<NoBody>.none, as: T.self)
    }

    /// Sends one API request, retrying 408, 429, 5xx and rate-limit 403s up to three times.
    private func request<B: Encodable, T: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: B?, as: T.Type
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
