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
    /// order and default have changed between versions. The dialog is the block between the
    /// last footer line (`Enter to confirm` or `Esc to cancel`) and the footer before it; the
    /// cursor and the answer must sit below the dialog's title and above that footer. When the
    /// block holds both titles, external imports wins. A title below the last footer belongs to a
    /// dialog that is still drawing, so it has no keys yet. Nil when the pane shows no known
    /// dialog, or when claude's input screen is below it, so it is scrollback.
    public static func startupDialog(_ pane: String) -> DialogAnswer? {
        let lines = normalized(pane)
        let footers = lines.indices.filter { isFooter(lines[$0]) }
        if let (dialog, title) = knownTitle(in: (footers.last.map { $0 + 1 } ?? 0)..<lines.count, lines) {
            return lines[title...].contains(where: isInputScreen) ? nil : DialogAnswer(dialog: dialog.name, keys: nil)
        }
        guard let footer = footers.last, !lines[footer...].contains(where: isInputScreen),
              let (dialog, title) = knownTitle(in: (footers.dropLast().last.map { $0 + 1 } ?? 0)..<footer, lines)
        else { return nil }
        let options = lines[(title + 1)..<footer]
        guard let cursor = options.lastIndex(where: { $0.hasPrefix("❯") }),
              let answer = options.lastIndex(where: { option($0).hasPrefix(dialog.answer) })
        else { return DialogAnswer(dialog: dialog.name, keys: nil) }
        return DialogAnswer(dialog: dialog.name, keys: Array(repeating: answer > cursor ? "Down" : "Up", count: abs(answer - cursor)) + ["Enter"])
    }

    /// True when claude shows its input screen or works on a turn: a line holds its interrupt
    /// hint (` to interrupt`), its mode-cycle hint (` to cycle)`) or a mode label (`auto mode on`,
    /// `accept edits on`, `plan mode on`, `bypass permissions on`). Key names aren't matched,
    /// because keybindings.json can remap them.
    public static func showsInputScreen(_ pane: String) -> Bool {
        normalized(pane).contains(where: isInputScreen)
    }

    /// The title that `dialogTitle` gives a dialog without a question line.
    public static let unrecognizedDialog = "an unrecognized dialog"

    /// The title line of the dialog that the bottom of the pane shows, or nil when it shows
    /// none. A dialog is a line with `Enter to confirm` or `Esc to cancel`, or a numbered option
    /// under the cursor (`❯ 1.`), among the last 15 non-empty lines and with no input screen
    /// below it. Its title is the last line ending in `?` between the rule or box top above it
    /// and that line, uncut; without one it is `unrecognizedDialog`, never another transcript
    /// line. The title is pane text: redact it before cutting or showing it anywhere.
    public static func dialogTitle(_ pane: String) -> String? {
        let tail = Array(normalized(pane).filter { !$0.isEmpty }.suffix(15))
        guard let marker = tail.lastIndex(where: { isFooter($0) || $0.contains(numberedCursor) }),
              !tail[marker...].contains(where: isInputScreen)
        else { return nil }
        let above = tail[..<marker]
        let start = above.lastIndex { $0.hasPrefix("─") || $0.hasPrefix("╭") }.map { $0 + 1 } ?? above.startIndex
        let block = above[start...].isEmpty ? above : above[start...]
        return block.last { $0.hasSuffix("?") } ?? unrecognizedDialog
    }

    /// True when the dialog at the bottom of the pane is claude's usage-limit menu: its title is
    /// `What do you want to do?` and an option starts with one of claude's usage-limit choices
    /// (`Stop and wait for limit to reset`, `Wait for limit to reset`, `Upgrade your plan`,
    /// `Ask your admin for more usage`, `Add funds to continue`), as in claude 2.1.316 and
    /// 2.1.322. It comes from the host's account, not from any card.
    public static func showsUsageLimitMenu(_ pane: String) -> Bool {
        guard dialogTitle(pane) == "What do you want to do?" else { return false }
        return normalized(pane).suffix(15).contains { line in usageLimitOptions.contains { option(line).hasPrefix($0) } }
    }

    /// What the worker is doing right now, for the status file: the most recent non-empty
    /// line that isn't claude's UI chrome (box drawing, the prompt, the mode footer), cut to
    /// 140 characters. Empty when there is no such line.
    public static func activityLine(_ pane: String) -> String {
        for line in pane.split(whereSeparator: \.isNewline).reversed() {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || chromePrefixes.contains(where: line.hasPrefix) { continue }
            if isInputScreen(line) { continue }
            return String(line.prefix(140))
        }
        return ""
    }

    // Regex isn't Sendable, but matching never mutates it (its compiled program is initialized atomically).
    nonisolated(unsafe) private static let authFailure = #/Please run /login\s*·\s*API Error|Not logged in\s*·\s*Please run /login/#.ignoresCase()
    // In priority order: an imports dialog's body may quote anything, including a trust line.
    nonisolated(unsafe) private static let knownDialogs = [
        KnownDialog(name: "external CLAUDE.md imports", title: #/^Allow external CLAUDE\.md file imports\?/#.ignoresCase(), answer: "No, disable external imports"),
        KnownDialog(name: "folder trust", title: #/^(?:Accessing workspace|Quick safety check|Do you trust the files in this folder)/#.ignoresCase(), answer: "Yes"),
    ]

    nonisolated(unsafe) private static let numberedCursor = #/^❯\s*\d+\./#

    private static let usageLimitOptions = [
        "Stop and wait for limit to reset", "Wait for limit to reset", "Upgrade your plan", "Ask your admin for more usage", "Add funds to continue",
    ]

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

    /// The first known dialog whose title is in `range` of `lines`, with its title's last line there.
    private static func knownTitle(in range: Range<Int>, _ lines: [String]) -> (KnownDialog, Int)? {
        for d in knownDialogs {
            if let t = lines[range].lastIndex(where: { $0.contains(d.title) }) { return (d, t) }
        }
        return nil
    }

    private static func isFooter(_ line: String) -> Bool {
        line.contains("Enter to confirm") || line.contains("Esc to cancel")
    }

    /// claude's interrupt hint, mode-cycle hint or mode label. Key names stay out: keybindings.json remaps them.
    private static func isInputScreen(_ line: String) -> Bool {
        [" to interrupt", " to cycle)", "auto mode on", "accept edits on", "plan mode on", "bypass permissions on"].contains(where: line.contains)
    }

    // "⎿" prefixes claude's tool results and rotating tips, which sit below the real line.
    private static let chromePrefixes = ["─", "❯", "⏵", "│", "╭", "╰", "⎿"]
}
