import Foundation

/// How the Manager reads claude's state from a worker's tmux pane. The production values come
/// from the tmux layer's pane parsing; tests pass simple substring checks.
public struct PaneReading: Sendable {
    /// True when the pane shows claude's login or 401 screen.
    public var showsAuthFailure: @Sendable (String) -> Bool
    /// True when the pane shows claude's folder-trust dialog.
    public var showsTrustPrompt: @Sendable (String) -> Bool

    public init(showsAuthFailure: @escaping @Sendable (String) -> Bool, showsTrustPrompt: @escaping @Sendable (String) -> Bool) {
        self.showsAuthFailure = showsAuthFailure
        self.showsTrustPrompt = showsTrustPrompt
    }

    /// The last `count` non-empty lines of `pane`, trimmed.
    static func tail(_ pane: String, _ count: Int) -> [String] {
        Array(pane.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(count))
    }
}
