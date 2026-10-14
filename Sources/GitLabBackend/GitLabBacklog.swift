import Foundation
import LoopWorkerCore

/// GitLab issues as a backlog. Card state lives in `<prefix>next|working|ci|review|stuck` labels;
/// only issues that the token's user vouched for are ever `ready` (DESIGN.md "Trust").
///
/// `CardRef.id` is `<project id>/<issue iid>`, `display` is `<project path>#<iid>`.
public actor GitLabBacklog: Backlog {
    let client: GitLabClient
    let settings: GitLabBacklogSettings
    private let log: LogSink
    /// Projects that `card(_:)` serves: the host config's plus any passed to a list call.
    private var knownProjects: [String: ProjectSpec]
    private var loggedOnce: Set<String> = []
    private var statusIDs: [String: [String: String]] = [:]

    init(client: GitLabClient, settings: GitLabBacklogSettings, projects: [ProjectSpec], log: LogSink) {
        self.client = client
        self.settings = settings
        self.log = log
        knownProjects = Dictionary(projects.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Reads

    public func workable(in projects: [ProjectSpec]) async throws -> [Card] {
        try await list(label: .ready, in: projects)
    }

    public func working(in projects: [ProjectSpec]) async throws -> [Card] {
        try await list(label: .working, in: projects)
    }

    public func verifying(in projects: [ProjectSpec]) async throws -> [Card] {
        try await list(label: .verifying, in: projects)
    }

    public func card(_ ref: CardRef) async throws -> Card? {
        try await read(ref)?.card
    }

    private func list(label state: CardState, in projects: [ProjectSpec]) async throws -> [Card] {
        for p in projects { knownProjects[p.key] = p }
        let me = try await client.me()
        let issues: [GLIssue] = try await client.getAll("/issues", query: [
            ("scope", "all"), ("state", "opened"), ("assignee_username", me.username),
            ("labels", settings.label(state)!),
        ])
        let served = Set(projects.map(\.key))
        var found: [(card: Card, created: Date)] = []
        for issue in issues {
            guard let read = try await evaluate(issue, me: me, served: served), read.card.state == state else { continue }
            found.append((read.card, issue.createdAt))
        }
        return found
            .sorted { $0.card.priority != $1.card.priority ? $0.card.priority > $1.card.priority : $0.created < $1.created }
            .map(\.card)
    }

    private struct Read {
        var card: Card
        var issue: GLIssue
        var projectPath: String
        var notes: [GLNote]
    }

    private func read(_ ref: CardRef) async throws -> Read? {
        let parts = ref.id.split(separator: "/")
        guard parts.count == 2, let projectID = Int(parts[0]), let iid = Int(parts[1]) else {
            throw GitLabError("\(ref.display): card id \(ref.id) is not <project id>/<iid>")
        }
        guard let issue: GLIssue = try await client.getIfFound("/projects/\(projectID)/issues/\(iid)"),
              issue.movedToId == nil
        else { return nil }
        return try await evaluate(issue, me: try await client.me(), served: Set(knownProjects.keys))
    }

    /// Maps an issue to a card, running the trust check when its label says ready. Nil when
    /// the project isn't served or is outside `allowed`.
    private func evaluate(_ issue: GLIssue, me: GLUser, served: Set<String>) async throws -> Read? {
        guard let project = try await client.project(id: issue.projectId) else { return nil }
        let path = project.pathWithNamespace
        guard served.contains(ProjectSpec(path: path).key) else { return nil }
        let display = "\(path)#\(issue.iid)"
        guard settings.isAllowed(path) else {
            logOnce(display, "project \(path) is outside [backlog.gitlab] allowed")
            return nil
        }
        let notes: [GLNote] = try await client.getAll(notesPath(issue))
        var state = labelState(issue, display: display)
        if state == .ready {
            let events: [GLLabelEvent] = try await client.getAll(eventsPath(issue))
            let verdict = Trust.check(issue: issue, me: me, nextLabel: settings.label(.ready)!, notes: notes, events: events)
            if case .untrusted(let reason) = verdict {
                logOnce(display, "not trusted: \(reason)")
                state = .other
            }
        }
        let card = Card(
            ref: CardRef(id: "\(issue.projectId)/\(issue.iid)", display: display),
            project: path,
            number: String(issue.iid),
            title: issue.title,
            state: state,
            priority: labelValue(issue, "priority:").flatMap(Double.init) ?? 0,
            model: labelValue(issue, "model:"),
            attempts: notes.filter { Trust.countsAsAttempt($0, me: me) }.count,
            url: URL(string: issue.webUrl))
        return Read(card: card, issue: issue, projectPath: path, notes: notes)
    }

    private func labelState(_ issue: GLIssue, display: String) -> CardState {
        guard issue.state == "opened" else { return .other }
        let states = Self.labelledStates.filter { issue.labels.contains(settings.label($0)!) }
        if states.count > 1 {
            logOnce(display, "has \(states.map { settings.label($0)! }.joined(separator: " and ")); treating it as not LoopWorker's")
            return .other
        }
        return states.first ?? .other
    }

    private func labelValue(_ issue: GLIssue, _ key: String) -> String? {
        let prefix = settings.labelPrefix + key
        return issue.labels.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private func logOnce(_ display: String, _ reason: String) {
        guard loggedOnce.insert("\(display)|\(reason)").inserted else { return }
        log.info("skipping \(display): \(reason)")
    }

    // MARK: - Snapshot

    public func snapshot(_ card: Card) async throws -> CardSnapshot {
        guard let read = try await read(card.ref) else {
            throw GitLabError("\(card.ref.display): can't snapshot, the issue is gone or no longer served")
        }
        let me = try await client.me()
        let events: [GLLabelEvent] = try await client.getAll(eventsPath(read.issue))
        let cutoff: Date
        switch Trust.cutoff(issue: read.issue, me: me, nextLabel: settings.label(.ready)!, notes: read.notes, events: events) {
        case .success(let date): cutoff = date
        case .failure(let refusal): throw GitLabError("\(card.ref.display): can't snapshot, not trusted: \(refusal)")
        }
        var notes: [GQLNote] = []
        var after: String?
        var text: IssueText?
        repeat {
            var variables = ["path": read.projectPath, "iid": String(read.issue.iid)]
            if let after { variables["after"] = after }
            let page: GQLSnapshotPage = try await client.graphQL("issue snapshot \(card.ref.display)", Self.snapshotQuery, variables: variables)
            guard let issueNotes = page.project?.issue?.notes else {
                throw GitLabError("\(card.ref.display): GraphQL returned no issue notes")
            }
            if text == nil { text = try Self.issueText(page, issue: read.issue, display: card.ref.display) }
            notes += issueNotes.nodes
            after = issueNotes.pageInfo.hasNextPage ? issueNotes.pageInfo.endCursor : nil
        } while after != nil
        return Trust.snapshot(content: text!, notes: notes, me: me, cutoff: cutoff)
    }

    /// Title and description from the work item, author and creation time from the REST issue.
    static func issueText(_ page: GQLSnapshotPage, issue: GLIssue, display: String) throws -> IssueText {
        guard let item = page.namespace?.workItem else { throw GitLabError("\(display): GraphQL returned no work item") }
        guard let widget = item.widgets.first(where: { $0.typename == "WorkItemWidgetDescription" }) else {
            throw GitLabError("\(display): the work item has no description widget")
        }
        return IssueText(
            title: item.title, description: widget.description, createdAt: issue.createdAt,
            author: GQLUser(id: "gid://gitlab/User/\(issue.author.id)", username: issue.author.username),
            lastEditedAt: widget.lastEditedAt, lastEditedBy: widget.lastEditedBy)
    }

    static let snapshotQuery = """
        query($path: ID!, $iid: String!, $after: String) {
          namespace(fullPath: $path) {
            workItem(iid: $iid) {
              title
              widgets {
                __typename
                ... on WorkItemWidgetDescription { description lastEditedAt lastEditedBy { id username } }
              }
            }
          }
          project(fullPath: $path) {
            issue(iid: $iid) {
              notes(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { id body system createdAt lastEditedAt lastEditedBy { id username } author { id username } }
              }
            }
          }
        }
        """

    // MARK: - Writes

    public func claim(_ card: Card) async throws -> Bool {
        guard let read = try await read(card.ref), read.card.state == .ready else {
            log.info("claim lost for \(card.ref.display): it is no longer ready")
            return false
        }
        try await move(read, to: .working)
        return true
    }

    public func markReview(_ card: Card, review: ReviewRequest, note: String?) async throws {
        let read = try await require(card, in: [.working, .verifying], for: "markReview")
        try await postNote(read, "Review request: \(review.url.absoluteString)" + (note.map { "\n\n\($0)" } ?? ""))
        try await move(read, to: .review)
    }

    public func markVerifying(_ card: Card, review: ReviewRequest) async throws {
        let read = try await require(card, in: [.working], for: "markVerifying")
        try await postNote(read, "Review request: \(review.url.absoluteString)\n\nWaiting for CI before review.")
        try await move(read, to: .verifying)
    }

    public func resumeFix(_ card: Card) async throws -> Bool {
        guard let read = try await read(card.ref), read.card.state == .verifying else {
            log.info("CI fix round for \(card.ref.display) dropped: it is no longer \(settings.label(.verifying)!)")
            return false
        }
        try await move(read, to: .working)
        return true
    }

    public func markStuck(_ card: Card, blocker: String) async throws {
        let read = try await require(card, in: [.working, .verifying], for: "markStuck")
        try await postNote(read, "LoopWorker is stuck on this card:\n\n\(blocker)")
        try await move(read, to: .stuck)
    }

    public func release(_ card: Card, reason: String, countsAsAttempt: Bool) async throws {
        let read = try await require(card, in: [.working], for: "release")
        let me = try await client.me()
        let events: [GLLabelEvent] = try await client.getAll(eventsPath(read.issue))
        let cutoff: Date
        switch Trust.cutoff(issue: read.issue, me: me, nextLabel: settings.label(.ready)!, notes: read.notes, events: events) {
        case .success(let date): cutoff = date
        // Releasing without the original cutoff would trust content that arrived while working.
        case .failure(let refusal): throw GitLabError("\(card.ref.display): can't release, no trust cutoff to keep: \(refusal)")
        }
        var markers = "\(Trust.cutoffMarkerPrefix)\(GitLabTime.format(cutoff)) -->\n"
        if countsAsAttempt { markers += Trust.failedAttemptMarker + "\n" }
        try await postNote(read, "LoopWorker released this card:\n\n\(reason)", markers: markers)
        try await move(read, to: .ready)
    }

    private func require(_ card: Card, in states: [CardState], for call: String) async throws -> Read {
        let expected = states.map(\.rawValue).joined(separator: " or ")
        guard let read = try await read(card.ref) else {
            throw GitLabError("\(call) \(card.ref.display): expected \(expected), but the issue is gone or no longer served")
        }
        guard states.contains(read.card.state) else {
            throw GitLabError("\(call) \(card.ref.display): expected \(expected), found \(read.card.state.rawValue)")
        }
        return read
    }

    /// Posts a Manager note. Everything after the markers passes through quick-action neutralization.
    /// Skips the post when my newest note already has this body and no label changed since:
    /// a retry after a write whose note landed but whose label change failed.
    private func postNote(_ read: Read, _ text: String, markers: String = "") async throws {
        let body = Trust.managerMarker + "\n" + markers + "\n" + Trust.neutralizeQuickActions(text)
        let me = try await client.me()
        if let last = read.notes.filter({ $0.author.id == me.id && !$0.system }).max(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }),
           last.body == body {
            let events: [GLLabelEvent] = try await client.getAll(eventsPath(read.issue))
            if !events.contains(where: { $0.createdAt >= last.createdAt }) {
                log.info("\(read.card.ref.display): note \(last.id) already says this; not posting it again")
                return
            }
        }
        let _: GLNote = try await client.send("POST", notesPath(read.issue), body: ["body": body], idempotent: false)
    }

    /// Swaps the state labels in one request, then mirrors the state into the status field.
    private func move(_ read: Read, to target: CardState) async throws {
        let (add, remove) = labelChange(to: target)
        let path = "/projects/\(read.issue.projectId)/issues/\(read.issue.iid)"
        let _: GLIssue = try await client.send(
            "PUT", path, body: ["add_labels": add.joined(separator: ","), "remove_labels": remove.joined(separator: ",")],
            idempotent: true)
        if settings.statusMode == .workItemStatus {
            await setWorkItemStatus(read, to: target)
        }
    }

    static let labelledStates: [CardState] = [.ready, .working, .verifying, .review, .stuck]

    /// The labels to add and remove to move any card to `target`.
    func labelChange(to target: CardState) -> (add: [String], remove: [String]) {
        let states = Self.labelledStates
        var add = [settings.label(target)!]
        var remove = states.filter { $0 != target }.map { settings.label($0)! }
        if settings.statusMode == .labels, let name = settings.statusNames[target] {
            add.append(name)
            remove += Set(states.compactMap { settings.statusNames[$0] }).subtracting([name]).sorted()
        }
        return (add, remove)
    }

    // MARK: - Work-item status

    /// Best effort: the labels already carry the state, so a failure here is logged, not thrown.
    private func setWorkItemStatus(_ read: Read, to target: CardState) async {
        guard let name = settings.statusNames[target] else { return }
        let display = read.card.ref.display
        do {
            let allowed = try await allowedStatuses(read.projectPath)
            guard let statusID = allowed[name.lowercased()] else {
                log.error("\(display): [backlog.gitlab.status] \(target.rawValue) = \"\(name)\" matches no work-item status allowed in \(read.projectPath); allowed: \(allowed.keys.sorted().joined(separator: ", "))")
                return
            }
            let data: StatusUpdateData = try await client.graphQL(
                "workItemUpdate \(display)", Self.statusMutation(workItem: "gid://gitlab/WorkItem/\(read.issue.id)", status: statusID),
                variables: [:], idempotent: true)
            if let errors = data.workItemUpdate?.errors, !errors.isEmpty {
                log.error("\(display): setting work-item status \"\(name)\" failed: \(errors.joined(separator: "; "))")
            }
        } catch {
            log.error("\(display): setting work-item status \"\(name)\" failed: \(error)")
        }
    }

    /// Lowercased status name to status global id, for the Issue work-item type, cached per project.
    private func allowedStatuses(_ projectPath: String) async throws -> [String: String] {
        if let cached = statusIDs[projectPath.lowercased()] { return cached }
        let data: StatusTypesData = try await client.graphQL("allowed statuses \(projectPath)", Self.statusTypesQuery, variables: ["path": projectPath])
        var map: [String: String] = [:]
        for type in data.project?.workItemTypes.nodes ?? [] {
            for definition in type.widgetDefinitions {
                for status in definition.allowedStatuses ?? [] { map[status.name.lowercased()] = status.id }
            }
        }
        statusIDs[projectPath.lowercased()] = map
        return map
    }

    private struct StatusTypesData: Decodable {
        struct Project: Decodable { var workItemTypes: Types }
        struct Types: Decodable { var nodes: [WorkItemType] }
        struct WorkItemType: Decodable { var widgetDefinitions: [Definition] }
        struct Definition: Decodable { var allowedStatuses: [Status]? }
        struct Status: Decodable { var id: String; var name: String }
        var project: Project?
    }

    private struct StatusUpdateData: Decodable {
        struct Update: Decodable { var errors: [String]? }
        var workItemUpdate: Update?
    }

    static let statusTypesQuery = """
        query($path: ID!) {
          project(fullPath: $path) {
            workItemTypes(name: ISSUE) {
              nodes { widgetDefinitions { ... on WorkItemWidgetDefinitionStatus { allowedStatuses { id name } } } }
            }
          }
        }
        """

    /// Inlines the ids as JSON string literals (valid GraphQL strings), which avoids naming
    /// the schema's id scalar types in variable declarations.
    static func statusMutation(workItem: String, status: String) -> String {
        func literal(_ s: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        return "mutation { workItemUpdate(input: { id: \(literal(workItem)), statusWidget: { status: \(literal(status)) } }) { errors } }"
    }

    private func notesPath(_ issue: GLIssue) -> String { "/projects/\(issue.projectId)/issues/\(issue.iid)/notes" }
    private func eventsPath(_ issue: GLIssue) -> String { "/projects/\(issue.projectId)/issues/\(issue.iid)/resource_label_events" }
}
