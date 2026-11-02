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

    /// A startup dialog that the pane shows, and the keys that answer it.
    public struct DialogAnswer: Sendable, Equatable {
        /// The dialog's name, for the log: `folder trust` or `external CLAUDE.md imports`.
        public var dialog: String
        /// Arrows from the highlighted option (`❯`) to the answer, then Enter. Nil when the pane
        /// shows no recognizable answer option or cursor, so nothing may be pressed.
        public var keys: [String]?

        public init(dialog: String, keys: [String]?) {
            self.dialog = dialog
            self.keys = keys
        }
    }

    /// The claude dialog that can appear before a worker's first turn and that `pane` shows,
    /// with the keys that answer it:
    ///
    /// | Dialog | Answer |
    /// | --- | --- |
    /// | folder trust (B17) | the option starting `Yes` |
    /// | `Allow external CLAUDE.md file imports?` | `No, disable external imports` |
    ///
    /// The keys always move to the answer from the highlighted option, because claude's option
    /// order and default have changed between versions. When the pane holds more than one
    /// dialog (an answered one in scrollback), the lowest one counts. Nil when the pane shows
    /// none, or when claude's input screen is below the dialog, so it is scrollback.
    public static func startupDialog(_ pane: String) -> DialogAnswer? {
        let lines = normalized(pane)
        func last(_ d: KnownDialog) -> Int? { lines.lastIndex { $0.contains(d.title) } }
        guard let (dialog, title) = knownDialogs.compactMap({ d in last(d).map { (d, $0) } }).max(by: { $0.1 < $1.1 }),
              !lines[title...].contains(where: isInputScreen)
        else { return nil }
        let start = knownDialogs.filter { $0.name != dialog.name }.compactMap(last).filter { $0 < title }.max().map { $0 + 1 } ?? 0
        let region = lines[start...]
        guard let cursor = region.lastIndex(where: { $0.hasPrefix("❯") }),
              let answer = region.lastIndex(where: { option($0).hasPrefix(dialog.answer) })
        else { return DialogAnswer(dialog: dialog.name, keys: nil) }
        return DialogAnswer(dialog: dialog.name, keys: Array(repeating: answer > cursor ? "Down" : "Up", count: abs(answer - cursor)) + ["Enter"])
    }

    /// True when claude shows its input screen or works on a turn: its mode footer, shortcut
    /// hint or interrupt hint is on screen.
    public static func showsInputScreen(_ pane: String) -> Bool {
        normalized(pane).contains(where: isInputScreen)
    }

    /// The title line of the dialog that the bottom of the pane shows, or nil when it shows
    /// none. A dialog is a line with `Enter to confirm` or `Esc to cancel`, or a numbered option
    /// under the cursor (`❯ 1.`), among the last 15 non-empty lines and with no input screen
    /// below it. Its title is the last line ending in `?` between the rule or box top above it
    /// and that line, else the first line there; redact it before showing it anywhere, and cut
    /// to 120 characters.
    public static func dialogTitle(_ pane: String) -> String? {
        let tail = Array(normalized(pane).filter { !$0.isEmpty }.suffix(15))
        guard let marker = tail.lastIndex(where: { $0.contains("Enter to confirm") || $0.contains("Esc to cancel") || $0.contains(numberedCursor) }),
              !tail[marker...].contains(where: isInputScreen)
        else { return nil }
        let above = tail[..<marker]
        let start = above.lastIndex { $0.hasPrefix("─") || $0.hasPrefix("╭") }.map { $0 + 1 } ?? above.startIndex
        let block = above[start...].isEmpty ? above : above[start...]
        let title = block.last { $0.hasSuffix("?") } ?? block.first { !$0.hasPrefix("❯") } ?? tail[marker]
        return String(title.prefix(120))
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
    nonisolated(unsafe) private static let knownDialogs = [
        KnownDialog(name: "folder trust", title: trustPrompt, answer: "Yes"),
        KnownDialog(name: "external CLAUDE.md imports", title: #/Allow external CLAUDE\.md file imports/#.ignoresCase(), answer: "No, disable external imports"),
    ]

    nonisolated(unsafe) private static let numberedCursor = #/^❯\s*\d+\./#

    private struct KnownDialog {
        var name: String
        var title: Regex<Substring>
        /// The start of the answer option's text.
        var answer: String
    }

    /// The pane's lines without surrounding whitespace and box sides.
    private static func normalized(_ pane: String) -> [String] {
        pane.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│").union(.whitespaces)) }
    }

    /// An option's text without the cursor and its number: `❯ 2. Yes, proceed` is `Yes, proceed`.
    private static func option(_ line: String) -> Substring {
        line.drop { $0 == "❯" || $0 == " " }.trimmingPrefix(#/\d+\.\s*/#)
    }

    private static func isInputScreen(_ line: String) -> Bool {
        line.contains("mode on (shift+tab") || line.contains("esc to interrupt") || line.contains("? for shortcuts")
    }

    // "⎿" prefixes claude's tool results and rotating tips, which sit below the real line.
    private static let chromePrefixes = ["─", "❯", "⏵", "│", "╭", "╰", "⎿"]
}
