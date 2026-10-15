import Foundation

/// A project the Manager serves, as declared by a `[[project]]` table in the host config.
public struct ProjectSpec: Sendable, Hashable {
    /// The forge path, e.g. `group/sub/app`. Also the key the backlog uses to route cards.
    public var path: String
    /// Weighted slot target. Hot projects keep this many slots provisioned; cold projects
    /// provision up to this many on demand.
    public var slots: Int
    public var hot: Bool
    /// Relative cost of one slot against the host's `max_slots` budget.
    public var weight: Double
    /// CLI model alias for workers on this project; nil leaves the `claude` default.
    public var model: String?
    /// Host-local project contract directory. When set it replaces the repo's `.loopworker/`.
    public var contract: String?
    /// Branch that slots reset to and review requests target; nil means the forge's default.
    public var baseBranch: String?
    /// How a finished card's review request ends. Host config only: a repo or a worker must
    /// never be able to opt itself into a merge.
    public var finish: FinishMode
    /// Names of Manager environment variables forwarded to this project's workers. Host config
    /// only: a repo's contract must not be able to widen what reaches a worker.
    public var workerEnv: [String]

    public init(
        path: String, slots: Int = 1, hot: Bool = false, weight: Double = 1,
        model: String? = nil, contract: String? = nil, baseBranch: String? = nil,
        finish: FinishMode = .draft, workerEnv: [String] = []
    ) {
        self.path = path
        self.slots = slots
        self.hot = hot
        self.weight = weight
        self.model = model
        self.contract = contract
        self.baseBranch = baseBranch
        self.finish = finish
        self.workerEnv = workerEnv
    }

    /// A filesystem- and tmux-safe name derived from `path`: lowercase ASCII letters, digits
    /// and `-`, with each `/` becoming `--`. Used for directories and session names. Config
    /// loading rejects two projects with the same key.
    public var key: String {
        var out = ""
        for ch in path.lowercased() {
            if ch == "/" { out += "--" }
            else if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) }
            else { out.append("-") }
        }
        return out
    }
}

/// How the Manager ends a `done` card, set per project by `finish` in the host config.
public enum FinishMode: String, Sendable, Hashable, CaseIterable {
    /// Opens a draft review request and moves the card to `review`.
    case draft
    /// Opens a review request that is ready for review and moves the card to `review`.
    case ready
    /// Opens a review request, merges it into the base branch without waiting for CI, and moves
    /// the card to `review_merged`. Ignores the contract's `wait_for_ci`.
    case merge
    /// Opens a review request, waits for the pushed commit's pipeline (with fix rounds, like
    /// `wait_for_ci`), merges once it passes, and moves the card to `review_merged`.
    case ciThenMerge = "ci_then_merge"

    /// True for the modes that merge the review request.
    public var merges: Bool { self == .merge || self == .ciThenMerge }

    /// The review request opens as a draft. Merging modes open it ready, since a forge
    /// refuses to merge a draft.
    public var opensDraft: Bool { self == .draft }

    /// Whether a finished card waits for CI, given the contract's `[review] wait_for_ci`.
    public func waitsForCI(contractWaitForCI: Bool) -> Bool {
        switch self {
        case .draft, .ready: contractWaitForCI
        case .merge: false
        case .ciThenMerge: true
        }
    }
}
