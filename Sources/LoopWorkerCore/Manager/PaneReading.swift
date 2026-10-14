import Foundation

/// How the Manager reads claude's state from a worker's tmux pane. The production values come
/// from the tmux layer's pane parsing; tests pass simple substring checks.
public struct PaneReading: Sendable {
    /// True when the pane shows claude's login or 401 screen.
    public var showsAuthFailure: @Sendable (String) -> Bool
    /// The keys that accept claude's folder-trust dialog, nil when the pane shows none, `[]`
    /// when it shows one that can't be accepted safely. See `Pane.trustPromptKeys`.
    public var trustPromptKeys: @Sendable (String) -> [String]?

    public init(showsAuthFailure: @escaping @Sendable (String) -> Bool, trustPromptKeys: @escaping @Sendable (String) -> [String]?) {
        self.showsAuthFailure = showsAuthFailure
        self.trustPromptKeys = trustPromptKeys
    }

    /// The last `count` non-empty lines of `pane`, trimmed.
    static func tail(_ pane: String, _ count: Int) -> [String] {
        Array(pane.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(count))
    }
}
