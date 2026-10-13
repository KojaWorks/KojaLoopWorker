import Foundation

/// Reading claude's state from a worker's tmux pane.
public enum PaneText {
    // Anchored on the `·` separator of claude's own chrome, so a worker editing this code or
    // printing these words in test output is not misread as logged out.
    private static let authFailure = try! NSRegularExpression(
        pattern: #"Please run /login\s*·\s*API Error|Not logged in\s*·\s*Please run /login"#,
        options: .caseInsensitive)
    private static let folderTrust = try! NSRegularExpression(
        pattern: "trust this folder|Accessing workspace|one you trust|do you trust|trust the files",
        options: .caseInsensitive)

    /// True when the pane shows claude's login or 401 screen.
    public static func showsAuthFailure(_ pane: String) -> Bool { matches(authFailure, pane) }

    /// True when the pane shows claude's folder-trust dialog.
    public static func showsFolderTrust(_ pane: String) -> Bool { matches(folderTrust, pane) }

    /// The last `count` non-empty lines of `pane`.
    public static func tail(_ pane: String, _ count: Int) -> [String] {
        Array(pane.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(count))
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
