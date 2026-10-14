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

    /// True when the pane shows claude's folder-trust dialog.
    public static func showsTrustPrompt(_ pane: String) -> Bool {
        pane.contains(trustPrompt)
    }

    /// The keys that accept claude's folder-trust dialog shown in `pane`: arrows from the
    /// highlighted option (`❯`) to the "Yes" option, then Enter. Claude's option order has
    /// changed between versions, so plain Enter may pick "No, exit". Returns nil when the pane
    /// shows no trust dialog, and `[]` when it shows one without a recognizable "Yes" option
    /// or cursor, so the caller presses nothing.
    public static func trustPromptKeys(_ pane: String) -> [String]? {
        guard showsTrustPrompt(pane) else { return nil }
        let lines = pane.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let cursor = lines.lastIndex(where: { $0.hasPrefix("❯") }),
              let yes = lines.lastIndex(where: { $0.drop(while: { $0 == "❯" || $0 == " " }).hasPrefix("Yes") })
        else { return [] }
        let arrows = Array(repeating: yes > cursor ? "Down" : "Up", count: abs(yes - cursor))
        return arrows + ["Enter"]
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
