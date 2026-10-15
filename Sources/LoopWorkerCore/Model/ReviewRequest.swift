import Foundation

/// Everything a forge needs to open a review request for a finished card.
public struct ReviewRequestDraft: Sendable, Equatable {
    public var project: ProjectSpec
    public var card: Card
    public var sourceBranch: String
    public var targetBranch: String
    public var title: String
    /// Markdown. The Manager has already appended the guide link and the card reference.
    public var body: String
    public var draft: Bool
    /// Assign the review request to the forge token's user, who owns the card. An open
    /// review request without an assignee gets one too. Best effort: the forge logs a failure.
    public var assignToOwner: Bool

    public init(
        project: ProjectSpec, card: Card, sourceBranch: String, targetBranch: String,
        title: String, body: String, draft: Bool, assignToOwner: Bool = false
    ) {
        self.assignToOwner = assignToOwner
        self.project = project
        self.card = card
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.title = title
        self.body = body
        self.draft = draft
    }
}

/// An opened review request (a GitLab merge request, a GitHub pull request).
public struct ReviewRequest: Sendable, Equatable, Codable {
    public var url: URL
    /// The forge's own notation, e.g. `group/app!34` or `owner/repo#34`.
    public var display: String

    public init(url: URL, display: String) {
        self.url = url
        self.display = display
    }
}

/// The latest CI pipeline that a forge ran for one commit. A re-run or a newer pipeline for
/// the same commit replaces the older one.
public struct PipelineStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        /// Created, pending, scheduled or running: not finished yet.
        case running
        /// Succeeded, was skipped, or waits only on manual jobs.
        case passed
        case failed
        case canceled
    }

    public var state: State
    /// The pipeline (or the commit's checks) in the forge's web UI.
    public var url: URL?
    /// The jobs that failed, for `.failed` only; jobs allowed to fail are left out.
    public var failedJobs: [CIJob]

    public init(state: State, url: URL?, failedJobs: [CIJob] = []) {
        self.state = state
        self.url = url
        self.failedJobs = failedJobs
    }
}

/// A failed CI job. Every field comes from CI output and is untrusted.
public struct CIJob: Sendable, Equatable {
    public var name: String
    /// The pipeline stage; empty when the forge has none.
    public var stage: String
    public var url: URL?
    /// The last lines of the job's log, unredacted.
    public var logTail: String
    /// The forge's id for `Forge.retryJobs`; nil when the forge can't re-run this job.
    public var id: String?

    public init(name: String, stage: String, url: URL?, logTail: String, id: String? = nil) {
        self.name = name
        self.stage = stage
        self.url = url
        self.logTail = logTail
        self.id = id
    }

    /// How many log lines `logTail` holds at most.
    public static let tailLines = 200

    /// The last `tailLines` lines of `log`.
    public static func tail(_ log: String) -> String {
        log.split(separator: "\n", omittingEmptySubsequences: false).suffix(tailLines).joined(separator: "\n")
    }
}

/// How the job of the same name did on the base branch. Tells a failure that the change caused
/// from one that the base branch already has.
public enum CIJobBaseline: Sendable, Equatable {
    /// The job passed on the base branch; the URL is that job's.
    case passed(URL?)
    /// The job failed on the base branch too; the URL is that job's.
    case failed(URL?)
    /// The base branch has no passed or failed job of that name, or it couldn't be read.
    case unknown
}

/// What `Forge.merge` did, or why the forge refused. Each refusal names the forge's own
/// reason (GitLab's `detailed_merge_status`, GitHub's `mergeable_state`) for the log and the
/// card's blocker.
public enum MergeResult: Sendable, Equatable {
    /// The review request is merged, by this call or earlier. The merge commit when the forge
    /// reports one.
    case merged(commit: String?)
    /// The forge can't decide yet: it is still computing mergeability, or a pipeline that the
    /// project requires still runs. Trying again later may merge.
    case pending(String)
    /// The target branch moved: the change conflicts with it, or the forge requires the source
    /// branch to be rebased onto it first. A rebase round may fix it.
    case outdated(String)
    /// A rule refuses the merge, and a rebase won't change that: missing approvals, branch
    /// protection, a draft, unresolved threads, a required pipeline that failed, a head that
    /// moved past `head`, or a closed review request.
    case blocked(String)
}
