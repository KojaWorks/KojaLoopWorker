import Foundation

/// What a worker reports as its last act, by writing JSON to `$LOOPWORKER_OUTCOME`.
///
/// ```json
/// {"outcome": "done", "title": "Add retry to sync", "body": "markdown", "guide": "guide.html",
///  "replies": {"<thread id>": "markdown"}}
/// {"outcome": "stuck", "blocker": "The card doesn't say which endpoint to call."}
/// ```
public enum Outcome: Sendable, Equatable {
    /// The worker committed an implementation on its branch.
    /// - title: the review request title: the first line only, at most `maxTitleLength` characters.
    /// - body: the review request description, markdown. When the review request is already
    ///   open, the Manager posts it as a note on it instead.
    /// - guide: an optional file to attach (a review guide), relative to the slot's state directory.
    /// - replies: for a review round, the reply to post in each review thread, by thread id.
    case done(title: String, body: String, guide: String?, replies: [String: String] = [:])
    /// The worker can't proceed without a human. `blocker` is posted on the card.
    case stuck(blocker: String)

    /// Parses an outcome file. A file that exists but can't be parsed is not an error: the
    /// worker did stop, so it becomes `stuck` with the parse failure as the blocker, and the
    /// card lands in front of a human instead of being retried blindly.
    /// Forges cap titles (GitLab at 255); a longer one would fail every finish attempt.
    public static let maxTitleLength = 200

    public static func parse(_ data: Data) -> Outcome {
        struct Raw: Decodable {
            var outcome: String
            var title: String?
            var body: String?
            var guide: String?
            var blocker: String?
            var replies: [String: String]?
        }
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            return .stuck(blocker: "The worker's outcome file is not valid JSON: \(error)")
        }
        switch raw.outcome {
        case "done":
            let title = (raw.title ?? "").split(whereSeparator: \.isNewline).first
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(maxTitleLength)) } ?? ""
            guard !title.isEmpty else {
                return .stuck(blocker: "The worker reported done without a review request title.")
            }
            return .done(title: title, body: raw.body ?? "", guide: raw.guide, replies: raw.replies ?? [:])
        case "stuck":
            return .stuck(blocker: raw.blocker ?? "The worker reported stuck without saying why.")
        default:
            return .stuck(blocker: "The worker's outcome file has unknown outcome \"\(raw.outcome)\".")
        }
    }
}
