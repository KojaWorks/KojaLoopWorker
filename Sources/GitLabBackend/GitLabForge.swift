import Foundation
import LoopWorkerCore

/// GitLab as a forge: HTTPS clones authenticated through `GIT_ASKPASS`, merge requests as
/// review requests, project uploads as attachments.
public struct GitLabForge: Forge {
    let client: GitLabClient
    let baseURL: URL
    private let environment: [String: String]
    let log: LogSink

    init(client: GitLabClient, baseURL: URL, gitEnvironment: [String: String], log: LogSink) {
        self.client = client
        self.baseURL = baseURL
        environment = gitEnvironment
        self.log = log
    }

    public func cloneURL(for project: ProjectSpec) -> String {
        "\(baseURL.absoluteString)/\(project.path).git"
    }

    public func gitEnvironment() -> [String: String] { environment }

    public func defaultBranch(for project: ProjectSpec) async throws -> String {
        let p: GLProject = try await client.get(projectPath(project))
        guard let branch = p.defaultBranch, !branch.isEmpty else {
            throw GitLabError("\(project.path) has no default branch; push one or set base_branch in config.toml")
        }
        return branch
    }

    public func openReviewRequest(for project: ProjectSpec, sourceBranch: String) async throws -> ReviewRequest? {
        try await openMergeRequests(project, sourceBranch).first.map { try review($0, project) }
    }

    private func openMergeRequests(_ project: ProjectSpec, _ sourceBranch: String) async throws -> [GLMergeRequest] {
        try await client.getAll(projectPath(project) + "/merge_requests", query: [("state", "opened"), ("source_branch", sourceBranch)])
    }

    public func openReviewRequest(_ draft: ReviewRequestDraft) async throws -> ReviewRequest {
        let path = projectPath(draft.project) + "/merge_requests"
        let open = try await openMergeRequests(draft.project, draft.sourceBranch)
        var assignee: [String: String] = [:]
        if draft.assignToOwner {
            // GitLab coerces the string to the integer that assignee_id takes.
            do { assignee = ["assignee_id": String(try await client.me().id)] }
            catch { log.warning("can't read the token's user to assign the merge request for \(draft.project.path) \(draft.sourceBranch): \(error); leaving it unassigned") }
        }
        if let existing = open.first {
            let review = try review(existing, draft.project)
            if !assignee.isEmpty, existing.assignees?.isEmpty ?? true {
                do { let _: GLMergeRequest = try await client.send("PUT", "\(path)/\(existing.iid)", body: assignee, idempotent: true) }
                catch { log.warning("can't assign \(review.display) (\(review.url.absoluteString)) to the token's user: \(error); leaving it unassigned") }
            }
            return review
        }
        let title = Trust.neutralizeQuickActions(draft.title)
        let created: GLMergeRequest = try await client.send("POST", path, body: [
            "source_branch": draft.sourceBranch,
            "target_branch": draft.targetBranch,
            "title": draft.draft ? "Draft: \(title)" : title,
            "description": Trust.neutralizeQuickActions(draft.body) + (draft.marker.map { "\n\n" + $0 } ?? ""),
            "remove_source_branch": "true",
        ].merging(assignee) { a, _ in a }, idempotent: false)
        return try review(created, draft.project)
    }

    /// `PUT .../merge_requests/:iid/merge` with `sha`, and nothing that would squash, delete the
    /// branch or wait for a pipeline. A refusal (405, 406, 409, 422) or an answer that isn't
    /// merged re-reads the merge request: `merged` is merged, `locked` (merging) pending, any
    /// other state but `opened` blocked; a 409 is a moved head; otherwise
    /// `detailed_merge_status` decides. GitLab answers 401 both for a bad token and for a user
    /// that may not merge, so a 401 or 403 re-reads `/user`: a token that GitLab accepts makes
    /// it a missing merge permission, `blocked`; a rejected one throws the token error.
    public func merge(_ review: ReviewRequest, project: ProjectSpec, head: String) async throws -> MergeResult {
        guard let iid = Int(review.url.lastPathComponent), iid > 0 else {
            throw BackendRejection("can't merge \(review.display): \(review.url.absoluteString) doesn't end in a merge request number")
        }
        let path = projectPath(project) + "/merge_requests/\(iid)"
        var refusal: GitLabRefusal?
        do {
            let mr: GLMergeRequest = try await client.send(
                "PUT", path + "/merge", body: ["sha": head], idempotent: true, refusals: [401, 403, 405, 406, 409, 422])
            if mr.state == "merged" { return .merged(commit: mr.mergeCommitSha) }
        } catch let r as GitLabRefusal { refusal = r }
        var forbiddenTo: GLUser?
        if let r = refusal, r.status == 401 || r.status == 403 {
            forbiddenTo = try await tokenUser(rejecting: r, where_: "PUT \(path)/merge")
        }
        let mr: GLMergeRequest = try await client.get(path)
        switch mr.state {
        case "merged": return .merged(commit: mr.mergeCommitSha)
        case "locked": return .pending("GitLab: locked (the merge is in progress)")
        case "opened": break
        default: return .blocked("GitLab: \(mr.state ?? "no state") (the merge request isn't open)")
        }
        if refusal?.status == 409 { return .blocked("GitLab: the source branch's head moved past \(head.prefix(12))") }
        if let user = forbiddenTo, let refusal {
            return .blocked(await mergeForbidden(user, refusal, into: mr.targetBranch, project))
        }
        let status = mr.detailedMergeStatus ?? "no detailed_merge_status"
        let reason = "GitLab: \(status)" + (Self.mergeStatusGloss[status].map { " (\($0))" } ?? "")
        switch status {
        case "mergeable": return .pending(reason + (refusal.map { ", but the merge answered \($0)" } ?? ""))
        case "checking", "unchecked", "preparing", "ci_still_running", "approvals_syncing": return .pending(reason)
        case "conflict", "need_rebase": return .outdated(reason)
        default: return .blocked(reason)
        }
    }

    /// The token's user, read afresh; throws the token error for `where_` when GitLab rejects the token.
    private func tokenUser(rejecting refusal: GitLabRefusal, where_: String) async throws -> GLUser {
        if refusal.message.contains("insufficient_scope") { throw await client.tokenRejected(where_, refusal) }
        do { return try await client.get("/user", refusals: [401, 403]) }
        catch is GitLabRefusal { throw await client.tokenRejected(where_, refusal) }
    }

    /// Names who may merge into `branch` when its protected branch rule is readable (it needs
    /// the Maintainer role), else the rule or the user's role as the cause.
    private func mergeForbidden(_ user: GLUser, _ refusal: GitLabRefusal, into branch: String?, _ project: ProjectSpec) async -> String {
        let who = "GitLab: @\(user.username) may not merge into \(branch ?? "the target branch")"
        let tail = " (the merge answered \(refusal))"
        guard let branch else { return who + tail }
        let rulePath = projectPath(project) + "/protected_branches/" + GitLabPath.encode(branch)
        var rule: GLProtectedBranch?
        do { rule = try await client.getIfFound(rulePath, refusals: [401, 403]) }
        catch is GitLabRefusal {}  // below Maintainer: the reason names the role instead
        catch { log.warning("can't read who may merge into \(branch) of \(project.path): \(error)") }
        let allowed = (rule?.mergeAccessLevels ?? []).compactMap(\.accessLevelDescription)
        guard !allowed.isEmpty else {
            return who + "; its protected branch rule or @\(user.username)'s role in \(project.path) decides who may" + tail
        }
        return who + "; its protected branch rule allows \(allowed.joined(separator: ", "))" + tail
    }

    static let mergeStatusGloss = [
        "approvals_syncing": "approvals are syncing",
        "checking": "GitLab is checking whether it can merge",
        "unchecked": "GitLab hasn't checked whether it can merge yet",
        "preparing": "GitLab is preparing the diff",
        "ci_still_running": "a pipeline still runs",
        "mergeable": "it can merge",
        "conflict": "it conflicts with the target branch",
        "need_rebase": "it must be rebased onto the target branch",
        "not_approved": "the merge request needs approvals",
        "ci_must_pass": "a pipeline must pass first",
        "discussions_not_resolved": "threads must be resolved first",
        "draft_status": "the merge request is a draft",
        "requested_changes": "a reviewer requested changes",
        "merge_request_blocked": "another merge request blocks it",
        "blocked_status": "another merge request blocks it",
        "status_checks_must_pass": "external status checks must pass",
        "external_status_checks": "external status checks must pass",
        "commits_status": "the source branch is missing or has no commits",
        "merge_time": "it may not merge before a set time",
        "not_open": "the merge request isn't open",
    ]

    /// Reads `GET .../merge_requests/:iid/discussions` for the threads and the merge request's
    /// notes over GraphQL for who last edited each one. A null `lastEditedBy` means no content
    /// edit, whatever `lastEditedAt` says; a note that GraphQL doesn't return is withheld as unknown.
    public func reviewFeedback(for review: ReviewRequest, project: ProjectSpec, vouchedAt: Date?) async throws -> ReviewFeedback {
        let path = try mergeRequestPath(review, project)
        let me = try await client.me()
        let mr: GLMergeRequest = try await client.get(path)
        guard let opened = mr.createdAt else { throw GitLabError("GET \(path): \(review.display) has no created_at") }
        let discussions: [GLDiscussion] = try await client.getAll(path + "/discussions")
        let edits = try await noteEdits(review, project)
        let threads = discussions.map { d in
            let resolvable = d.notes.filter { $0.resolvable == true }
            return ReviewFeedback.RawThread(
                id: d.id, position: d.notes.first?.position.flatMap(Self.position), resolvable: !resolvable.isEmpty,
                resolved: !resolvable.isEmpty && resolvable.allSatisfy { $0.resolved == true },
                notes: d.notes.map { n in
                    let edit: ReviewFeedback.Edit
                    switch edits[n.id] {
                    case nil: edit = .unknown
                    case let e?:
                        if let by = e.lastEditedBy, let at = e.lastEditedAt {
                            edit = .edited(by: by.username, owner: by.numericID == me.id, at: at)
                        } else { edit = .never }
                    }
                    return ReviewFeedback.RawNote(id: String(n.id), author: n.author.username, byOwner: n.author.id == me.id,
                                                  createdAt: n.createdAt, body: n.body, edit: edit, system: n.system)
                })
        }
        return ReviewFeedback.build(threads, owner: me.username, openedAt: opened, vouchedAt: vouchedAt)
    }

    public func postReviewNote(_ text: String, marker: String, on review: ReviewRequest, project: ProjectSpec) async throws -> Bool {
        let path = try mergeRequestPath(review, project)
        let mr: GLMergeRequest = try await client.get(path)
        if mr.description?.contains(marker) == true { return false }
        let me = try await client.me()
        let notes: [GLNote] = try await client.getAll(path + "/notes")
        if notes.contains(where: { $0.author.id == me.id && ReviewMarker.has(marker, $0.body) }) { return false }
        let _: GLNote = try await client.send("POST", path + "/notes", body: [
            "body": ReviewMarker.note(Trust.neutralizeQuickActions(text), markers: [marker]),
        ], idempotent: false)
        return true
    }

    /// A thread gets `POST .../discussions/:id/notes`. A single comment gets a new merge
    /// request note that links it instead, because replying would turn it into a resolvable
    /// thread that comes back every round.
    public func replyToThread(_ thread: String, text: String, marker: String, on review: ReviewRequest, project: ProjectSpec) async throws -> ThreadReply {
        let mr = try mergeRequestPath(review, project)
        let path = mr + "/discussions/\(GitLabPath.encode(thread))"
        guard let discussion: GLDiscussion = try await client.getIfFound(path) else { return .noSuchThread }
        let me = try await client.me()
        let mine = { (notes: [(author: GLUser, body: String)]) in notes.contains { $0.author.id == me.id && ReviewMarker.has(marker, $0.body) } }
        let neutral = Trust.neutralizeQuickActions(text)
        if discussion.individualNote, let comment = discussion.notes.first {
            let notes: [GLNote] = try await client.getAll(mr + "/notes")
            if mine(notes.map { ($0.author, $0.body) }) { return .alreadyPosted }
            let link = "[@\(comment.author.username)'s comment](\(review.url.absoluteString)#note_\(comment.id))"
            let _: GLNote = try await client.send("POST", mr + "/notes", body: [
                "body": ReviewMarker.note("In reply to \(link):\n\n\(neutral)", markers: [marker]),
            ], idempotent: false)
            return .posted
        }
        if mine(discussion.notes.map { ($0.author, $0.body) }) { return .alreadyPosted }
        let _: GLNote = try await client.send("POST", path + "/notes", body: [
            "body": ReviewMarker.note(neutral, markers: [marker]),
        ], idempotent: false)
        return .posted
    }

    static func position(_ p: GLDiscussion.Position) -> ReviewFeedback.Position? {
        if let path = p.newPath ?? p.oldPath, let line = p.newLine {
            return .init(path: path, line: line, side: .new, commit: p.headSha)
        }
        guard let path = p.oldPath ?? p.newPath else { return nil }
        return .init(path: path, line: p.oldLine, side: .old, commit: p.headSha)
    }

    /// Every note of the merge request with its last edit, by note id.
    private func noteEdits(_ review: ReviewRequest, _ project: ProjectSpec) async throws -> [Int: GQLMergeRequestNotesPage.Edit] {
        var edits: [Int: GQLMergeRequestNotesPage.Edit] = [:]
        var after: String?
        repeat {
            var variables = ["path": project.path, "iid": String(try iid(review))]
            if let after { variables["after"] = after }
            let page: GQLMergeRequestNotesPage = try await client.graphQL("merge request notes \(review.display)", Self.notesQuery, variables: variables)
            guard let notes = page.project?.mergeRequest?.notes else {
                throw GitLabError("\(review.display): GraphQL returned no merge request notes")
            }
            for e in notes.nodes { if let id = e.numericID { edits[id] = e } }
            after = notes.pageInfo.hasNextPage ? notes.pageInfo.endCursor : nil
        } while after != nil
        return edits
    }

    static let notesQuery = """
        query($path: ID!, $iid: String!, $after: String) {
          project(fullPath: $path) {
            mergeRequest(iid: $iid) {
              notes(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { id lastEditedAt lastEditedBy { id username } }
              }
            }
          }
        }
        """

    public func attach(_ file: URL, to project: ProjectSpec) async throws -> URL? {
        let upload = try await client.upload(projectPath(project) + "/uploads", file: file)
        let relative = upload.fullPath ?? "/\(project.path)\(upload.url)"
        guard let url = URL(string: baseURL.absoluteString + relative) else {
            throw GitLabError("upload of \(file.lastPathComponent) to \(project.path) returned an unusable path: \(relative)")
        }
        return url
    }

    /// The commit's pipelines, read as one: the newest per (ref, source) among the 20 newest,
    /// leaving out child pipelines (their parent reflects them). Any failed is failed, with the
    /// failed jobs of each failed pipeline (jobs allowed to fail left out); else any running
    /// is running; else any canceled is canceled; else passed. `success`, `skipped` and
    /// `manual` pass, other statuses run.
    public func pipeline(for project: ProjectSpec, commit: String) async throws -> PipelineStatus? {
        let base = projectPath(project)
        let all: [GLPipeline] = try await client.get(base + "/pipelines", query: [
            ("sha", commit), ("order_by", "id"), ("sort", "desc"), ("per_page", "20"),
        ])
        var seen: Set<String> = []
        let latest = all.filter { $0.source != "parent_pipeline" && seen.insert("\($0.ref ?? "")|\($0.source ?? "")").inserted }
        guard !latest.isEmpty else { return nil }
        func state(_ p: GLPipeline) -> PipelineStatus.State {
            switch p.status {
            case "success", "skipped", "manual": .passed
            case "failed": .failed
            case "canceled": .canceled
            default: .running
            }
        }
        let failed = latest.filter { state($0) == .failed }
        if let first = failed.first {
            var jobs: [CIJob] = []
            for p in failed {
                let listed: [GLJob] = try await client.getAll(base + "/pipelines/\(p.id)/jobs", query: [("scope[]", "failed")])
                for job in listed where !job.allowFailure {
                    let trace: String
                    do { trace = try await client.textIfFound(base + "/jobs/\(job.id)/trace") ?? "(GitLab has no log for this job)" }
                    catch { trace = "(LoopWorker couldn't read this job's log: \(error))" }
                    jobs.append(CIJob(name: job.name, stage: job.stage, url: URL(string: job.webUrl),
                                      logTail: CIJob.tail(Self.stripANSI(trace)), id: String(job.id)))
                }
            }
            return PipelineStatus(state: .failed, url: URL(string: first.webUrl), failedJobs: jobs)
        }
        for s in [PipelineStatus.State.running, .canceled] {
            if let p = latest.first(where: { state($0) == s }) { return PipelineStatus(state: s, url: URL(string: p.webUrl)) }
        }
        return PipelineStatus(state: .passed, url: URL(string: latest[0].webUrl))
    }

    /// Reads the newest of the 20 latest pipelines on `ref` that succeeded or failed, child
    /// pipelines left out, and maps each named job's latest attempt there: `success` passed,
    /// `failed` failed, any other status unknown.
    public func baselineJobs(for project: ProjectSpec, ref: String, names: [String]) async throws -> [String: CIJobBaseline] {
        var result = Dictionary(names.map { ($0, CIJobBaseline.unknown) }, uniquingKeysWith: { a, _ in a })
        let base = projectPath(project)
        let recent: [GLPipeline] = try await client.get(base + "/pipelines", query: [
            ("ref", ref), ("order_by", "id"), ("sort", "desc"), ("per_page", "20"),
        ])
        guard let finished = recent.first(where: { $0.source != "parent_pipeline" && ["success", "failed"].contains($0.status) }) else {
            return result
        }
        let jobs: [GLJob] = try await client.getAll(base + "/pipelines/\(finished.id)/jobs")
        for job in jobs.sorted(by: { $0.id < $1.id }) where result[job.name] != nil {
            let url = URL(string: job.webUrl)
            result[job.name] = switch job.status {
            case "success": .passed(url)
            case "failed": .failed(url)
            default: .unknown
            }
        }
        return result
    }

    /// `POST /projects/:id/jobs/:job_id/retry` per job, which puts the pipeline back to running.
    public func retryJobs(project: ProjectSpec, jobs: [CIJob]) async throws -> Bool {
        let ids = jobs.compactMap(\.id)
        guard ids.count == jobs.count else { return false }
        struct Retried: Decodable { var id: Int }
        for id in ids {
            let _: Retried = try await client.send("POST", projectPath(project) + "/jobs/\(id)/retry", body: [:], idempotent: false)
        }
        return true
    }

    /// Removes what GitLab traces carry besides the job's output: terminal color and erase
    /// sequences, the runner's per-line timestamp prefix (`2026-10-14T16:59:46.845Z 00O+ `) and
    /// collapsible-section markers, so the tail the worker reads is mostly real output.
    static func stripANSI(_ text: String) -> String {
        // Markers go first, while the "\r" after each still ends its name. Foundation's replace
        // works on code units; Swift's treats "\r\n" as one Character.
        text.replacing(/section_(start|end):\d+:[A-Za-z0-9_\-]+(\[[^\]]*\])?/, with: "")
            .replacing(/\x{1B}\[[0-9;?]*[A-Za-z]/, with: "")
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/^\d{4}-\d\d-\d\dT[\d:.]+Z \d+[OE]\+? ?/, with: "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    private func review(_ mr: GLMergeRequest, _ project: ProjectSpec) throws -> ReviewRequest {
        guard let url = URL(string: mr.webUrl) else {
            throw GitLabError("merge request \(project.path)!\(mr.iid) has an unusable web_url: \(mr.webUrl)")
        }
        return ReviewRequest(url: url, display: "\(project.path)!\(mr.iid)")
    }

    /// The iid in a display that `review(_:_:)` made, `<path>!<iid>`.
    private func iid(_ review: ReviewRequest) throws -> Int {
        guard let iid = review.display.split(separator: "!").last.flatMap({ Int($0) }) else {
            throw GitLabError("\(review.display) (\(review.url.absoluteString)) doesn't name a merge request as <path>!<iid>")
        }
        return iid
    }

    private func mergeRequestPath(_ review: ReviewRequest, _ project: ProjectSpec) throws -> String {
        "\(projectPath(project))/merge_requests/\(try iid(review))"
    }

    private func projectPath(_ project: ProjectSpec) -> String { "/projects/\(GitLabPath.encode(project.path))" }
}
