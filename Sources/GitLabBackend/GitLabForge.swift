import Foundation
import LoopWorkerCore

/// GitLab as a forge: HTTPS clones authenticated through `GIT_ASKPASS`, merge requests as
/// review requests, project uploads as attachments.
public struct GitLabForge: Forge {
    let client: GitLabClient
    let baseURL: URL
    private let environment: [String: String]

    init(client: GitLabClient, baseURL: URL, gitEnvironment: [String: String]) {
        self.client = client
        self.baseURL = baseURL
        environment = gitEnvironment
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
        if let existing = open.first { return try review(existing, draft.project) }
        let title = Trust.neutralizeQuickActions(draft.title)
        let created: GLMergeRequest = try await client.send("POST", path, body: [
            "source_branch": draft.sourceBranch,
            "target_branch": draft.targetBranch,
            "title": draft.draft ? "Draft: \(title)" : title,
            "description": Trust.neutralizeQuickActions(draft.body),
            "remove_source_branch": "true",
        ], idempotent: false)
        return try review(created, draft.project)
    }

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
                                      logTail: CIJob.tail(Self.stripANSI(trace))))
                }
            }
            return PipelineStatus(state: .failed, url: URL(string: first.webUrl), failedJobs: jobs)
        }
        for s in [PipelineStatus.State.running, .canceled] {
            if let p = latest.first(where: { state($0) == s }) { return PipelineStatus(state: s, url: URL(string: p.webUrl)) }
        }
        return PipelineStatus(state: .passed, url: URL(string: latest[0].webUrl))
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
