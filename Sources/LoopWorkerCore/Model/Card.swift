import Foundation

/// A card's stable identity, owned by its backlog.
///
/// The Manager never parses `id`; it only compares it and hands it back to the backlog that
/// produced it. `display` is what logs, notes and the status file show a human; it can change
/// (a renamed prefix), so it plays no part in equality.
public struct CardRef: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Backlog-specific and stable for the card's lifetime, e.g. the GitLab global issue id.
    public var id: String
    /// Human-readable reference in the backlog's own notation, e.g. `group/app#12` or `~802`.
    public var display: String

    public init(id: String, display: String) {
        self.id = id
        self.display = display
    }

    public var description: String { display }

    /// Equal by `id` alone: a backlog may show the same card under a new `display`.
    public static func == (a: CardRef, b: CardRef) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The Manager's normalized view of where a card is in the loop. Each backlog maps its own
/// statuses and labels onto these; see DESIGN.md "Card states".
public enum CardState: String, Sendable, Codable, CaseIterable {
    /// Trusted and waiting to be claimed.
    case ready
    /// Claimed by this Manager; a worker should be running for it.
    case working
    /// The review request exists and the Manager waits for its CI before moving the card to
    /// `review` (projects with `[review] wait_for_ci`). No worker runs and no slot is held.
    case verifying
    /// Finished; a review request exists.
    case review
    /// A worker gave up and needs a human.
    case stuck
    /// Anything the loop doesn't own. Never claimed, never reaped on its own account.
    case other
}

/// One unit of work, as last read from its backlog.
public struct Card: Sendable, Equatable {
    public var ref: CardRef
    /// The `ProjectSpec.path` of the project this card belongs to, in the backlog's own case.
    /// Compare it with `ProjectSpec.key` semantics (case-insensitive), not byte for byte.
    public var project: String
    /// The card's number in its backlog's notation without the sigil (`12` for `group/app#12`,
    /// `802` for `~802`), used in branch names. Nil when the backlog has no numbers.
    public var number: String?
    /// Untrusted when the snapshot withheld it: render it only after the trust check.
    public var title: String
    public var state: CardState
    /// Higher is sooner. Backlogs without priorities report 0.
    public var priority: Double
    /// CLI model alias that overrides the project's default for this card only.
    public var model: String?
    /// Failed attempts: releases recorded with `countsAsAttempt`. Drives the poison-card
    /// guard: a crash that would reach `max_attempts` marks the card stuck instead.
    public var attempts: Int
    /// The card in the backlog's web UI.
    public var url: URL?
    /// The holder id (`Manager.holder`) of the Manager that holds a `working` or `verifying`
    /// card: the one named by the card's newest claim. Nil when a release followed that claim,
    /// when a LoopWorker without holder ids claimed it, and in every other state.
    public var holder: String?

    public init(
        ref: CardRef, project: String, number: String? = nil, title: String, state: CardState,
        priority: Double = 0, model: String? = nil, attempts: Int = 0, url: URL? = nil, holder: String? = nil
    ) {
        self.ref = ref
        self.project = project
        self.number = number
        self.title = title
        self.state = state
        self.priority = priority
        self.model = model
        self.attempts = attempts
        self.url = url
        self.holder = holder
    }
}

/// The trusted content of a card, rendered for the worker.
public struct CardSnapshot: Sendable, Equatable {
    /// Title, description and trusted comments as one markdown document. Withheld parts are
    /// replaced by a placeholder that says so.
    public var markdown: String
    /// One line per piece of content that the trust check left out, saying what and why,
    /// e.g. "comment 4411 by @someone, posted after the loopworker:next label". Logged by the
    /// Manager and appended to the snapshot so the worker knows something was withheld.
    public var excluded: [String]
    /// When the card's owner last vouched for it, for the trust check on review feedback:
    /// reviewers' notes from before it are trusted. Nil when the backlog has no such moment;
    /// then only the owner's own notes are.
    public var vouchedAt: Date?

    public init(markdown: String, excluded: [String] = [], vouchedAt: Date? = nil) {
        self.markdown = markdown
        self.excluded = excluded
        self.vouchedAt = vouchedAt
    }
}
