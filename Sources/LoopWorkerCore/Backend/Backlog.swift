import Foundation

/// Where cards live and change state. See DESIGN.md "Backlog and forge are separate seams".
///
/// Implementations talk to their service over HTTP and never through an MCP. Every read is
/// complete or throws: a page that failed to load must throw, never return a partial list,
/// because the Manager acts on what is missing (a missing card reaps its worker).
/// Expected absences are values, not errors: an empty backlog is `[]`, a deleted card `nil`.
public protocol Backlog: Sendable {
    /// Cards in state `ready` and trusted, for the given projects only, best first
    /// (priority descending, then oldest). Cards outside the configured allowlist or failing
    /// the trust check are never returned; the implementation logs each one it skips once.
    func workable(in projects: [ProjectSpec]) async throws -> [Card]

    /// Re-reads one card. Returns nil when the card no longer exists or has left the
    /// projects this Manager serves.
    func card(_ ref: CardRef) async throws -> Card?

    /// Every card in state `working` in the given projects, with its `holder`. The Manager
    /// compares this with its slots to find cards stranded by a Manager or host crash.
    func working(in projects: [ProjectSpec]) async throws -> [Card]

    /// Every card in state `verifying` in the given projects, with its `holder`. The Manager
    /// resumes watching the CI of those it holds at startup and in the stranded-card sweep.
    func verifying(in projects: [ProjectSpec]) async throws -> [Card]

    /// The Manager's own earlier notes on the card (stuck blockers, release reasons, review
    /// links; not claims), without the backend's header, oldest first; `[]` when there are none. The
    /// Manager hands them to the card's next worker as background, never as card content.
    func managerNotes(_ card: Card) async throws -> [String]

    /// Moves a `ready` card to `working` and records `holder` (`Manager.holder`) on it, so
    /// later reads report it as `Card.holder`. Returns false when the card is no longer `ready`
    /// (someone else moved it); the Manager then skips it. A claim that isn't compare-and-set
    /// may return true while a rival claims too; the newest claim holds the card, so the
    /// Manager re-reads the holder before it spawns.
    func claim(_ card: Card, holder: String) async throws -> Bool

    /// The card's trusted content for the worker. See `CardSnapshot`.
    func snapshot(_ card: Card) async throws -> CardSnapshot

    /// Moves a `working` or `verifying` card to `review` and links the review request from
    /// the card, followed by `note` (markdown) when given, e.g. a link to the CI pipeline
    /// that passed.
    func markReview(_ card: Card, review: ReviewRequest, note: String?) async throws

    /// Moves a `working` card to `verifying`: the review request is open and the Manager
    /// waits for its CI, merges it, or both, as `plan` says. Links the review request from the
    /// card and says what the Manager waits for.
    func markVerifying(_ card: Card, review: ReviewRequest, plan: VerifyingPlan) async throws

    /// Moves a `verifying` card to `review_merged`: the Manager merged its review request.
    /// Links the review request from the card, followed by `note` (markdown) when given, e.g.
    /// the merge commit and the pipeline that passed. The card stays open and assigned to its
    /// human, who still has to look at the result.
    func markMerged(_ card: Card, review: ReviewRequest, note: String?) async throws

    /// Moves a `verifying` card back to `working` for a fix round: one that fixes its failed CI,
    /// or one that rebases its branch onto a base branch that moved.
    /// Returns false, writing nothing, when the card is no longer `verifying` (a human moved
    /// it); the Manager then drops the round.
    func resumeFix(_ card: Card) async throws -> Bool

    /// Moves a `working` or `verifying` card to `stuck` and posts `blocker` (markdown) on the
    /// card under the backend's own header, so `blocker` doesn't repeat one. The card stays
    /// assigned to its human so it shows up in their queue.
    func markStuck(_ card: Card, blocker: String) async throws

    /// Returns a `working` card to `ready` and posts `reason` on the card, under the backend's
    /// own "released" header, so the history shows why it bounced. When `countsAsAttempt` is true (the worker crashed or hung), the release
    /// is recorded so that later reads report `Card.attempts` one higher; releases caused by
    /// the host (auth failures, Manager restarts) pass false and don't count.
    func release(_ card: Card, reason: String, countsAsAttempt: Bool) async throws
}

extension Backlog {
    /// `markReview(_:review:note:)` without a note.
    public func markReview(_ card: Card, review: ReviewRequest) async throws {
        try await markReview(card, review: review, note: nil)
    }
}

/// What the Manager does with a `verifying` card's review request.
public enum VerifyingPlan: String, Sendable, Equatable {
    /// Waits for CI, then moves the card to `review` (`wait_for_ci` with `finish = draft` or `ready`).
    case ciThenReview
    /// Waits for CI, then merges (`finish = ci_then_merge`).
    case ciThenMerge
    /// Merges without waiting for CI (`finish = merge`). The card stays `verifying` only until
    /// the merge lands, or while the forge can't merge yet.
    case merge
}
