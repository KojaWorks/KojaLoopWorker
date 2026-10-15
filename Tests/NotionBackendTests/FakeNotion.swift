import Foundation
import LoopWorkerCore
@testable import NotionBackend
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A fabricated id of the API's dashed form: `id(7, "a")` is `0000000a-0000-4000-8000-000000000007`.
func id(_ n: Int, _ kind: String) -> String {
    let k = String(repeating: "0", count: 8 - kind.count) + kind
    let num = String(n, radix: 16)
    return "\(k)-0000-4000-8000-\(String(repeating: "0", count: 12 - num.count))\(num)"
}

let botID = id(1, "b07")
let alice = id(1, "a")   // trusted
let mallory = id(2, "a") // untrusted
let databaseID = id(1, "d")
let dataSourceID = id(1, "d5")

/// An in-memory Notion workspace: users, one database per entry, pages, block children and
/// comments, with cursor pagination and per-request status injection.
final class FakeNotion: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var users: [String: JSON] = [
        botID: .object(["object": "user", "id": .string(botID), "type": "bot", "name": "LoopWorker",
                        "bot": .object(["workspace_name": "Acme"])]),
        alice: .object(["object": "user", "id": .string(alice), "type": "person", "name": "Alice"]),
        mallory: .object(["object": "user", "id": .string(mallory), "type": "person", "name": "Mallory"]),
    ]
    var meID = botID
    var databases: [String: JSON] = [:]
    var dataSources: [String: JSON] = [:]
    var pages: [String: JSON] = [:]
    var children: [String: [JSON]] = [:]
    var comments: [String: [JSON]] = [:]
    /// Results per page that the fake returns, at most.
    var pageSize = 100
    /// Responses for the next requests to `"METHOD /v1/path"`, in order (nil answers normally);
    /// afterwards the fake answers normally.
    var queued: [String: [(Int, [String: String], JSON)?]] = [:]
    /// Extra fields merged into every query response, e.g. `request_status`.
    var queryExtra: [String: JSON] = [:]
    var clock = Date(timeIntervalSince1970: 2_000_000_000)
    private(set) var nextComment = 1
    /// Runs after a comment is created, e.g. to let a competing Manager post its claim.
    var afterComment: (() -> Void)?

    var requests: [URLRequest] { lock.withLock { _requests } }
    func requests(_ method: String, _ path: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == method && $0.url?.path == path }
    }
    var writes: [URLRequest] { requests.filter { $0.httpMethod != "GET" && !($0.url?.path.hasSuffix("/query") ?? false) } }

    var transport: HTTPTransport {
        { [self] req in
            let (status, headers, body) = lock.withLock { () -> (Int, [String: String], JSON) in
                _requests.append(req)
                return handle(req)
            }
            return (try JSONEncoder().encode(body), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    static func iso(_ d: Date) -> String { d.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) }

    // MARK: Fixtures

    func addDatabase(_ db: String = databaseID, sources: [String] = [dataSourceID], properties: [String: JSON]? = nil) {
        databases[db] = .object(["object": "database", "id": .string(db),
                                 "data_sources": .array(sources.map { .object(["id": .string($0), "name": .string("Source \($0.prefix(4))")]) })])
        for s in sources {
            dataSources[s] = .object(["object": "data_source", "id": .string(s), "properties": .object(properties ?? Self.schema())])
        }
    }

    static func schema(state: [String] = ["next", "working", "ci", "review", "stuck"], extra: [String: JSON] = [:]) -> [String: JSON] {
        var p: [String: JSON] = [
            "Name": .object(["id": "title", "name": "Name", "type": "title", "title": .object([:])]),
            "LoopWorker": .object(["id": "lw", "name": "LoopWorker", "type": "select",
                                   "select": .object(["options": .array(state.map { .object(["id": .string($0), "name": .string($0)]) })])]),
            "Priority": .object(["id": "pr", "name": "Priority", "type": "select",
                                 "select": .object(["options": .array(["P0", "P1", "P2"].map { .object(["name": .string($0)]) })])]),
            "Tags": .object(["id": "tg", "name": "Tags", "type": "multi_select",
                             "multi_select": .object(["options": .array(["urgent", "soon", "later"].map { .object(["name": .string($0)]) })])]),
            "Points": .object(["id": "pt", "name": "Points", "type": "number", "number": .object([:])]),
            "Model": .object(["id": "md", "name": "Model", "type": "select", "select": .object(["options": .array([])])]),
            "ID": .object(["id": "id", "name": "ID", "type": "unique_id", "unique_id": .object(["prefix": "CARD"])]),
        ]
        p.merge(extra) { $1 }
        return p
    }

    /// A card page in `dataSourceID`. `n` picks the id and the unique id number.
    @discardableResult
    func addPage(_ n: Int, state: String? = "next", editor: String = alice, title: String? = nil, created: Int = 0,
                 source: String = dataSourceID, database: String = databaseID, props: [String: JSON] = [:]) -> String {
        let pid = id(n, "c")
        var properties: [String: JSON] = [
            "Name": .object(["id": "title", "type": "title", "title": .array([text(title ?? "card \(n)")])]),
            "LoopWorker": .object(["id": "lw", "type": "select", "select": state.map { .object(["name": .string($0)]) } ?? .null]),
            "ID": .object(["id": "id", "type": "unique_id", "unique_id": .object(["number": .number(Double(n)), "prefix": "CARD"])]),
        ]
        properties.merge(props) { $1 }
        pages[pid] = .object([
            "object": "page", "id": .string(pid), "url": .string("https://www.notion.so/card-\(n)"),
            "created_time": .string(Self.iso(Date(timeIntervalSince1970: 1_900_000_000 + Double(created)))),
            "last_edited_by": .object(["object": "user", "id": .string(editor)]),
            "in_trash": false,
            "parent": .object(["type": "data_source_id", "data_source_id": .string(source), "database_id": .string(database)]),
            "properties": .object(properties),
        ])
        return pid
    }

    func text(_ s: String, link: String? = nil, _ annotations: [String: JSON] = [:]) -> JSON {
        var t: [String: JSON] = ["content": .string(s)]
        if let link { t["link"] = .object(["url": .string(link)]) }
        return .object(["type": "text", "text": .object(t), "plain_text": .string(s), "href": link.map(JSON.string) ?? .null,
                        "annotations": .object(annotations)])
    }

    func addComment(_ page: String, by author: String, _ body: String) {
        appendComment(page, author: author, richText: [text(body)])
    }

    @discardableResult
    private func appendComment(_ page: String, author: String, richText: [JSON]) -> JSON {
        clock = clock.addingTimeInterval(1)
        let c: JSON = .object([
            "object": "comment", "id": .string(id(nextComment, "cc")),
            "created_by": .object(["object": "user", "id": .string(author)]),
            "created_time": .string(Self.iso(clock)), "rich_text": .array(richText),
        ])
        nextComment += 1
        comments[page, default: []].append(c)
        return c
    }

    func addBlock(_ parent: String, _ n: Int, type: String, editor: String = alice, _ content: [String: JSON] = [:], hasChildren: Bool = false) -> String {
        let bid = id(n, "bb")
        children[parent, default: []].append(.object([
            "object": "block", "id": .string(bid), "type": .string(type), "has_children": .bool(hasChildren),
            "last_edited_by": .object(["object": "user", "id": .string(editor)]), type: .object(content),
        ]))
        return bid
    }

    func state(_ page: String) -> String? { pages[page]?["properties"]?["LoopWorker"]?["select"]?["name"]?.string }

    func commentTexts(_ page: String) -> [String] {
        (comments[page] ?? []).map { $0["rich_text"]!.array.map { $0["plain_text"]?.string ?? "" }.joined() }
    }

    // MARK: Routing

    private func handle(_ req: URLRequest) -> (Int, [String: String], JSON) {
        let path = req.url!.path
        let key = "\(req.httpMethod!) \(path)"
        if var q = queued[key], !q.isEmpty {
            let r = q.removeFirst()
            queued[key] = q
            if let r { return r }
        }
        let query = Dictionary(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                               uniquingKeysWith: { $1 })
        let body = req.httpBody.flatMap { try? JSONDecoder().decode(JSON.self, from: $0) } ?? .null
        let parts = path.split(separator: "/").map(String.init) // ["v1", ...]
        switch (req.httpMethod!, Array(parts.dropFirst())) {
        case ("GET", ["users", "me"]): return found(users[meID])
        case ("GET", ["users"]): return paginate(users.keys.sorted().map { users[$0]! }, cursor: query["start_cursor"])
        case ("GET", let p) where p.count == 2 && p[0] == "users": return found(users[p[1]])
        case ("GET", let p) where p.count == 2 && p[0] == "databases": return found(databases[p[1]])
        case ("GET", let p) where p.count == 2 && p[0] == "data_sources": return found(dataSources[p[1]])
        case ("POST", let p) where p.count == 3 && p[0] == "data_sources" && p[2] == "query":
            guard dataSources[p[1]] != nil else { return notFound() }
            let prop = body["filter"]?["property"]?.string ?? ""
            let equals = body["filter"]?["select"]?["equals"]?.string
            let hits = pages.keys.sorted().compactMap { pages[$0] }.filter {
                $0["parent"]?["data_source_id"]?.string == p[1] && $0["in_trash"]?.bool != true
                    && (equals == nil || $0["properties"]?[prop]?["select"]?["name"]?.string == equals)
            }
            var r = paginate(hits, cursor: body["start_cursor"]?.string)
            r.2 = .object(r.2.object.merging(queryExtra) { $1 })
            return r
        case ("GET", let p) where p.count == 2 && p[0] == "pages": return found(pages[p[1]])
        case ("PATCH", let p) where p.count == 2 && p[0] == "pages":
            guard var page = pages[p[1]]?.object else { return notFound() }
            var props = page["properties"]?.object ?? [:]
            for (name, value) in body["properties"]?.object ?? [:] {
                var prop = props[name]?.object ?? ["type": "select"]
                prop["select"] = value["select"]
                props[name] = .object(prop)
            }
            page["properties"] = .object(props)
            page["last_edited_by"] = .object(["object": "user", "id": .string(meID)])
            pages[p[1]] = .object(page)
            return (200, [:], .object(page))
        case ("GET", let p) where p.count == 3 && p[0] == "blocks" && p[2] == "children":
            return paginate(children[p[1]] ?? [], cursor: query["start_cursor"])
        case ("GET", ["comments"]):
            return paginate(comments[query["block_id"] ?? ""] ?? [], cursor: query["start_cursor"])
        case ("POST", ["comments"]):
            guard let page = body["parent"]?["page_id"]?.string else { return (400, [:], .object(["message": "no parent"])) }
            let rich = body["rich_text"]!.array.map { item -> JSON in
                var o = item.object
                o["plain_text"] = item["text"]?["content"] ?? .string("")
                return .object(o)
            }
            let c = appendComment(page, author: meID, richText: rich)
            afterComment?()
            return (200, [:], c)
        case ("DELETE", let p) where p.count == 2 && p[0] == "comments":
            for (page, list) in comments {
                if let i = list.firstIndex(where: { $0["id"]?.string == p[1] }) {
                    comments[page]!.remove(at: i)
                    return (200, [:], .object(["object": "comment", "id": .string(p[1])]))
                }
            }
            return notFound()
        default: fatalError("FakeNotion: unexpected \(key)")
        }
    }

    private func found(_ j: JSON?) -> (Int, [String: String], JSON) { j.map { (200, [:], $0) } ?? notFound() }
    private func notFound() -> (Int, [String: String], JSON) {
        (404, [:], .object(["object": "error", "status": 404, "code": "object_not_found", "message": "Could not find it."]))
    }

    private func paginate(_ all: [JSON], cursor: String?) -> (Int, [String: String], JSON) {
        let start = cursor.flatMap(Int.init) ?? 0
        let page = Array(all.dropFirst(start).prefix(pageSize))
        let more = start + page.count < all.count
        return (200, [:], .object(["object": "list", "results": .array(page), "has_more": .bool(more),
                                   "next_cursor": more ? .string("\(start + page.count)") : .null]))
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

final class LogRecorder: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func log(_ level: LogLevel, _ message: String) { lock.withLock { _lines.append(message) } }
}

/// A clock that moves only when the code under test sleeps, so waits are exact and instant.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 2_000_000_000)
    private var _sleeps: [Double] = []
    var now: Date { lock.withLock { t } }
    var sleeps: [Double] { lock.withLock { _sleeps } }
    func sleep(_ s: Double) { lock.withLock { _sleeps.append(s); t = t.addingTimeInterval(s) } }
}

let app = ProjectSpec(path: "owner/app")
let env = ["LOOPWORKER_NOTION_TOKEN": "ntn_FAKE_token_value"]

/// `[backlog.notion]` with `alice` trusted and `owner/app` mapped to `databaseID` by URL.
/// `keys` go into `[backlog.notion]`, `projects` replaces the mapping lines.
func hostConfig(_ keys: String = "priority_property = \"Priority\"\nmodel_property = \"Model\"",
                trusted: String = "trusted_users = [\"\(alice.replacingOccurrences(of: "-", with: ""))\"]",
                projects: String = "\"owner/app\" = \"https://www.notion.so/acme/Cards-\(databaseID.replacingOccurrences(of: "-", with: ""))?v=0123\"",
                extraProjects: String = "") throws -> HostConfig {
    try HostConfig.parse("""
        [backlog]
        kind = "notion"
        [forge]
        kind = "github"
        [backlog.notion]
        \(trusted)
        \(keys)
        [backlog.notion.projects]
        \(projects)
        [[project]]
        path = "owner/app"
        \(extraProjects)
        """, home: URL(filePath: "/tmp/lw-notion-test"))
}

func make(_ fake: FakeNotion, config: HostConfig? = nil, log: LogRecorder = LogRecorder(), clock: TestClock = TestClock()) throws -> NotionBacklog {
    try NotionBackend.makeBacklog(
        config: config ?? hostConfig(), log: log, environment: env, transport: fake.transport,
        sleep: { clock.sleep($0) }, now: { clock.now }, host: "testhost")
}

func card(_ page: String, _ state: CardState = .working) -> Card {
    Card(ref: CardRef(id: page, display: "CARD-x"), project: "owner/app", title: "t", state: state)
}

extension FakeNotion {
    /// A claim comment by the integration that records `title` as vouched.
    func addClaim(_ page: String, title: String = "card 1", host: String = "h") {
        addComment(page, by: botID, "LoopWorker claimed this card (host \(host), 1234).\n\nVouched title: \(title)")
    }

    /// The id that the fake gives the next comment.
    var nextCommentID: String { id(nextComment, "cc") }
}
