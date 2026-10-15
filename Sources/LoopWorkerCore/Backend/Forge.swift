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
    /// open for `draft.sourceBranch`, returns it, so a finish retried after a Manager restart
    /// never opens a duplicate; the only change made to it is the assignee that
    /// `draft.assignToOwner` asks for when it has none. A failed assignment is logged and
    /// leaves the review request unassigned; it never fails the call. A new review request's
    /// description ends with `draft.marker`, so `postReviewNote` with that marker posts nothing.
    func openReviewRequest(_ draft: ReviewRequestDraft) async throws -> ReviewRequest

    /// The open review request whose source branch is `sourceBranch`, or nil when none is open.
    func openReviewRequest(for project: ProjectSpec, sourceBranch: String) async throws -> ReviewRequest?

    /// What reviewers said on `review`, selected and trust-checked by `ReviewFeedback.build`:
    /// the unresolved threads and the plain comments newer than the Manager's latest note, with
    /// notes trusted against `vouchedAt` (`CardSnapshot.vouchedAt`) and the forge token's user
    /// as the owner. Not capped or redacted; the Manager does that.
    /// - Throws: when any part can't be read; never returns partial feedback.
    func reviewFeedback(for review: ReviewRequest, project: ProjectSpec, vouchedAt: Date?) async throws -> ReviewFeedback

    /// Posts `text` (markdown) as a note on `review`, under the Manager's header with `marker`
    /// (`ReviewMarker.round`).
    /// - Returns: false, posting nothing, when the description or a note by the forge token's
    ///   user already carries `marker`, so a retried finish doesn't post twice.
    func postReviewNote(_ text: String, marker: String, on review: ReviewRequest, project: ProjectSpec) async throws -> Bool

    /// Replies `text` (markdown) in thread `thread` of `review` (an id from `reviewFeedback`),
    /// under the Manager's header with `marker` (`ReviewMarker.reply`). Never resolves the
    /// thread: that is the reviewer's call.
    /// - Returns: `.alreadyPosted`, posting nothing, when a note by the forge token's user
    ///   already carries `marker`; `.noSuchThread` when `review` has no such thread.
    func replyToThread(_ thread: String, text: String, marker: String, on review: ReviewRequest, project: ProjectSpec) async throws -> ThreadReply

    /// The latest CI pipeline for `commit` in `project`, whatever triggered it (a push of the
    /// branch or the review request), or nil when none exists yet. A re-run or a newer
    /// pipeline for the same commit replaces an older one. Fetches failed jobs and their log
    /// tails only when the pipeline failed.
    /// - Throws: when the forge can't be read; a later poll retries.
    func pipeline(for project: ProjectSpec, commit: String) async throws -> PipelineStatus?

    /// How each job named in `names` did on branch `ref`, for telling a pre-existing failure
    /// from a new one. GitLab reads the latest pipeline on `ref` that succeeded or failed (the
    /// latest attempt per job name); GitHub reads the latest completed check runs on the head
    /// commit of `ref`. Every name in `names` is a key of the result; a name without a passed
    /// or failed job there is `.unknown`.
    /// - Throws: when the forge can't be read; the Manager then treats every job as `.unknown`.
    func baselineJobs(for project: ProjectSpec, ref: String, names: [String]) async throws -> [String: CIJobBaseline]

    /// Re-runs failed `jobs` from `pipeline(for:commit:)` in place, so that the next read of
    /// that commit's pipeline reflects the new attempts.
    /// - Returns: false, with nothing re-run, when some job can't be re-run (its `id` is nil).
    /// - Throws: when the forge refuses or can't be reached.
    func retryJobs(project: ProjectSpec, jobs: [CIJob]) async throws -> Bool

    /// Uploads a file and returns a URL that the review request body can link to, or nil
    /// when the forge has no attachments. The Manager then leaves the link out.
    func attach(_ file: URL, to project: ProjectSpec) async throws -> URL?
}
