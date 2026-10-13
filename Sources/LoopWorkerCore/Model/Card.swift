import Foundation

/// A card's stable identity, owned by its backlog.
///
/// The Manager never parses `id`; it only compares it and hands it back to the backlog that
/// produced it. `display` is what logs, notes and the status file show a human.
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
}

/// The Manager's normalized view of where a card is in the loop. Each backlog maps its own
/// statuses and labels onto these; see DESIGN.md "Card states".
public enum CardState: String, Sendable, Codable, CaseIterable {
    /// Trusted and waiting to be claimed.
    case ready
    /// Claimed by this Manager; a worker should be running for it.
    case working
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
    /// The `ProjectSpec.path` of the project this card belongs to.
    public var project: String
    public var title: String
    public var state: CardState
    /// Higher is sooner. Backlogs without priorities report 0.
    public var priority: Double
    /// CLI model alias that overrides the project's default for this card only.
    public var model: String?
    /// How many times the Manager has claimed this card before. Drives the poison-card guard:
    /// at `max_attempts` a crash marks the card stuck instead of releasing it.
    public var attempts: Int
    /// The card in the backlog's web UI.
    public var url: URL?

    public init(
        ref: CardRef, project: String, title: String, state: CardState,
        priority: Double = 0, model: String? = nil, attempts: Int = 0, url: URL? = nil
    ) {
        self.ref = ref
        self.project = project
        self.title = title
        self.state = state
        self.priority = priority
        self.model = model
        self.attempts = attempts
        self.url = url
    }
}

/// The trusted content of a card, rendered for the worker.
public struct CardSnapshot: Sendable, Equatable {
    /// Title, description and trusted comments as one markdown document.
    public var markdown: String
    /// One line per piece of content that the trust check left out, saying what and why,
    /// e.g. "comment 4411 by @someone, posted after the loopworker:next label". Logged by the
    /// Manager and appended to the snapshot so the worker knows something was withheld.
    public var excluded: [String]

    public init(markdown: String, excluded: [String] = []) {
        self.markdown = markdown
        self.excluded = excluded
    }
}
