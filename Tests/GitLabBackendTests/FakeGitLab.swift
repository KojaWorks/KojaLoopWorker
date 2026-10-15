import Foundation
import LoopWorkerCore
@testable import GitLabBackend

/// An in-memory GitLab: answers stubbed requests and records every request it sees.
/// The most recently added matching stub wins; a stub with several responses serves them in
/// order and then repeats its last one. An unstubbed request gets a 418 and is recorded.
final class FakeGitLab: HTTPTransport, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String]
    }
    struct Request {
        var method: String
        /// Percent-encoded, e.g. `/api/v4/projects/mygroup%2Fapp`.
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data?

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] ?? [:] }
        var bodyText: String { String(decoding: body ?? Data(), as: UTF8.self) }
    }
    private struct Stub {
        var method: String
        var path: String
        var query: [String: String]
        var bodyContains: String?
        var responses: [Response]
    }

    private let lock = NSLock()
    private var stubs: [Stub] = []
    private var recorded: [Request] = []

    var requests: [Request] { lock.withLock { recorded } }
    func requests(_ method: String, _ path: String) -> [Request] {
        requests.filter { $0.method == method && $0.path == path }
    }

    /// Stubs `method path`. `query` must be a subset of the request's query; `bodyContains`
    /// a substring of its body.
    func on(_ method: String, _ path: String, query: [String: String] = [:], bodyContains: String? = nil,
            status: Int = 200, json: Any, headers: [String: String] = [:]) {
        on(method, path, query: query, bodyContains: bodyContains, responses: [Self.response(status, json, headers)])
    }

    func on(_ method: String, _ path: String, query: [String: String] = [:], bodyContains: String? = nil, responses: [Response]) {
        lock.withLock { stubs.append(Stub(method: method, path: path, query: query, bodyContains: bodyContains, responses: responses)) }
    }

    static func response(_ status: Int, _ json: Any, _ headers: [String: String] = [:]) -> Response {
        Response(status: status, body: try! JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]), headers: headers)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var query: [String: String] = [:]
        for item in c.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let req = Request(
            method: request.httpMethod ?? "GET", path: c.percentEncodedPath, query: query,
            headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody)
        let response: Response = lock.withLock {
            recorded.append(req)
            guard let i = stubs.lastIndex(where: { s in
                s.method == req.method && s.path == req.path
                    && s.query.allSatisfy { query[$0.key] == $0.value }
                    && (s.bodyContains.map { req.bodyText.contains($0) } ?? true)
            }) else {
                return Self.response(418, ["message": "no stub for \(req.method) \(req.path) \(query)"])
            }
            let r = stubs[i].responses[0]
            if stubs[i].responses.count > 1 { stubs[i].responses.removeFirst() }
            return r
        }
        return (response.body, HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!)
    }
}

final class CollectingLog: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [(LogLevel, String)] = []
    var lines: [String] { lock.withLock { collected.map(\.1) } }
    var errors: [String] { lock.withLock { collected.filter { $0.0 == .error }.map(\.1) } }
    func log(_ level: LogLevel, _ message: String) { lock.withLock { collected.append((level, message)) } }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    var durations: [Duration] { lock.withLock { recorded } }
    func sleep(_ d: Duration) { lock.withLock { recorded.append(d) } }
}

/// Fabricated GitLab data. The token's user is `me` (id 1); `mallory` (id 2) is anyone else.
enum Fixture {
    static let token = "glpat-FAKEFAKEFAKEFAKEFAKE"
    static var me: [String: Any] { ["id": 1, "username": "me"] }
    static var mallory: [String: Any] { ["id": 2, "username": "mallory"] }
    static let projectID = 7
    static let projectPath = "mygroup/app"
    static let issuePath = "/api/v4/projects/7/issues/12"

    static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    static func gid(_ user: [String: Any]) -> [String: Any] {
        ["id": "gid://gitlab/User/\(user["id"]!)", "username": user["username"]!]
    }

    /// Minutes after 2026-10-01T10:00:00Z.
    static func t(_ minutes: Int) -> String {
        GitLabTime.format(Date(timeIntervalSince1970: 1_790_157_600 + Double(minutes) * 60))
    }
    static func date(_ minutes: Int) -> Date { GitLabTime.parse(t(minutes))! }

    static func issue(
        iid: Int = 12, projectID: Int = projectID, labels: [String] = ["loopworker::next"],
        assignees: [[String: Any]] = [me], author: [String: Any] = me, created: Int = 0,
        state: String = "opened", title: String = "Fix it", movedTo: Int? = nil
    ) -> [String: Any] {
        var i: [String: Any] = [
            "id": 9000 + iid, "iid": iid, "project_id": projectID, "title": title, "description": "Do the thing",
            "state": state, "labels": labels, "assignees": assignees, "author": author, "created_at": t(created),
            "web_url": "https://gitlab.example.com/\(projectPath)/-/issues/\(iid)",
        ]
        if let movedTo { i["moved_to_id"] = movedTo }
        return i
    }

    static func note(_ id: Int, _ body: String, by author: [String: Any] = me, at minutes: Int, system: Bool = false) -> [String: Any] {
        ["id": id, "body": body, "author": author, "created_at": t(minutes), "system": system]
    }

    static func assigned(by author: [String: Any] = me, at minutes: Int = 1, id: Int = 100) -> [String: Any] {
        note(id, "assigned to @me", by: author, at: minutes, system: true)
    }

    static func labelEvent(_ id: Int, _ label: String = "loopworker::next", by user: [String: Any] = me, at minutes: Int, action: String = "add") -> [String: Any] {
        ["id": id, "user": user, "created_at": t(minutes), "label": ["id": 50, "name": label], "action": action, "resource_type": "Issue", "resource_id": 9012]
    }

    static func gqlNote(_ id: Int, _ body: String, by author: [String: Any], at minutes: Int, editedBy: [String: Any]? = nil, editedAt: Int? = nil, system: Bool = false) -> [String: Any] {
        [
            "id": "gid://gitlab/Note/\(id)", "body": body, "system": system, "createdAt": t(minutes),
            "lastEditedAt": orNull(editedAt.map { t($0) }), "lastEditedBy": orNull(editedBy.map(gid)),
            "author": gid(author),
        ]
    }

    static func gqlIssue(
        title: String = "Fix it", description: String = "Do the thing",
        editedBy: [String: Any]? = nil, editedAt: Int? = nil, notes: [[String: Any]] = [],
        hasNextPage: Bool = false, endCursor: String? = nil
    ) -> [String: Any] {
        ["data": [
            "namespace": ["workItem": [
                "title": title,
                "widgets": [
                    ["__typename": "WorkItemWidgetAssignees"],
                    [
                        "__typename": "WorkItemWidgetDescription", "description": description,
                        "lastEditedAt": orNull(editedAt.map { t($0) }), "lastEditedBy": orNull(editedBy.map(gid)),
                    ],
                ],
            ] as [String: Any]],
            "project": ["issue": [
                "notes": ["pageInfo": ["hasNextPage": hasNextPage, "endCursor": orNull(endCursor)], "nodes": notes],
            ]],
        ] as [String: Any]]
    }
}

/// The holder id that tests claim as.
let testHolder = "buildmac.local:/Users/x/.loopworker"
