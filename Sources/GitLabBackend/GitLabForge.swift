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

    public func openReviewRequest(_ draft: ReviewRequestDraft) async throws -> ReviewRequest {
        let path = projectPath(draft.project) + "/merge_requests"
        let open: [GLMergeRequest] = try await client.getAll(path, query: [("state", "opened"), ("source_branch", draft.sourceBranch)])
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
            "description": Trust.neutralizeQuickActions(draft.body),
            "remove_source_branch": "true",
        ].merging(assignee) { a, _ in a }, idempotent: false)
        return try review(created, draft.project)
    }

    /// `PUT .../merge_requests/:iid/merge` with `sha`, and nothing that would squash, delete the
    /// branch or wait for a pipeline. A refusal (405, 406, 409, 422) or an answer that isn't
    /// merged re-reads the merge request: `merged` is merged, `locked` (merging) pending, any
    /// other state but `opened` blocked; a 409 is a moved head; otherwise
    /// `detailed_merge_status` decides.
    public func merge(_ review: ReviewRequest, project: ProjectSpec, head: String) async throws -> MergeResult {
        guard let iid = Int(review.url.lastPathComponent), iid > 0 else {
            throw BackendRejection("can't merge \(review.display): \(review.url.absoluteString) doesn't end in a merge request number")
        }
        let path = projectPath(project) + "/merge_requests/\(iid)"
        var refusal: GitLabRefusal?
        do {
            let mr: GLMergeRequest = try await client.send(
                "PUT", path + "/merge", body: ["sha": head], idempotent: true, refusals: [405, 406, 409, 422])
            if mr.state == "merged" { return .merged(commit: mr.mergeCommitSha) }
        } catch let r as GitLabRefusal { refusal = r }
        let mr: GLMergeRequest = try await client.get(path)
        switch mr.state {
        case "merged": return .merged(commit: mr.mergeCommitSha)
        case "locked": return .pending("GitLab: locked (the merge is in progress)")
        case "opened": break
        default: return .blocked("GitLab: \(mr.state ?? "no state") (the merge request isn't open)")
        }
        if refusal?.status == 409 { return .blocked("GitLab: the source branch's head moved past \(head.prefix(12))") }
        let status = mr.detailedMergeStatus ?? "no detailed_merge_status"
        let reason = "GitLab: \(status)" + (Self.mergeStatusGloss[status].map { " (\($0))" } ?? "")
        switch status {
        case "mergeable": return .pending(reason + (refusal.map { ", but the merge answered \($0)" } ?? ""))
        case "checking", "unchecked", "preparing", "ci_still_running", "approvals_syncing": return .pending(reason)
        case "conflict", "need_rebase": return .outdated(reason)
        default: return .blocked(reason)
        }
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

    private func projectPath(_ project: ProjectSpec) -> String { "/projects/\(GitLabPath.encode(project.path))" }
}
