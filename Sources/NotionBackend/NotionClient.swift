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
        throw NotionError.transport(request.url?.absoluteString ?? "?", "not an HTTP response")
    }
    return (data, http)
}

/// Failures of the Notion backlog other than `BackendRejection`.
public enum NotionError: Error, CustomStringConvertible, Equatable {
    /// Notion answered 401: the token in the named variable is revoked or wrong.
    case unauthorized(tokenEnv: String, request: String)
    /// The token belongs to a person, not an integration (B188).
    case personToken(tokenEnv: String, name: String)
    /// Notion answered 403 outside a database or data source read: the integration lacks a capability.
    case forbidden(tokenEnv: String, request: String, message: String)
    /// A database or data source answered 403 or 404: the integration isn't connected to it.
    case notConnected(database: String, request: String)
    /// A database with no data source or several.
    case dataSources(database: String, found: [String])
    /// Notion didn't answer usefully (5xx, 408, or 429 after every retry); a later tick may succeed.
    case unavailable(request: String, status: Int, body: String)
    case transport(String, String)
    /// A query that Notion cut off (`request_status`), so its result is partial.
    case incomplete(request: String, reason: String)
    /// A response that isn't what the API promises.
    case malformed(String)
    /// A write found the card in a different state than the call requires.
    case unexpectedState(card: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case .unauthorized(let env, let request):
            "\(request): 401. Notion rejected the token in \(env) (revoked or wrong); put an internal integration's secret in secrets.env"
        case .personToken(let env, let name):
            "the token in \(env) belongs to the person \(name), not an integration. LoopWorker refuses it because the Manager's writes would look like that person's edits; put an internal integration's secret in \(env)"
        case .forbidden(let env, let request, let message):
            "\(request): 403 \(message). Give the integration in \(env) the capabilities read, update and insert content; read and insert comments; read user information"
        case .notConnected(let database, let request):
            "\(request): the integration can't read database \(database). Open the database in Notion, choose ••• -> Connections (Add connections) and add the integration"
        case .dataSources(let database, let found):
            "database \(database) has \(found.isEmpty ? "no data source" : "\(found.count) data sources (\(found.joined(separator: ", ")))"); LoopWorker needs exactly one"
        case .unavailable(let request, let status, let body): "\(request): \(status) \(body)"
        case .transport(let request, let detail): "\(request): \(detail)"
        case .incomplete(let request, let reason): "\(request): Notion returned an incomplete result (\(reason))"
        case .malformed(let detail): "Notion returned malformed data: \(detail)"
        case .unexpectedState(let card, let expected, let actual): "\(card) is \(actual), expected \(expected)"
        }
    }
}

/// A Sendable JSON value; the API's objects are read through it.
enum JSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// A non-empty string value.
    var string: String? {
        if case .string(let s) = self, !s.isEmpty { return s }
        return nil
    }

    var double: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var array: [JSON] {
        if case .array(let a) = self { return a }
        return []
    }

    var object: [String: JSON] {
        if case .object(let o) = self { return o }
        return [:]
    }
}

/// The Notion REST API as one internal integration. Sends at most 3 requests per second,
/// waits out 429s, and times every request out after 30 s (B193). Constructing it does no I/O.
actor NotionClient {
    static let version = "2026-03-11"
    static let base = URL(string: "https://api.notion.com/v1")!
    static let pageSize = 100
    static let spacing = 1.0 / 3
    static let maxRetries = 3

    /// What a 403 or 404 means for one request.
    enum Missing {
        /// 404 is a `BackendRejection`, 403 a missing capability.
        case reject
        /// 404 returns nil.
        case none
        /// The request reads this database or one of its data sources: 403 and 404 mean that
        /// the integration isn't connected to it.
        case database(String)
    }

    let tokenEnv: String
    private let token: String
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Double) async throws -> Void
    private var nextSlot = Date.distantPast
    private var cachedMe: JSON?

    init(
        tokenEnv: String, token: String, transport: @escaping HTTPTransport,
        now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Double) async throws -> Void
    ) {
        self.tokenEnv = tokenEnv
        self.token = token
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    /// The integration's own bot user, read once (B188). Throws `.personToken` for a person's token.
    func me() async throws -> JSON {
        if let cachedMe { return cachedMe }
        guard let user = try await request("GET", "users/me") else { throw NotionError.malformed("GET /v1/users/me: empty") }
        guard user["type"]?.string == "bot" else {
            throw NotionError.personToken(tokenEnv: tokenEnv, name: user["name"]?.string ?? user["id"]?.string ?? "?")
        }
        cachedMe = user
        return user
    }

    /// Every result of a paginated endpoint, following `next_cursor` with `page_size` 100 (B192).
    /// GET sends the cursor in the query, POST in the body. A failed page throws, and so does a
    /// page whose `request_status` says the result is incomplete.
    func list(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: JSON] = [:], missing: Missing = .reject) async throws -> [JSON] {
        var results: [JSON] = []
        var cursor: String?
        repeat {
            var q = query
            var b = body
            if method == "GET" {
                q.append(URLQueryItem(name: "page_size", value: "\(Self.pageSize)"))
                if let cursor { q.append(URLQueryItem(name: "start_cursor", value: cursor)) }
            } else {
                b["page_size"] = .number(Double(Self.pageSize))
                if let cursor { b["start_cursor"] = .string(cursor) }
            }
            guard let page = try await request(method, path, query: q, body: method == "GET" ? nil : .object(b), missing: missing) else {
                throw NotionError.malformed("\(method) /v1/\(path): empty")
            }
            if let status = page["request_status"], status["type"]?.string == "incomplete" || status["incomplete_reason"]?.string != nil {
                throw NotionError.incomplete(request: "\(method) /v1/\(path)", reason: status["incomplete_reason"]?.string ?? "incomplete")
            }
            guard case .array(let got)? = page["results"] else {
                throw NotionError.malformed("\(method) /v1/\(path): no results array")
            }
            results += got
            cursor = page["has_more"]?.bool == true ? page["next_cursor"]?.string : nil
            if page["has_more"]?.bool == true, cursor == nil {
                throw NotionError.malformed("\(method) /v1/\(path): has_more without next_cursor")
            }
        } while cursor != nil
        return results
    }

    /// One request. Returns the decoded body, or nil for a 404 with `missing: .none`.
    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSON? = nil, missing: Missing = .reject) async throws -> JSON? {
        var comps = URLComponents(url: Self.base.appending(path: path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query.isEmpty ? nil : query
        let label = "\(method) /v1/\(path)"
        var req = URLRequest(url: comps.url!, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.version, forHTTPHeaderField: "Notion-Version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }

        var attempt = 0
        while true {
            try await waitForSlot()
            let data: Data, resp: HTTPURLResponse
            do { (data, resp) = try await transport(req) }
            catch let e as NotionError { throw e }
            catch { throw NotionError.transport(label, error.localizedDescription) }
            let status = resp.statusCode
            let json = try? JSONDecoder().decode(JSON.self, from: data)
            switch status {
            case 200..<300:
                guard let json else { throw NotionError.malformed("\(label): the body is not JSON") }
                return json
            case 401: throw NotionError.unauthorized(tokenEnv: tokenEnv, request: label)
            case 429:
                guard attempt < Self.maxRetries else {
                    throw NotionError.unavailable(request: label, status: status, body: Self.excerpt(data))
                }
                attempt += 1
                let wait = Self.retryAfter(resp, json) ?? Double(1 << attempt)
                nextSlot = max(nextSlot, now().addingTimeInterval(wait))
            case 403, 404:
                switch missing {
                case .database(let id): throw NotionError.notConnected(database: id, request: label)
                case .none where status == 404: return nil
                default:
                    if status == 403 { throw NotionError.forbidden(tokenEnv: tokenEnv, request: label, message: Self.message(json, data)) }
                    throw BackendRejection("\(label): 404 \(Self.message(json, data))")
                }
            case 408, 500...: throw NotionError.unavailable(request: label, status: status, body: Self.excerpt(data))
            case 400..<500: throw BackendRejection("\(label): \(status) \(Self.message(json, data))")
            default: throw NotionError.unavailable(request: label, status: status, body: Self.excerpt(data))
            }
        }
    }

    /// Spaces requests at least 1/3 s apart. The slot is taken before the await, so
    /// concurrent callers queue up instead of all waking at once.
    private func waitForSlot() async throws {
        let t = now()
        let at = max(t, nextSlot)
        nextSlot = at.addingTimeInterval(Self.spacing)
        if at > t { try await sleep(at.timeIntervalSince(t)) }
    }

    /// `Retry-After`, else the body's `additional_data.retry_after`, in seconds.
    static func retryAfter(_ resp: HTTPURLResponse, _ json: JSON?) -> Double? {
        if let h = resp.value(forHTTPHeaderField: "Retry-After"), let s = Double(h.trimmingCharacters(in: .whitespaces)) { return s }
        switch json?["additional_data"]?["retry_after"] {
        case .string(let s)?: return Double(s)
        case .number(let n)?: return n
        default: return nil
        }
    }

    static func message(_ json: JSON?, _ data: Data) -> String {
        guard let json, let message = json["message"]?.string else { return excerpt(data) }
        return json["code"]?.string.map { "\($0): \(message)" } ?? message
    }

    static func excerpt(_ data: Data) -> String {
        let text = String(decoding: data.prefix(300), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
        return text.count > 200 ? String(text.prefix(200)) + "..." : text
    }
}
