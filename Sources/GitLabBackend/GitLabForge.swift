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

    private func review(_ mr: GLMergeRequest, _ project: ProjectSpec) throws -> ReviewRequest {
        guard let url = URL(string: mr.webUrl) else {
            throw GitLabError("merge request \(project.path)!\(mr.iid) has an unusable web_url: \(mr.webUrl)")
        }
        return ReviewRequest(url: url, display: "\(project.path)!\(mr.iid)")
    }

    private func projectPath(_ project: ProjectSpec) -> String { "/projects/\(GitLabPath.encode(project.path))" }
}
