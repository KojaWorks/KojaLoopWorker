import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LoopWorkerCore

/// Sends one HTTP request. `URLSession` in production, a stub in tests.
protocol HTTPTransport: Sendable {
    /// Returns the response for any HTTP status; throws only when no response arrived.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    var session: URLSession = .shared

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// A GitLab request that failed in a way a retry on a later tick may fix, or that needs an
/// operator. Deterministic refusals are `BackendRejection` instead.
public struct GitLabError: Error, CustomStringConvertible, Equatable {
    public var description: String
    init(_ description: String) { self.description = description }
}

/// REST v4 and GraphQL client for one GitLab instance and token.
///
/// Every list read follows pagination to the end or throws. 429 is retried for every request,
/// 5xx only for idempotent ones (a retried POST could post a note twice). 401 and 403 fail
/// at once with an error that names the token variable.
actor GitLabClient {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    let connection: GitLabConnection
    private let transport: any HTTPTransport
    private let sleep: Sleep
    private var cachedMe: GLUser?
    private var projectsByID: [Int: GLProject] = [:]

    static let maxRetries = 3
    static let requestTimeout: TimeInterval = 30

    init(connection: GitLabConnection, transport: any HTTPTransport, sleep: @escaping Sleep) {
        self.connection = connection
        self.transport = transport
        self.sleep = sleep
    }

    /// The token's user, read once per process.
    func me() async throws -> GLUser {
        if let cachedMe { return cachedMe }
        let user: GLUser = try await get("/user")
        cachedMe = user
        return user
    }

    /// A project by numeric id, cached for the process lifetime; nil when it doesn't exist.
    func project(id: Int) async throws -> GLProject? {
        if let p = projectsByID[id] { return p }
        guard let p: GLProject = try await getIfFound("/projects/\(id)") else { return nil }
        projectsByID[id] = p
        return p
    }

    func get<T: Decodable>(_ path: String, query: [(String, String)] = []) async throws -> T {
        let (data, _) = try await perform("GET", path, query: query)
        return try decode(data, "GET", path)
    }

    /// Like `get`, but a 404 is nil.
    func getIfFound<T: Decodable>(_ path: String, query: [(String, String)] = []) async throws -> T? {
        let (data, response) = try await perform("GET", path, query: query, allowNotFound: true)
        if response.statusCode == 404 { return nil }
        return try decode(data, "GET", path)
    }

    /// A plain-text body, such as a job trace; nil on 404.
    func textIfFound(_ path: String) async throws -> String? {
        let (data, response) = try await perform("GET", path, allowNotFound: true)
        return response.statusCode == 404 ? nil : String(decoding: data, as: UTF8.self)
    }

    /// Every page of a list endpoint, 100 per page.
    func getAll<T: Decodable>(_ path: String, query: [(String, String)] = []) async throws -> [T] {
        var all: [T] = []
        var url = try apiURL(path, query: query + [("per_page", "100")])
        while true {
            let (data, response) = try await perform("GET", url: url, label: path)
            let page: [T] = try decode(data, "GET", path)
            all += page
            guard let next = nextPage(after: url, response: response) else { return all }
            url = next
        }
    }

    /// Sends a JSON body. `idempotent` allows retrying 5xx.
    func send<T: Decodable>(_ method: String, _ path: String, body: [String: String], idempotent: Bool) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (out, _) = try await perform(method, path, body: data, contentType: "application/json", idempotent: idempotent)
        return try decode(out, method, path)
    }

    func upload(_ path: String, file: URL) async throws -> GLUpload {
        let content: Data
        do { content = try Data(contentsOf: file) }
        catch { throw GitLabError("can't read \(file.path) to upload it: \(error.localizedDescription)") }
        let boundary = "loopworker-\(UUID().uuidString)"
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body += content
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        let (out, _) = try await perform(
            "POST", path, body: body, contentType: "multipart/form-data; boundary=\(boundary)", idempotent: false)
        return try decode(out, "POST", path)
    }

    /// Runs a GraphQL operation and returns its `data`. Top-level `errors` throw.
    func graphQL<T: Decodable>(_ operation: String, _ query: String, variables: [String: String], idempotent: Bool = true) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables], options: [.sortedKeys])
        guard let url = URL(string: connection.baseURL.absoluteString + "/api/graphql") else {
            throw GitLabError("can't build the GraphQL URL from \(connection.baseURL)")
        }
        let label = "graphql \(operation)"
        let (data, _) = try await perform(
            "POST", url: url, label: label, body: body, contentType: "application/json", idempotent: idempotent, bearer: true)
        let envelope: GraphQLEnvelope<T> = try decode(data, "POST", label)
        if let errors = envelope.errors, !errors.isEmpty {
            throw GitLabError("POST \(label): \(errors.map(\.message).joined(separator: "; "))")
        }
        guard let result = envelope.data else { throw GitLabError("POST \(label): response has no data") }
        return result
    }

    // MARK: - Transport

    private func perform(
        _ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil,
        contentType: String? = nil, idempotent: Bool? = nil, allowNotFound: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        try await perform(
            method, url: try apiURL(path, query: query), label: path, body: body, contentType: contentType,
            idempotent: idempotent, allowNotFound: allowNotFound)
    }

    private func perform(
        _ method: String, url: URL, label: String, body: Data? = nil, contentType: String? = nil,
        idempotent: Bool? = nil, allowNotFound: Bool = false, bearer: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        let retriesServerErrors = idempotent ?? (method == "GET" || method == "PUT")
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = method
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        // Bearer, not PRIVATE-TOKEN: GitLab accepts personal access tokens and OAuth tokens there.
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let where_ = "\(method) \(label)"

        var attempt = 0
        while true {
            let data: Data, response: HTTPURLResponse
            do { (data, response) = try await transport.send(request) }
            catch { throw GitLabError("\(where_): no response from \(connection.baseURL.host() ?? "GitLab"): \(error.localizedDescription)") }
            let status = response.statusCode
            let excerpt = Self.excerpt(data)
            switch status {
            case 200..<300:
                return (data, response)
            case 404 where allowNotFound:
                return (data, response)
            case 401, 403:
                throw GitLabError("\(where_): \(status) \(excerpt). The token in \(connection.tokenEnv) is invalid, expired or lacks the api scope.")
            case 429, 500...599:
                let retryable = status == 429 || retriesServerErrors
                guard retryable, attempt < Self.maxRetries else {
                    throw GitLabError("\(where_): \(status) \(excerpt)")
                }
                attempt += 1
                try await sleep(Self.retryDelay(response, attempt: attempt))
            case 408:
                throw GitLabError("\(where_): \(status) \(excerpt)")
            case 400..<500:
                throw BackendRejection("\(where_): \(status) \(excerpt)")
            default:
                throw GitLabError("\(where_): unexpected \(status) \(excerpt)")
            }
        }
    }

    /// `Retry-After` in seconds (capped at 60), else 2, 4, 8 s.
    static func retryDelay(_ response: HTTPURLResponse, attempt: Int) -> Duration {
        if let value = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Int(value.trimmingCharacters(in: .whitespaces)) {
            return .seconds(min(max(seconds, 0), 60))
        }
        return .seconds(1 << attempt)
    }

    private static func excerpt(_ data: Data) -> String {
        let text = String(decoding: data.prefix(300), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
        return text.count > 200 ? String(text.prefix(200)) + "..." : text
    }

    private func nextPage(after url: URL, response: HTTPURLResponse) -> URL? {
        if let page = response.value(forHTTPHeaderField: "x-next-page"), !page.isEmpty,
           var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = (c.percentEncodedQueryItems ?? []).filter { $0.name != "page" }
            items.append(URLQueryItem(name: "page", value: GitLabPath.encode(page)))
            c.percentEncodedQueryItems = items
            return c.url
        }
        // Keyset pagination only sends Link. Never follow it to another host with our token.
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close,
                  let next = URL(string: String(part[part.index(after: open)..<close])),
                  next.scheme == url.scheme, next.host() == url.host(), next.port == url.port
            else { return nil }
            return next
        }
        return nil
    }

    private func apiURL(_ path: String, query: [(String, String)]) throws -> URL {
        var string = connection.baseURL.absoluteString + "/api/v4" + path
        if !query.isEmpty {
            string += "?" + query.map { "\(GitLabPath.encode($0.0))=\(GitLabPath.encode($0.1))" }.joined(separator: "&")
        }
        guard let url = URL(string: string) else { throw GitLabError("can't build a URL from \(path)") }
        return url
    }

    private func decode<T: Decodable>(_ data: Data, _ method: String, _ path: String) throws -> T {
        do { return try GitLabJSON.decoder.decode(T.self, from: data) }
        catch { throw GitLabError("\(method) \(path): unexpected response shape: \(error)") }
    }
}

enum GitLabPath {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything but RFC 3986 unreserved characters, so `group/app` becomes
    /// `group%2Fapp` as GitLab's `:id` path parameter expects.
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}

enum GitLabTime {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func parse(_ s: String) -> Date? {
        (try? fractional.parse(s)) ?? (try? whole.parse(s))
    }

    static func format(_ date: Date) -> String { fractional.format(date) }
}

enum GitLabJSON {
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = GitLabTime.parse(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 time: \(s)"))
            }
            return date
        }
        return d
    }
}

private struct GraphQLEnvelope<T: Decodable>: Decodable {
    struct Message: Decodable { var message: String }
    var data: T?
    var errors: [Message]?
}
