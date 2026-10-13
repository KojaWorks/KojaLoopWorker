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

    /// Every card in state `working` in the given projects. The Manager compares this with
    /// its slots to find cards stranded by a Manager or host crash.
    func working(in projects: [ProjectSpec]) async throws -> [Card]

    /// Moves a `ready` card to `working`. Returns false when the card is no longer `ready`
    /// (someone else moved it); the Manager then skips it.
    func claim(_ card: Card) async throws -> Bool

    /// The card's trusted content for the worker. See `CardSnapshot`.
    func snapshot(_ card: Card) async throws -> CardSnapshot

    /// Moves a `working` card to `review` and links the review request from the card.
    func markReview(_ card: Card, review: ReviewRequest) async throws

    /// Moves a `working` card to `stuck` and posts `blocker` (markdown) on the card. The card
    /// stays assigned to its human so it shows up in their queue.
    func markStuck(_ card: Card, blocker: String) async throws

    /// Returns a `working` card to `ready` and posts `reason` on the card so the history shows
    /// why it bounced. When `countsAsAttempt` is true (the worker crashed or hung), the release
    /// is recorded so that later reads report `Card.attempts` one higher; releases caused by
    /// the host (auth failures, Manager restarts) pass false and don't count.
    func release(_ card: Card, reason: String, countsAsAttempt: Bool) async throws
}
