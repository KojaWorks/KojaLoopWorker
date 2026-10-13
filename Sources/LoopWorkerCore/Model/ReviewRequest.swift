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

    public init(
        project: ProjectSpec, card: Card, sourceBranch: String, targetBranch: String,
        title: String, body: String, draft: Bool
    ) {
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
