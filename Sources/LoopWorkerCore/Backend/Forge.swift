import Foundation

/// Where code is pushed and reviewed. Independent of the backlog: a Patch backlog can feed a
/// GitHub forge. See DESIGN.md "Backlog and forge are separate seams".
public protocol Forge: Sendable {
    /// The URL the Manager clones and pushes with. Must not embed credentials.
    func cloneURL(for project: ProjectSpec) -> String

    /// Environment for every git process that talks to this forge, e.g. `GIT_ASKPASS` plus
    /// the variables its helper reads. Credentials never appear in argv or in remote URLs.
    func gitEnvironment() -> [String: String]

    /// The project's default branch, used when `ProjectSpec.baseBranch` is nil.
    func defaultBranch(for project: ProjectSpec) async throws -> String

    /// Opens a review request for an already pushed branch. Idempotent: if one is already
    /// open for `draft.sourceBranch`, returns it unchanged, so a finish retried after a
    /// Manager restart never opens a duplicate.
    func openReviewRequest(_ draft: ReviewRequestDraft) async throws -> ReviewRequest

    /// The latest CI pipeline for `commit` in `project`, whatever triggered it (a push of the
    /// branch or the review request), or nil when none exists yet. A re-run or a newer
    /// pipeline for the same commit replaces an older one. Fetches failed jobs and their log
    /// tails only when the pipeline failed.
    /// - Throws: when the forge can't be read; a later poll retries.
    func pipeline(for project: ProjectSpec, commit: String) async throws -> PipelineStatus?

    /// Uploads a file and returns a URL that the review request body can link to, or nil
    /// when the forge has no attachments. The Manager then leaves the link out.
    func attach(_ file: URL, to project: ProjectSpec) async throws -> URL?
}
