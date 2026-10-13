import Foundation
import LoopWorkerCore
@testable import PatchBackend
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An in-memory Patch deployment: the PAT exchange plus a PostgREST subset (eq., is.null,
/// in.() filters, limit/offset with a max-rows cap, return=representation).
final class FakePatch: @unchecked Sendable {
    static let owner = "owner-uid"
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var rows: [String: [[String: JSON]]] = ["roadmap": [], "patch_blocks": []]
    /// Answers for the next exchanges, in order; afterwards each exchange succeeds.
    var exchangeQueue: [Result<(Int, JSON), URLError>] = []
    /// Status codes for the next REST requests per HTTP method, in order; afterwards PostgREST answers normally.
    var restStatus: [String: [Int]] = [:]
    var maxRows = 1000
    var tokenLifetime: TimeInterval = 3600
    var clock = Date(timeIntervalSince1970: 1_000_000)
    /// Runs before a PATCH is applied, e.g. to let a competing writer win a race.
    var beforePatch: (() -> Void)?

    var requests: [URLRequest] { lock.withLock { _requests } }
    func requests(_ method: String, _ path: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == method && $0.url?.path == path }
    }
    var exchanges: Int { requests("POST", "/functions/v1/pat-exchange").count }

    static func jwt(_ claims: JSON) -> String {
        let payload = try! JSONEncoder().encode(claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(payload).FAKE-signature"
    }

    var transport: HTTPTransport {
        { [self] req in
            let result = lock.withLock { () -> Result<(Int, [String: String], Data), URLError> in
                _requests.append(req)
                return handle(req)
            }
            let (status, headers, body) = try result.get()
            return (body, HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    private func handle(_ req: URLRequest) -> Result<(Int, [String: String], Data), URLError> {
        let path = req.url!.path
        if path == "/functions/v1/pat-exchange" {
            let next = exchangeQueue.isEmpty
                ? .success((200, .object([
                    "access_token": .string(Self.jwt(.object(["sub": .string(Self.owner)]))),
                    "expires_at": .number(clock.timeIntervalSince1970 + tokenLifetime),
                ])))
                : exchangeQueue.removeFirst()
            return next.map { (status, body) in (status, [:], try! JSONEncoder().encode(body)) }
        }
        if let status = restStatus[req.httpMethod!]?.first {
            restStatus[req.httpMethod!]!.removeFirst()
            return .success((status, [:], Data("{\"message\":\"fake\"}".utf8)))
        }
        let table = String(path.dropFirst("/rest/v1/".count))
        let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let filters = query.filter { !["select", "order", "limit", "offset"].contains($0.name) }
        let matches = { (row: [String: JSON]) in filters.allSatisfy { Self.matches(row, $0) } }
        switch req.httpMethod {
        case "GET":
            let all = (rows[table] ?? []).filter(matches)
            let offset = Int(query.first { $0.name == "offset" }?.value ?? "0")!
            let limit = min(Int(query.first { $0.name == "limit" }?.value ?? "1000")!, maxRows)
            let page = Array(all.dropFirst(offset).prefix(limit))
            let range = page.isEmpty ? "*/\(all.count)" : "\(offset)-\(offset + page.count - 1)/\(all.count)"
            return .success((200, ["Content-Range": range], try! JSONEncoder().encode(page)))
        case "PATCH":
            beforePatch?()
            guard case .object(let fields) = try! JSONDecoder().decode(JSON.self, from: req.httpBody!) else { fatalError() }
            var changed: [[String: JSON]] = []
            for i in rows[table, default: []].indices where matches(rows[table]![i]) {
                rows[table]![i].merge(fields) { $1 }
                changed.append(rows[table]![i])
            }
            return .success((200, [:], try! JSONEncoder().encode(changed)))
        case "POST":
            guard case .object(var row) = try! JSONDecoder().decode(JSON.self, from: req.httpBody!) else { fatalError() }
            row["id"] = .string("block-\(rows[table, default: []].count + 1)")
            rows[table, default: []].append(row)
            return .success((201, [:], Data()))
        default: fatalError("unexpected \(req.httpMethod ?? "")")
        }
    }

    private static func matches(_ row: [String: JSON], _ filter: URLQueryItem) -> Bool {
        var cell = row[filter.name]
        if filter.name.contains("->>") {
            let parts = filter.name.components(separatedBy: "->>")
            cell = row[parts[0]]?[parts[1]]
        }
        let value = filter.value ?? ""
        let text: String? = switch cell {
        case .string(let s)?: s
        case .number(let n)?: n == n.rounded() ? "\(Int(n))" : "\(n)"
        default: nil
        }
        if value == "is.null" { return cell == nil || cell == .null }
        if value.hasPrefix("eq.") { return text == String(value.dropFirst(3)) }
        if value.hasPrefix("in.(") {
            return text.map { value.dropFirst(4).dropLast().split(separator: ",").map(String.init).contains($0) } ?? false
        }
        fatalError("unsupported filter \(filter)")
    }
}

final class LogRecorder: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func log(_ level: LogLevel, _ message: String) { lock.withLock { _lines.append(message) } }
}

func card(_ number: Int, status: String? = "Backlog", project: JSON = .string("proj-app"), _ extra: [String: JSON] = [:]) -> [String: JSON] {
    var row: [String: JSON] = [
        "id": .string("u\(number)"), "id_2": .number(Double(number)), "title": .string("card \(number)"),
        "status": status.map(JSON.string) ?? .null, "priority": .number(Double(number)), "area": .array([]),
        "blocked_by": .null, "assignee": .null, "project": project, "created_by": .string(FakePatch.owner),
    ]
    row.merge(extra) { $1 }
    return row
}
