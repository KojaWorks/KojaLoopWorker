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

    /// The newest pipeline for `commit`, whatever triggered it. `success`, `skipped` and
    /// `manual` pass; failed jobs that may fail are left out of `failedJobs`.
    public func pipeline(for project: ProjectSpec, commit: String) async throws -> PipelineStatus? {
        let base = projectPath(project)
        let pipelines: [GLPipeline] = try await client.get(base + "/pipelines", query: [
            ("sha", commit), ("order_by", "id"), ("sort", "desc"), ("per_page", "1"),
        ])
        guard let p = pipelines.first else { return nil }
        let url = URL(string: p.webUrl)
        switch p.status {
        case "success", "skipped", "manual":
            return PipelineStatus(state: .passed, url: url)
        case "canceled":
            return PipelineStatus(state: .canceled, url: url)
        case "failed":
            let jobs: [GLJob] = try await client.getAll(base + "/pipelines/\(p.id)/jobs", query: [("scope[]", "failed")])
            var failed: [CIJob] = []
            for job in jobs where !job.allowFailure {
                let trace = try await client.textIfFound(base + "/jobs/\(job.id)/trace") ?? "(GitLab has no log for this job)"
                failed.append(CIJob(name: job.name, stage: job.stage, url: URL(string: job.webUrl),
                                    logTail: CIJob.tail(Self.stripANSI(trace))))
            }
            return PipelineStatus(state: .failed, url: url, failedJobs: failed)
        default:
            return PipelineStatus(state: .running, url: url)
        }
    }

    /// Removes terminal color and erase sequences, which GitLab traces are full of.
    static func stripANSI(_ text: String) -> String {
        text.replacing(/\x{1B}\[[0-9;?]*[A-Za-z]/, with: "")
    }

    private func review(_ mr: GLMergeRequest, _ project: ProjectSpec) throws -> ReviewRequest {
        guard let url = URL(string: mr.webUrl) else {
            throw GitLabError("merge request \(project.path)!\(mr.iid) has an unusable web_url: \(mr.webUrl)")
        }
        return ReviewRequest(url: url, display: "\(project.path)!\(mr.iid)")
    }

    private func projectPath(_ project: ProjectSpec) -> String { "/projects/\(GitLabPath.encode(project.path))" }
}
