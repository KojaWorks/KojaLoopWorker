import Foundation
import LoopWorkerCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one HTTP request. Injected so that tests serve fabricated responses.
typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

let urlSessionTransport: HTTPTransport = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw PatchError.transport(request.url?.absoluteString ?? "?", "not an HTTP response")
    }
    return (data, http)
}

/// Failures of the Patch backlog other than `BackendRejection`.
public enum PatchError: Error, CustomStringConvertible, Equatable {
    /// The PAT exchange answered 401 or 403: the token in the named variable is revoked or wrong.
    case patRejected(tokenEnv: String)
    /// PostgREST answered 401 or 403 even with a fresh session.
    case unauthorized(tokenEnv: String, request: String, status: Int)
    /// The deployment didn't answer usefully (5xx, 408, 429); retrying later may help.
    case unavailable(request: String, status: Int, body: String)
    case transport(String, String)
    /// The startup exchange kept failing for the whole retry budget.
    case unreachable(String)
    /// The exchanged session carries no owner uid, so the trust gate can't work.
    case badToken(String)
    /// A response that isn't what PostgREST or the exchange promise.
    case malformed(String)
    /// A write found the card in a different state than the call requires.
    case unexpectedState(card: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case .patRejected(let env):
            "Patch rejected the token in \(env) (revoked or wrong). Mint a new one in Patch Settings -> Tokens."
        case .unauthorized(let env, let request, let status):
            "\(request): \(status) even with a fresh session; check that the owner of the token in \(env) can read and write the roadmap"
        case .unavailable(let request, let status, let body): "\(request): \(status) \(body)"
        case .transport(let url, let detail): "\(url): \(detail)"
        case .unreachable(let detail): "Patch is unreachable: \(detail)"
        case .badToken(let detail): "Patch pat-exchange returned an unusable session: \(detail)"
        case .malformed(let detail): "Patch returned malformed data: \(detail)"
        case .unexpectedState(let card, let expected, let actual):
            "\(card) has status \"\(actual)\", expected \"\(expected)\""
        }
    }
}

/// PostgREST access as the PAT owner. Exchanges the PAT for a short-lived owner JWT on first
/// use, re-exchanges 60 s before expiry and once on a 401, so a revoked PAT stops working
/// within one session lifetime. Constructing it does no I/O.
actor PatchClient {
    static let pageSize = 1000
    static let retryBase = 10.0
    static let retryCap = 120.0

    let apiBase: URL
    let anonKey: String
    let tokenEnv: String
    private let pat: String
    private let log: LogSink
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Double) async throws -> Void

    private var session: (token: String, owner: String, expires: Date)?

    init(
        apiBase: URL, anonKey: String, tokenEnv: String, pat: String, log: LogSink,
        transport: @escaping HTTPTransport = urlSessionTransport,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.apiBase = apiBase
        self.anonKey = anonKey
        self.tokenEnv = tokenEnv
        self.pat = pat
        self.log = log
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    /// The PAT owner's uid, exchanging the PAT first if needed.
    func owner() async throws -> String { try await ensureSession().owner }

    /// The startup exchange: waits out a transient backend (5xx, connection errors) with backoff
    /// from 10 s doubling to 120 s, for up to `budget` seconds, then throws `.unreachable`.
    /// A rejected PAT throws `.patRejected` at once.
    func connect(budget: Double = 600) async throws {
        var elapsed = 0.0
        var delay = Self.retryBase
        while true {
            do {
                _ = try await ensureSession()
                return
            } catch let e as PatchError {
                switch e {
                case .unavailable, .transport: break
                default: throw e
                }
                guard elapsed < budget else {
                    throw PatchError.unreachable("\(e) (still failing after \(Int(elapsed)) s of retries)")
                }
                let wait = min(delay, budget - elapsed)
                log.warning("Patch pat-exchange failed (\(e)); retrying in \(Int(wait)) s")
                try await sleep(wait)
                elapsed += wait
                delay = min(delay * 2, Self.retryCap)
            }
        }
    }

    private func ensureSession(force: Bool = false) async throws -> (token: String, owner: String, expires: Date) {
        if !force, let s = session, now() < s.expires.addingTimeInterval(-60) { return s }
        let url = apiBase.appending(path: "functions/v1/pat-exchange")
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["token": pat])
        let (data, resp) = try await send(req, label: "POST /functions/v1/pat-exchange")
        switch resp.statusCode {
        case 200..<300: break
        case 401, 403: throw PatchError.patRejected(tokenEnv: tokenEnv)
        case 408, 429, 500...:
            throw PatchError.unavailable(request: "POST /functions/v1/pat-exchange", status: resp.statusCode, body: Self.excerpt(data))
        default:
            // Not a BackendRejection: that would turn every card being finished into a stuck one.
            throw PatchError.malformed("POST /functions/v1/pat-exchange: \(resp.statusCode) \(Self.excerpt(data))")
        }
        guard let body = try? JSONDecoder().decode(JSON.self, from: data), let token = body["access_token"]?.string else {
            throw PatchError.badToken("no access_token in the response")
        }
        // The owner is decoded before the session is cached, so a bad token never becomes usable.
        let claims = try Self.claims(of: token)
        guard let owner = claims["sub"]?.string else { throw PatchError.badToken("the JWT has no sub claim") }
        let exp = body["expires_at"]?.double ?? claims["exp"]?.double ?? 0
        let s = (token: token, owner: owner, expires: Date(timeIntervalSince1970: exp))
        session = s
        return s
    }

    /// The payload of a JWT, unverified: the token is our own session, just issued by the exchange.
    static func claims(of jwt: String) throws -> JSON {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw PatchError.badToken("not a JWT") }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let claims = try? JSONDecoder().decode(JSON.self, from: data),
              case .object = claims
        else { throw PatchError.badToken("the JWT payload is not a JSON object") }
        return claims
    }

    // MARK: PostgREST

    /// Every row matching `query`, paging with `limit`/`offset` until the exact count from
    /// `Content-Range` is reached (or an empty page when the server gives no count), so a
    /// `max-rows` cap smaller than the page size can't truncate the result. `query` must
    /// include an `order` so pages are stable.
    func getAll(_ table: String, _ query: [URLQueryItem]) async throws -> [JSON] {
        var rows: [JSON] = []
        while true {
            let page = query + [URLQueryItem(name: "limit", value: "\(Self.pageSize)"),
                                URLQueryItem(name: "offset", value: "\(rows.count)")]
            let (data, resp) = try await rest("GET", table, page, body: nil, prefer: "count=exact")
            let got = try Self.decodeRows(data, label: "GET \(table)")
            rows += got
            if got.isEmpty { return rows }
            if let total = Self.total(resp), rows.count >= total { return rows }
        }
    }

    /// PATCHes the rows matching `query` and returns the changed rows.
    func patch(_ table: String, _ query: [URLQueryItem], _ body: JSON) async throws -> [JSON] {
        let (data, _) = try await rest("PATCH", table, query, body: body, prefer: "return=representation")
        return try Self.decodeRows(data, label: "PATCH \(table)")
    }

    func insert(_ table: String, _ body: JSON) async throws {
        _ = try await rest("POST", table, [], body: body, prefer: "return=minimal")
    }

    private func rest(_ method: String, _ table: String, _ query: [URLQueryItem], body: JSON?, prefer: String) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents(url: apiBase.appending(path: "rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = query.isEmpty ? nil : query
        let label = "\(method) /rest/v1/\(table)"
        var req = URLRequest(url: comps.url!, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(prefer, forHTTPHeaderField: "Prefer")
        if let body { req.httpBody = try JSONEncoder().encode(body) }

        req.setValue("Bearer \(try await ensureSession().token)", forHTTPHeaderField: "Authorization")
        var (data, resp) = try await send(req, label: label)
        if resp.statusCode == 401 {
            req.setValue("Bearer \(try await ensureSession(force: true).token)", forHTTPHeaderField: "Authorization")
            (data, resp) = try await send(req, label: label)
        }
        try Self.check(resp, data, label: label, tokenEnv: tokenEnv)
        return (data, resp)
    }

    private func send(_ req: URLRequest, label: String) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport(req) }
        catch let e as PatchError { throw e }
        catch { throw PatchError.transport(label, error.localizedDescription) }
    }

    static func check(_ resp: HTTPURLResponse, _ data: Data, label: String, tokenEnv: String) throws {
        let status = resp.statusCode
        guard !(200..<300).contains(status) else { return }
        let excerpt = excerpt(data)
        switch status {
        case 401, 403: throw PatchError.unauthorized(tokenEnv: tokenEnv, request: label, status: status)
        case 408, 429, 500...: throw PatchError.unavailable(request: label, status: status, body: excerpt)
        default: throw BackendRejection("\(label): \(status) \(excerpt)")
        }
    }

    static func excerpt(_ data: Data) -> String { String(decoding: data.prefix(300), as: UTF8.self) }

    static func decodeRows(_ data: Data, label: String) throws -> [JSON] {
        guard case .array(let rows)? = try? JSONDecoder().decode(JSON.self, from: data) else {
            throw PatchError.malformed("\(label) did not return a JSON array")
        }
        return rows
    }

    /// The total from `Content-Range: 0-999/1234`; nil for `*/*` or a missing header.
    static func total(_ resp: HTTPURLResponse) -> Int? {
        resp.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int($0) }
    }
}
