import Foundation
import LoopWorkerCore

/// Notion databases as a `Backlog`, one database per project, through an internal integration.
///
/// The Manager's card state lives in the state property, a select with the options `next`,
/// `working`, `ci`, `review` and `stuck`; the team's own status property is never touched.
/// A `next` card is `ready` only when a trusted user edited the page last, or the integration
/// did and its newest comment is a release (DESIGN.md "Trust in Notion"). The Manager's notes
/// are page comments that the integration wrote, each under a header line (`ManagerComment`).
///
/// `CardRef.id` is the page id; `display` is the unique-id property (`CARD-12`) when the
/// database has one, else `notion:` and the page id's first 8 hex digits.
public actor NotionBacklog: Backlog {
    static let states: [String: CardState] = ["next": .ready, "working": .working, "ci": .verifying, "review": .review, "stuck": .stuck]
    static let schemaLifetime: TimeInterval = 600

    let config: NotionConfig
    let client: NotionClient
    private let log: LogSink
    private let now: @Sendable () -> Date
    private let host: String
    private var loggedOnce: Set<String> = []
    private var dataSources: [String: String] = [:]
    private var schemas: [String: (read: Date, properties: [String: JSON])] = [:]
    private var userNames: [String: String] = [:]

    init(config: NotionConfig, client: NotionClient, log: LogSink, now: @escaping @Sendable () -> Date, host: String) {
        self.config = config
        self.client = client
        self.log = log
        self.now = now
        self.host = host
    }

    // MARK: Reads

    public func workable(in projects: [ProjectSpec]) async throws -> [Card] {
        var found: [(card: Card, created: Date)] = []
        for (db, path) in served(projects) {
            for page in try await query(db, option: "next") {
                let card = try await evaluate(page, project: path)
                if card.state == .ready { found.append((card, page.created)) }
            }
        }
        return found
            .sorted { $0.card.priority != $1.card.priority ? $0.card.priority > $1.card.priority : $0.created < $1.created }
            .map(\.card)
    }

    public func working(in projects: [ProjectSpec]) async throws -> [Card] {
        try await list("working", projects)
    }

    public func verifying(in projects: [ProjectSpec]) async throws -> [Card] {
        try await list("ci", projects)
    }

    private func list(_ option: String, _ projects: [ProjectSpec]) async throws -> [Card] {
        var cards: [Card] = []
        for (db, path) in served(projects) {
            for page in try await query(db, option: option) { cards.append(try await evaluate(page, project: path)) }
        }
        return cards
    }

    public func card(_ ref: CardRef) async throws -> Card? {
        guard let json = try await client.request("GET", "pages/\(ref.id)", missing: .none) else { return nil }
        let page = try Page(json)
        guard !page.inTrash, let project = try await project(of: page) else { return nil }
        return try await evaluate(page, project: project)
    }

    public func snapshot(_ card: Card) async throws -> CardSnapshot {
        guard let json = try await client.request("GET", "pages/\(card.ref.id)", missing: .none) else {
            throw NotionError.unexpectedState(card: card.ref.display, expected: "a page to snapshot", actual: "deleted")
        }
        let page = try Page(json)
        let blocks = try await tree(page.id)
        let comments = try await comments(page.id)
        let trusted = Set(config.trustedUsers)
        let me = try await meID()
        var withheld = Set(comments.map(\.author)).subtracting(trusted).subtracting([me])
        func collect(_ bs: [Block]) {
            for b in bs {
                if let e = b.editor, trusted.contains(e) {} else { withheld.insert(b.editor ?? "") }
                collect(b.children)
            }
        }
        collect(blocks)
        var names: [String: String] = [:]
        for id in withheld.subtracting([""]) { names[id] = await name(id) }
        for id in trusted { names[id] = await name(id) }
        return NotionMarkdown.snapshot(title: page.title, blocks: blocks, comments: comments, trusted: trusted, me: me, names: names)
    }

    /// The integration's release, stuck, review and CI comments, header stripped, oldest first.
    public func managerNotes(_ card: Card) async throws -> [String] {
        let me = try await meID()
        return try await comments(card.ref.id).compactMap { c in
            guard c.author == me, let kind = ManagerComment.kind(c.text), !kind.isClaim else { return nil }
            return ManagerComment.body(c.text)
        }
    }

    // MARK: Writes

    public func claim(_ card: Card) async throws -> Bool {
        guard let fresh = try await self.card(card.ref), fresh.state == .ready else {
            log.info("claim lost for \(card.ref.display): it is no longer ready")
            return false
        }
        try await setState(card.ref.id, "working")
        let nonce = UUID().uuidString.prefix(8).lowercased()
        let mine = try await post(card.ref.id, .claim(host: host, nonce: nonce), [])
        let me = try await meID()
        let ours = try await comments(card.ref.id).filter { $0.author == me }
        // The claims after the integration's newest other comment are this round's.
        let round = ours.reversed().prefix { ManagerComment.kind($0.text)?.isClaim == true }.reversed()
        guard let winner = round.first, winner.id != mine else { return true }
        log.info("claim lost for \(card.ref.display): an older claim comment \(winner.id) (\(winner.text)) won the race")
        do { _ = try await client.request("DELETE", "comments/\(mine)") }
        catch { log.error("\(card.ref.display): can't delete the lost claim comment \(mine): \(error)") }
        return false
    }

    public func markReview(_ card: Card, review: ReviewRequest, note: String?) async throws {
        try await require(card, ["working", "ci"], for: "markReview")
        var segments: [(text: String, link: URL?)] = [("\(review.display): ", nil), (review.url.absoluteString, review.url)]
        if let note { segments.append(("\n\n\(note)", nil)) }
        try await post(card.ref.id, .review, segments)
        try await setState(card.ref.id, "review")
    }

    public func markVerifying(_ card: Card, review: ReviewRequest) async throws {
        try await require(card, ["working"], for: "markVerifying")
        try await post(card.ref.id, .ci, [("\(review.display): ", nil), (review.url.absoluteString, review.url)])
        try await setState(card.ref.id, "ci")
    }

    public func resumeFix(_ card: Card) async throws -> Bool {
        let state = try await currentOption(card)
        guard state == "ci" else {
            log.info("CI fix round for \(card.ref.display) dropped: its \(config.stateProperty) is \(state ?? "empty"), not ci")
            return false
        }
        try await setState(card.ref.id, "working")
        return true
    }

    public func markStuck(_ card: Card, blocker: String) async throws {
        try await require(card, ["working", "ci"], for: "markStuck")
        try await post(card.ref.id, .stuck, [(blocker, nil)])
        try await setState(card.ref.id, "stuck")
    }

    public func release(_ card: Card, reason: String, countsAsAttempt: Bool) async throws {
        try await require(card, ["working"], for: "release")
        try await post(card.ref.id, countsAsAttempt ? .failedRelease : .release, [(reason, nil)])
        try await setState(card.ref.id, "next")
    }

    private func require(_ card: Card, _ options: [String], for call: String) async throws {
        let state = try await currentOption(card)
        guard let state, options.contains(state) else {
            throw NotionError.unexpectedState(card: "\(call) \(card.ref.display)", expected: options.joined(separator: " or "), actual: state ?? "empty")
        }
    }

    /// The state property's option as stored now; nil when it is empty, or the page is deleted or in the trash.
    private func currentOption(_ card: Card) async throws -> String? {
        _ = try await meID()
        guard let json = try await client.request("GET", "pages/\(card.ref.id)", missing: .none) else { return nil }
        let page = try Page(json)
        return page.inTrash ? nil : page.select(config.stateProperty)
    }

    private func setState(_ page: String, _ option: String) async throws {
        _ = try await client.request("PATCH", "pages/\(page)", body: .object([
            "properties": .object([config.stateProperty: .object(["select": .object(["name": .string(option)])])]),
        ]))
    }

    /// Posts a Manager comment and returns its id.
    @discardableResult
    private func post(_ page: String, _ kind: ManagerComment, _ segments: [(text: String, link: URL?)]) async throws -> String {
        let all = [(text: kind.header + (segments.isEmpty ? "" : "\n\n"), link: URL?.none)] + segments
        let created = try await client.request("POST", "comments", body: .object([
            "parent": .object(["page_id": .string(page)]),
            "rich_text": .array(NotionMarkdown.richText(all)),
        ]))
        guard let id = created?["id"]?.string else { throw NotionError.malformed("POST /v1/comments returned no id") }
        return id
    }

    // MARK: Mapping

    struct Page {
        var id: String
        var url: URL?
        var created: Date
        var editor: String?
        var inTrash: Bool
        var databaseID: String?
        var dataSourceID: String?
        var properties: [String: JSON]

        init(_ j: JSON) throws {
            guard let id = j["id"]?.string, let created = j["created_time"]?.string.flatMap(NotionTime.parse) else {
                throw NotionError.malformed("a page without id or created_time: \(NotionClient.excerpt((try? JSONEncoder().encode(j)) ?? Data()))")
            }
            self.id = id
            self.created = created
            url = j["url"]?.string.flatMap(URL.init(string:))
            editor = j["last_edited_by"]?["id"]?.string.map { NotionID.normalize($0) ?? $0 }
            inTrash = j["in_trash"]?.bool ?? j["archived"]?.bool ?? false
            databaseID = j["parent"]?["database_id"]?.string.flatMap(NotionID.normalize)
            dataSourceID = j["parent"]?["data_source_id"]?.string.flatMap(NotionID.normalize)
            properties = j["properties"]?.object ?? [:]
        }

        var title: String {
            let prop = properties.values.first { $0["type"]?.string == "title" }
            return (prop?["title"]?.array ?? []).map { $0["plain_text"]?.string ?? $0["text"]?["content"]?.string ?? "" }.joined()
        }

        func select(_ name: String) -> String? { properties[name]?["select"]?["name"]?.string }

        /// The unique-id property's prefix and number, if the database has one.
        var uniqueID: (prefix: String?, number: Int)? {
            for key in properties.keys.sorted() {
                let u = properties[key]!["unique_id"]
                if properties[key]!["type"]?.string == "unique_id", let n = u?["number"]?.double {
                    return (u?["prefix"]?.string, Int(n))
                }
            }
            return nil
        }
    }

    /// Maps a page to a card, judging trust for `next` (B190). Reads the comments unless the
    /// state property alone makes the card `other`.
    private func evaluate(_ page: Page, project: String) async throws -> Card {
        let me = try await meID()
        let unique = page.uniqueID
        let display = unique.map { u in u.prefix.map { "\($0)-\(u.number)" } ?? "\(u.number)" }
            ?? "notion:\(page.id.replacingOccurrences(of: "-", with: "").prefix(8))"
        var state = page.select(config.stateProperty).flatMap { Self.states[$0] } ?? .other
        var comments: [Comment] = []
        if state == .ready, page.editor.map(config.trustedUsers.contains) != true, page.editor != me {
            let editor = await name(page.editor)
            logOnce(page.id, "skipping \(display) \"\(page.title)\": its last editor \(editor) is not in [backlog.notion] trusted_users")
            state = .other
        } else if state != .other {
            comments = try await self.comments(page.id)
            if state == .ready, page.editor == me,
               comments.last(where: { $0.author == me }).flatMap({ ManagerComment.kind($0.text) })?.isRelease != true {
                logOnce(page.id, "skipping \(display) \"\(page.title)\": LoopWorker edited it last and its newest LoopWorker comment is not a release")
                state = .other
            }
        }
        return Card(
            ref: CardRef(id: page.id, display: display), project: project, number: unique.map { "\($0.number)" },
            title: page.title, state: state, priority: try await priority(page, project: project), model: model(page),
            attempts: comments.filter { $0.author == me && ManagerComment.kind($0.text) == .failedRelease }.count,
            url: page.url)
    }

    /// B194: a number as is; a select or multi-select option ranks by its place in the
    /// property's option list, earlier higher; absent, empty or unknown is 0.
    private func priority(_ page: Page, project: String) async throws -> Double {
        guard let name = config.priorityProperty, let prop = page.properties[name], let type = prop["type"]?.string else { return 0 }
        let chosen: [String]
        switch type {
        case "number": return prop["number"]?.double ?? 0
        case "select": chosen = prop["select"]?["name"]?.string.map { [$0] } ?? []
        case "multi_select": chosen = (prop["multi_select"]?.array ?? []).compactMap { $0["name"]?.string }
        default: return 0
        }
        guard !chosen.isEmpty, let db = config.projectPaths.first(where: { $0.value == project })?.key else { return 0 }
        let source: String
        if let s = page.dataSourceID { source = s } else { source = try await dataSource(db) }
        let options = (try await schema(source, database: db)[name]?[type]?["options"]?.array ?? []).compactMap { $0["name"]?.string }
        return chosen.compactMap { options.firstIndex(of: $0) }.map { Double(options.count - $0) }.max() ?? 0
    }

    private func model(_ page: Page) -> String? {
        guard let name = config.modelProperty, let prop = page.properties[name] else { return nil }
        let text: String
        switch prop["type"]?.string {
        case "select": text = prop["select"]?["name"]?.string ?? ""
        case "rich_text": text = (prop["rich_text"]?.array ?? []).map { $0["plain_text"]?.string ?? "" }.joined()
        default: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Lookups

    private func meID() async throws -> String {
        let me = try await client.me()
        guard let id = me["id"]?.string else { throw NotionError.malformed("GET /v1/users/me returned no id") }
        return NotionID.normalize(id) ?? id
    }

    /// The configured databases of `projects`, in a stable order.
    private func served(_ projects: [ProjectSpec]) -> [(database: String, path: String)] {
        projects.compactMap { p in config.databaseID(for: p).map { ($0, config.projectPaths[$0]!) } }.sorted { $0.path < $1.path }
    }

    private func project(of page: Page) async throws -> String? {
        if let db = page.databaseID { return config.projectPaths[db] }
        guard let source = page.dataSourceID else { return nil }
        for (db, path) in config.projectPaths.sorted(by: { $0.value < $1.value }) {
            if try await dataSource(db) == source { return path }
        }
        return nil
    }

    /// The database's one data source, cached (B189).
    func dataSource(_ database: String) async throws -> String {
        if let cached = dataSources[database] { return cached }
        guard let db = try await client.request("GET", "databases/\(database)", missing: .database(database)) else {
            throw NotionError.notConnected(database: database, request: "GET /v1/databases/\(database)")
        }
        let sources = db["data_sources"]?.array ?? []
        guard sources.count == 1, let id = sources[0]["id"]?.string else {
            throw NotionError.dataSources(database: database, found: sources.map { "\($0["name"]?.string ?? "unnamed") \($0["id"]?.string ?? "?")" })
        }
        let normalized = NotionID.normalize(id) ?? id
        dataSources[database] = normalized
        return normalized
    }

    /// The data source's properties by name, re-read every `schemaLifetime` seconds so new options rank.
    func schema(_ source: String, database: String) async throws -> [String: JSON] {
        if let cached = schemas[source], now().timeIntervalSince(cached.read) < Self.schemaLifetime { return cached.properties }
        guard let ds = try await client.request("GET", "data_sources/\(source)", missing: .database(database)) else {
            throw NotionError.notConnected(database: database, request: "GET /v1/data_sources/\(source)")
        }
        let properties = ds["properties"]?.object ?? [:]
        schemas[source] = (now(), properties)
        return properties
    }

    private func query(_ database: String, option: String) async throws -> [Page] {
        _ = try await meID()  // B188: refuse a person's token before reading anything
        let source = try await dataSource(database)
        return try await client.list("POST", "data_sources/\(source)/query", body: [
            "filter": .object(["property": .string(config.stateProperty), "select": .object(["equals": .string(option)])]),
        ], missing: .database(database)).map(Page.init)
    }

    /// The page's comments, oldest first; ties keep the API's order.
    private func comments(_ page: String) async throws -> [Comment] {
        try await client.list("GET", "comments", query: [URLQueryItem(name: "block_id", value: page)])
            .map(Comment.init).enumerated()
            .sorted { ($0.element.created, $0.offset) < ($1.element.created, $1.offset) }
            .map(\.element)
    }

    /// The page's body blocks, recursively; child pages and databases are not entered.
    private func tree(_ parent: String) async throws -> [Block] {
        var blocks: [Block] = []
        for json in try await client.list("GET", "blocks/\(parent)/children") {
            var b = Block(json: json, children: [])
            if json["has_children"]?.bool == true, !["child_page", "child_database"].contains(b.type) {
                b.children = try await tree(b.id)
            }
            blocks.append(b)
        }
        return blocks
    }

    /// A user's name, cached; the id when it can't be read.
    func name(_ user: String?) async -> String {
        guard let user else { return "an unknown user" }
        if let cached = userNames[user] { return cached }
        do {
            if let name = try await client.request("GET", "users/\(user)", missing: .none)?["name"]?.string {
                userNames[user] = name
                return name
            }
        } catch {
            logOnce("user \(user)", "can't read the name of Notion user \(user): \(error)")
        }
        return user
    }

    private func logOnce(_ key: String, _ message: String) {
        guard loggedOnce.insert("\(key)|\(message)").inserted else { return }
        log.info(message)
    }
}
