import Foundation

/// Reads a worker's pane text, as returned by `TmuxDriving.capture`.
public enum Pane {
    /// True when the pane shows claude's own login prompt after its auth failed
    /// (`Please run /login · API Error` or `Not logged in · Please run /login`). Anchored on
    /// claude's `·` separator, so a pane that merely contains the words, such as a worker
    /// editing this code or printing test output, doesn't match.
    public static func showsAuthFailure(_ pane: String) -> Bool {
        pane.contains(authFailure)
    }

    /// True when the pane shows claude's folder-trust dialog, which the Manager accepts with
    /// `TmuxDriving.sendEnter`.
    public static func showsTrustPrompt(_ pane: String) -> Bool {
        pane.contains(trustPrompt)
    }

    /// What the worker is doing right now, for the status file: the most recent non-empty
    /// line that isn't claude's UI chrome (box drawing, the prompt, the mode footer), cut to
    /// 140 characters. Empty when there is no such line.
    public static func activityLine(_ pane: String) -> String {
        for line in pane.split(whereSeparator: \.isNewline).reversed() {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || chromePrefixes.contains(where: line.hasPrefix) { continue }
            if line.contains("mode on (shift+tab") || line.contains("esc to interrupt") { continue }
            return String(line.prefix(140))
        }
        return ""
    }

    // Regex isn't Sendable, but matching never mutates it (its compiled program is initialized atomically).
    nonisolated(unsafe) private static let authFailure = #/Please run /login\s*·\s*API Error|Not logged in\s*·\s*Please run /login/#.ignoresCase()
    nonisolated(unsafe) private static let trustPrompt = #/trust this folder|Accessing workspace|one you trust|do you trust|trust the files/#.ignoresCase()
    // "⎿" prefixes claude's tool results and rotating tips, which sit below the real line.
    private static let chromePrefixes = ["─", "❯", "⏵", "│", "╭", "╰", "⎿"]
}
