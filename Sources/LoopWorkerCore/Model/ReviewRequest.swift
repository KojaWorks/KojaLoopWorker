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
    /// review request without an assignee gets one too.
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

    public init(name: String, stage: String, url: URL?, logTail: String) {
        self.name = name
        self.stage = stage
        self.url = url
        self.logTail = logTail
    }

    /// How many log lines `logTail` holds at most.
    public static let tailLines = 200

    /// The last `tailLines` lines of `log`.
    public static func tail(_ log: String) -> String {
        log.split(separator: "\n", omittingEmptySubsequences: false).suffix(tailLines).joined(separator: "\n")
    }
}
