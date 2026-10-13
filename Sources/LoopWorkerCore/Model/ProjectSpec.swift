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
    /// Open review requests as drafts. Defaults to true.
    public var draftReviewRequests: Bool

    public init(
        path: String, slots: Int = 1, hot: Bool = false, weight: Double = 1,
        model: String? = nil, contract: String? = nil, baseBranch: String? = nil,
        draftReviewRequests: Bool = true
    ) {
        self.path = path
        self.slots = slots
        self.hot = hot
        self.weight = weight
        self.model = model
        self.contract = contract
        self.baseBranch = baseBranch
        self.draftReviewRequests = draftReviewRequests
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
