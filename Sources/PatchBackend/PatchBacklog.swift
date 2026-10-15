import Foundation
import LoopWorkerCore

/// A Patch roadmap table as a `Backlog`, over PostgREST as the PAT owner.
///
/// Card states come from the `status` column (`[backlog.patch.status]`); an empty status counts
/// as ready. A card is workable when its status is ready, it is unassigned and not an epic,
/// every `blocked_by` target is shipped, its `project` relation names a configured project,
/// and its `created_by` is the PAT owner or in `trusted_authors`.
///
/// The claim marker is the status itself: `claim` moves ready to working in one PATCH filtered
/// on the status it read and `assignee=is.null`, so a lost race changes no row. `assignee` is
/// never set. Manager notes are text blocks appended to the card's page body, tagged
/// `content.loopworker` (`note` or `failed-attempt`) so that `attempts` can count them and
/// `snapshot` can leave them out.
public actor PatchBacklog: Backlog {
    let config: PatchConfig
    let client: PatchClient
    private let log: LogSink
    private var skipped: Set<String> = []

    init(config: PatchConfig, client: PatchClient, log: LogSink) {
        self.config = config
        self.client = client
        self.log = log
    }

    /// Exchanges the PAT, waiting out a transient backend for up to 600 s. Call once at
    /// startup; without it the first read exchanges and fails at once on a transient error.
    /// Throws `PatchError.unreachable` after the budget (the caller should alert a human) and
    /// `PatchError.patRejected` at once for a revoked or wrong PAT.
    public func connect() async throws { try await client.connect() }

    // MARK: Reads

    public func workable(in projects: [ProjectSpec]) async throws -> [Card] {
        let served = Set(projects.compactMap(config.patchID(for:)))
        let rows = try await allRows()
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let trusted = try await trustedAuthors()
        var picked: [Row] = []
        for r in rows where isReady(r.status) && r.assignee == nil && !r.isEpic {
            guard let project = r.project else { skipOnce(r, "it has no project"); continue }
            guard served.contains(project) else { continue }
            guard r.blockedBy.allSatisfy({ byID[$0]?.status == config.status.shipped }) else { continue }
            guard let author = r.createdBy, trusted.contains(author) else {
                skipOnce(r, "its author \(r.createdBy ?? "(none)") is not trusted; add the uid to trusted_authors to allow it")
                continue
            }
            picked.append(r)
        }
        picked.sort { ($0.priority, -$0.number) > ($1.priority, -$1.number) }
        return try await cards(picked, trusted: trusted)
    }

    public func working(in projects: [ProjectSpec]) async throws -> [Card] {
        let served = Set(projects.compactMap(config.patchID(for:)))
        let rows = try await allRows([URLQueryItem(name: "status", value: "eq.\(config.status.working)")])
        return try await cards(rows.filter { $0.project.map(served.contains) ?? false }, trusted: trustedAuthors())
    }

    public func verifying(in projects: [ProjectSpec]) async throws -> [Card] {
        let served = Set(projects.compactMap(config.patchID(for:)))
        let rows = try await allRows([URLQueryItem(name: "status", value: "eq.\(config.status.verifying)")])
        return try await cards(rows.filter { $0.project.map(served.contains) ?? false }, trusted: trustedAuthors())
    }

    public func card(_ ref: CardRef) async throws -> Card? {
        guard let row = try await row(ref.id), row.project.flatMap({ config.projectPaths[$0] }) != nil else { return nil }
        return try await cards([row], trusted: trustedAuthors()).first
    }

    public func snapshot(_ card: Card) async throws -> CardSnapshot {
        guard let row = try await row(card.ref.id) else {
            throw PatchError.malformed("\(card.ref) no longer exists in \(config.roadmapTable)")
        }
        let blocks = try await client.getAll("patch_blocks", [
            URLQueryItem(name: "table_name", value: "eq.\(config.roadmapTable)"),
            URLQueryItem(name: "row_id", value: "eq.\(row.id)"),
            URLQueryItem(name: "select", value: "id,type,content,parent_id,updated_by"),
            URLQueryItem(name: "order", value: "sort.asc,id.asc"),
        ])
        return PatchMarkdown.snapshot(title: row.title, createdBy: row.createdBy, blocks: blocks, trusted: try await trustedAuthors())
    }

    /// The text of the card's blocks tagged `content.loopworker` that the PAT owner wrote and
    /// last edited, in body order.
    public func managerNotes(_ card: Card) async throws -> [String] {
        let owner = try await client.owner()
        return try await client.getAll("patch_blocks", [
            URLQueryItem(name: "table_name", value: "eq.\(config.roadmapTable)"),
            URLQueryItem(name: "row_id", value: "eq.\(card.ref.id)"),
            URLQueryItem(name: "content->>\(PatchMarkdown.markerKey)", value: "not.is.null"),
            URLQueryItem(name: "owner", value: "eq.\(owner)"),
            URLQueryItem(name: "updated_by", value: "eq.\(owner)"),
            URLQueryItem(name: "select", value: "content"),
            URLQueryItem(name: "order", value: "sort.asc,id.asc"),
        ]).compactMap { $0["content"]?["text"]?.string }
    }

    // MARK: Writes

    public func claim(_ card: Card) async throws -> Bool {
        guard let r = try await row(card.ref.id), isReady(r.status), r.assignee == nil, !r.isEpic,
              let author = r.createdBy, try await trustedAuthors().contains(author)
        else { return false }
        let statusFilter = r.status.map { URLQueryItem(name: "status", value: "eq.\($0)") }
            ?? URLQueryItem(name: "status", value: "is.null")
        let changed = try await client.patch(config.roadmapTable, [
            URLQueryItem(name: "id", value: "eq.\(r.id)"), statusFilter,
            URLQueryItem(name: "assignee", value: "is.null"),
        ], .object(["status": .string(config.status.working)]))
        return !changed.isEmpty
    }

    public func markReview(_ card: Card, review: ReviewRequest, note: String?) async throws {
        var fields: [String: JSON] = ["status": .string(config.status.review)]
        if let field = config.reviewLinkField { fields[field] = .string(review.url.absoluteString) }
        try await move(card, from: [config.status.working, config.status.verifying],
                       note: "Review request: [\(review.display)](\(review.url.absoluteString))" + (note.map { "\n\n\($0)" } ?? ""),
                       kind: "note", fields: fields)
    }

    public func markVerifying(_ card: Card, review: ReviewRequest, plan: VerifyingPlan) async throws {
        var fields: [String: JSON] = ["status": .string(config.status.verifying)]
        if let field = config.reviewLinkField { fields[field] = .string(review.url.absoluteString) }
        try await move(card, note: "Review request: [\(review.display)](\(review.url.absoluteString))\n\nWaiting for CI before review.",
                       kind: "note", fields: fields)
    }

    /// One PATCH filtered on the verifying status, so a card that a human moved stays put.
    public func markMerged(_ card: Card, review: ReviewRequest, note: String?) async throws {
        throw BackendRejection("markMerged \(card.ref.display): not implemented yet")
    }

    public func resumeFix(_ card: Card) async throws -> Bool {
        let changed = try await client.patch(config.roadmapTable, [
            URLQueryItem(name: "id", value: "eq.\(card.ref.id)"),
            URLQueryItem(name: "status", value: "eq.\(config.status.verifying)"),
        ], .object(["status": .string(config.status.working)]))
        return !changed.isEmpty
    }

    public func markStuck(_ card: Card, blocker: String) async throws {
        try await move(card, from: [config.status.working, config.status.verifying],
                       note: "LoopWorker is stuck on this card:\n\n\(blocker)", kind: "note",
                       fields: ["status": .string(config.status.stuck)])
    }

    public func release(_ card: Card, reason: String, countsAsAttempt: Bool) async throws {
        // Clearing assignee lets a card claimed by an older Manager, which set it, become workable again.
        try await move(card, note: "LoopWorker released this card: \(reason)",
                       kind: countsAsAttempt ? "failed-attempt" : "note",
                       fields: ["status": .string(config.status.ready), "assignee": .null])
    }

    /// Checks that the card has one of the `from` statuses (default: working), appends the
    /// note, then writes `fields` in a PATCH filtered on the status it read, so a card that a
    /// human moved meanwhile is left alone.
    private func move(_ card: Card, from: [String]? = nil, note: String, kind: String, fields: [String: JSON]) async throws {
        let from = from ?? [config.status.working]
        let expected = from.joined(separator: " or ")
        guard let r = try await row(card.ref.id) else {
            throw PatchError.unexpectedState(card: card.ref.display, expected: expected, actual: "(deleted)")
        }
        guard let status = r.status, from.contains(status) else {
            throw PatchError.unexpectedState(card: card.ref.display, expected: expected, actual: r.status ?? "")
        }
        let owner = try await client.owner()
        try await client.insert("patch_blocks", .object([
            "table_name": .string(config.roadmapTable), "row_id": .string(r.id), "type": .string("text"),
            "content": .object(["text": .string(note), PatchMarkdown.markerKey: .string(kind)]),
            "owner": .string(owner), "updated_by": .string(owner),
        ]))
        let changed = try await client.patch(config.roadmapTable, [
            URLQueryItem(name: "id", value: "eq.\(r.id)"),
            URLQueryItem(name: "status", value: "eq.\(status)"),
        ], .object(fields))
        if changed.isEmpty {
            throw PatchError.unexpectedState(card: card.ref.display, expected: status, actual: "(changed during the write)")
        }
    }

    // MARK: Mapping

    struct Row {
        var id: String
        var number: Int
        var title: String
        /// Exactly as stored: nil for null, so `claim` can filter on the value it read.
        var status: String?
        var priority: Double
        var isEpic: Bool
        var blockedBy: [String]
        var assignee: String?
        var project: String?
        var model: String?
        var createdBy: String?

        init(_ j: JSON, table: String) throws {
            guard let id = j["id"]?.string, let number = j["id_2"]?.double else {
                throw PatchError.malformed("a \(table) row without id or id_2: \(j)")
            }
            self.id = id
            self.number = Int(number)
            title = j["title"]?.string ?? ""
            if case .string(let s)? = j["status"] { status = s } else { status = nil }
            priority = j["priority"]?.double ?? 0
            isEpic = j["area"]?.strings.contains("epic") ?? false
            blockedBy = j["blocked_by"]?.strings ?? []
            assignee = j["assignee"]?.strings.first
            project = j["project"]?.strings.first
            model = j["model"]?.string
            createdBy = j["created_by"]?.string
        }
    }

    private func isReady(_ status: String?) -> Bool { (status ?? "").isEmpty || status == config.status.ready }

    private func state(_ r: Row, trusted: Set<String>) -> CardState {
        switch r.status {
        case _ where isReady(r.status): r.createdBy.map(trusted.contains) == true ? .ready : .other
        case config.status.working: .working
        case config.status.verifying: .verifying
        case config.status.review: .review
        case config.status.stuck: .stuck
        default: .other
        }
    }

    private func cards(_ rows: [Row], trusted: Set<String>) async throws -> [Card] {
        let attempts = try await failedAttempts(rows.map(\.id))
        return rows.compactMap { r in
            guard let path = r.project.flatMap({ config.projectPaths[$0] }) else { return nil }
            var url: URL?
            if let app = config.appBase, let item = config.roadmapItemID {
                url = URL(string: "\(app.absoluteString)/app/\(item)?row=\(r.id)&rowpage=1")
            }
            return Card(
                ref: CardRef(id: r.id, display: "~\(r.number)"), project: path, number: "\(r.number)",
                title: r.title, state: state(r, trusted: trusted), priority: r.priority, model: r.model,
                attempts: attempts[r.id] ?? 0, url: url)
        }
    }

    /// Failed-attempt notes per card, counting only notes the PAT owner wrote.
    private func failedAttempts(_ ids: [String]) async throws -> [String: Int] {
        guard !ids.isEmpty else { return [:] }
        let blocks = try await client.getAll("patch_blocks", [
            URLQueryItem(name: "table_name", value: "eq.\(config.roadmapTable)"),
            URLQueryItem(name: "row_id", value: "in.(\(ids.joined(separator: ",")))"),
            URLQueryItem(name: "content->>\(PatchMarkdown.markerKey)", value: "eq.failed-attempt"),
            URLQueryItem(name: "owner", value: "eq.\(try await client.owner())"),
            URLQueryItem(name: "select", value: "row_id"),
            URLQueryItem(name: "order", value: "id.asc"),
        ])
        return blocks.reduce(into: [:]) { counts, b in
            if let id = b["row_id"]?.string { counts[id, default: 0] += 1 }
        }
    }

    private func allRows(_ filter: [URLQueryItem] = []) async throws -> [Row] {
        try await client.getAll(config.roadmapTable, filter + [
            URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "order", value: "id_2.asc"),
        ]).map { try Row($0, table: config.roadmapTable) }
    }

    private func row(_ id: String) async throws -> Row? {
        try await allRows([URLQueryItem(name: "id", value: "eq.\(id)")]).first
    }

    private func trustedAuthors() async throws -> Set<String> {
        config.trustedAuthors.union([try await client.owner()])
    }

    private func skipOnce(_ r: Row, _ why: String) {
        guard skipped.insert(r.id).inserted else { return }
        log.info("Skipping ~\(r.number) \"\(r.title)\": \(why)")
    }
}
