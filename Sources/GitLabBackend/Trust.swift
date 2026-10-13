import Foundation
import LoopWorkerCore

/// The trust rules of DESIGN.md "Trust", as pure functions over what GitLab returned.
enum Trust {
    static let managerMarker = "<!-- loopworker -->"
    static let failedAttemptMarker = "<!-- loopworker:failed-attempt -->"
    static let cutoffMarkerPrefix = "<!-- loopworker:cutoff="
    /// A `next` label added this soon after a release note by me is that release's re-add.
    static let releaseWindow: TimeInterval = 120

    enum Verdict: Equatable {
        case trusted(cutoff: Date)
        case untrusted(String)
    }

    /// Whether `issue` (which carries the `next` label) is trusted, and its cutoff.
    /// `notes` and `events` are complete lists in any order. The allowlist is checked by the caller.
    static func check(issue: GLIssue, me: GLUser, nextLabel: String, notes: [GLNote], events: [GLLabelEvent]) -> Verdict {
        guard issue.assignees?.contains(where: { $0.id == me.id }) == true else {
            return .untrusted("not assigned to @\(me.username)")
        }
        let assignment = notes
            .filter { $0.system && assigns($0.body, to: me.username) }
            .max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        if let assignment {
            guard assignment.author.id == me.id else {
                return .untrusted("@\(assignment.author.username) assigned it to @\(me.username)")
            }
        } else if issue.author.id != me.id {
            // No system note: the assignment was part of creating the issue, so its author made it.
            return .untrusted("@\(issue.author.username) created it already assigned to @\(me.username)")
        }
        switch cutoff(issue: issue, me: me, nextLabel: nextLabel, notes: notes, events: events) {
        case .success(let date): return .trusted(cutoff: date)
        case .failure(let reason): return .untrusted(reason.description)
        }
    }

    struct Refusal: Error, CustomStringConvertible { var description: String }

    /// The trust cutoff: when I last added the `next` label, or, when that add was a release
    /// re-adding it, the cutoff recorded in that release's note.
    static func cutoff(issue: GLIssue, me: GLUser, nextLabel: String, notes: [GLNote], events: [GLLabelEvent]) -> Result<Date, Refusal> {
        let latest = events
            .filter { $0.action == "add" && $0.label?.name == nextLabel }
            .max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        guard let latest else {
            // Labels set while creating an issue may have no event; only its author could set them.
            if issue.labels.contains(nextLabel), issue.author.id == me.id { return .success(issue.createdAt) }
            return .failure(Refusal(description: "no \(nextLabel) label event by @\(me.username)"))
        }
        guard let user = latest.user, user.id == me.id else {
            return .failure(Refusal(description: "\(nextLabel) was last added by @\(latest.user?.username ?? "a deleted user")"))
        }
        let release = notes
            .filter {
                $0.author.id == me.id && !$0.system && managerHeader($0.body).contains { $0.hasPrefix(cutoffMarkerPrefix) }
                    && $0.createdAt <= latest.createdAt
                    && latest.createdAt.timeIntervalSince($0.createdAt) <= releaseWindow
            }
            .max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        guard let release else { return .success(latest.createdAt) }
        guard let recorded = recordedCutoff(release.body) else {
            return .failure(Refusal(description: "release note \(release.id) has an unreadable cutoff"))
        }
        return .success(recorded)
    }

    static func recordedCutoff(_ body: String) -> Date? {
        guard let line = managerHeader(body).first(where: { $0.hasPrefix(cutoffMarkerPrefix) && $0.hasSuffix(" -->") })
        else { return nil }
        return GitLabTime.parse(String(line.dropFirst(cutoffMarkerPrefix.count).dropLast(4)))
    }

    /// The marker lines of a note the Manager posted: from its first line, the Manager marker,
    /// up to the first blank line. Worker-written text only ever follows that blank line, so a
    /// marker inside it is never read as one.
    static func managerHeader(_ body: String) -> [Substring] {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == Substring(managerMarker) else { return [] }
        return Array(lines.prefix { !$0.isEmpty })
    }

    static func countsAsAttempt(_ note: GLNote, me: GLUser) -> Bool {
        note.author.id == me.id && managerHeader(note.body).contains(Substring(failedAttemptMarker))
    }

    /// Whether a system note body assigns `username`: "assigned to @a", "assigned to @a and @b",
    /// "assigned to @a and unassigned @b". Mentions after "unassigned" don't count.
    static func assigns(_ body: String, to username: String) -> Bool {
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        guard let start = firstLine.range(of: "assigned to ") else { return false }
        var segment = firstLine[start.upperBound...]
        if let unassigned = segment.range(of: "unassigned") { segment = segment[..<unassigned.lowerBound] }
        return mentions(in: segment).contains(username.lowercased())
    }

    private static func mentions(in text: Substring) -> [String] {
        var out: [String] = []
        var current: String?
        for ch in text {
            if ch == "@" { if let c = current { out.append(c) }; current = "" }
            else if current != nil, ch.isASCII, ch.isLetter || ch.isNumber || "_.-".contains(ch) { current! += String(ch).lowercased() }
            else if let c = current { out.append(c); current = nil }
        }
        if let c = current { out.append(c) }
        return out.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
    }

    /// Renders the trusted content of an issue. `notes` in any order; system notes are ignored.
    static func snapshot(content: GQLIssueContent, notes: [GQLNote], me: GLUser, cutoff: Date) -> CardSnapshot {
        var excluded: [String] = []
        func name(_ u: GQLUser?) -> String { "@" + (u?.username ?? "ghost") }
        func time(_ d: Date) -> String { GitLabTime.format(d) }
        let isMe = { (u: GQLUser?) in u?.numericID == me.id }

        let titleTrusted: Bool
        let reason: String
        if let edited = content.lastEditedAt {
            titleTrusted = isMe(content.lastEditedBy) || edited <= cutoff
            reason = "last edited by \(name(content.lastEditedBy)) at \(time(edited)), after the card was approved"
        } else {
            titleTrusted = isMe(content.author) || content.createdAt <= cutoff
            reason = "created by \(name(content.author)) at \(time(content.createdAt)), after the card was approved"
        }
        var md: String
        if titleTrusted {
            let description = content.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            md = "# \(content.title)\n\n\(description.isEmpty ? "(no description)" : description)\n"
        } else {
            md = "# (withheld: \(reason))\n\n(withheld: \(reason))\n"
            excluded.append("title and description: \(reason)")
        }

        var comments: [String] = []
        for note in notes.filter({ !$0.system }).sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
            let id = note.numericID
            let by = "comment \(id) by \(name(note.author)) at \(time(note.createdAt))"
            if note.body.contains(managerMarker) {
                excluded.append("\(by): posted by LoopWorker")
                continue
            }
            let editedLate = note.lastEditedAt.map { $0 > cutoff } ?? false
            let mine = isMe(note.author) && (!editedLate || isMe(note.lastEditedBy))
            let early = note.createdAt <= cutoff && !editedLate
            guard mine || early else {
                if let edited = note.lastEditedAt, editedLate, note.createdAt <= cutoff {
                    excluded.append("\(by), edited by \(name(note.lastEditedBy)) at \(time(edited))")
                } else {
                    excluded.append(by)
                }
                continue
            }
            comments.append("**\(name(note.author))** (\(time(note.createdAt))):\n\n\(note.body.trimmingCharacters(in: .whitespacesAndNewlines))\n")
        }
        if !comments.isEmpty { md += "\n## Comments\n\n" + comments.joined(separator: "\n") }
        return CardSnapshot(markdown: md, excluded: excluded)
    }

    /// Escapes the `/` of every line whose first non-space character is `/`, so GitLab shows a
    /// quick action (`/merge`, `/label`) in text we post instead of executing it. `\/` renders as `/`.
    static func neutralizeQuickActions(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var atLineStart = true
        for scalar in text.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                atLineStart = true
            } else if atLineStart {
                if scalar == "/" { out.append("\\") ; atLineStart = false }
                else if !CharacterSet.whitespaces.contains(scalar) { atLineStart = false }
            }
            out.append(scalar)
        }
        return String(out)
    }
}
