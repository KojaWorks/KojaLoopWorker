import Foundation

/// What reviewers said on an open review request, for the worker of the card's next review
/// round: the unresolved threads, plus plain comments newer than the Manager's latest note,
/// with only the notes that the trust check accepts. See DESIGN.md "Review rounds".
public struct ReviewFeedback: Sendable, Equatable {
    /// The side of the diff that a line number counts on.
    public enum Side: String, Sendable, Equatable { case new, old }

    /// Where a diff comment points.
    public struct Position: Sendable, Equatable {
        public var path: String
        /// Nil for a comment on the whole file.
        public var line: Int?
        public var side: Side
        /// The commit that the comment was made on; nil when the forge doesn't say.
        public var commit: String?

        public init(path: String, line: Int?, side: Side, commit: String?) {
            self.path = path
            self.line = line
            self.side = side
            self.commit = commit
        }
    }

    public struct Note: Sendable, Equatable {
        /// The author's forge handle, without `@`.
        public var author: String
        public var createdAt: Date
        /// Markdown. A note that the Manager posted has its marker header removed.
        public var body: String
        /// The Manager posted this note in an earlier round: text that a worker wrote, not a
        /// reviewer's.
        public var byLoopWorker: Bool

        public init(author: String, createdAt: Date, body: String, byLoopWorker: Bool = false) {
            self.author = author
            self.createdAt = createdAt
            self.body = body
            self.byLoopWorker = byLoopWorker
        }
    }

    public struct Thread: Sendable, Equatable {
        /// The forge's id for the thread; the worker names it in the outcome's `replies`.
        public var id: String
        /// Nil for a comment that isn't on the diff.
        public var position: Position?
        /// The trusted notes, oldest first.
        public var notes: [Note]

        public init(id: String, position: Position?, notes: [Note]) {
            self.id = id
            self.position = position
            self.notes = notes
        }
    }

    public var threads: [Thread]
    /// One line per note that the trust check left out, saying which and why. Logged by the
    /// Manager and shown to the worker, like `CardSnapshot.excluded`.
    public var withheld: [String]
    /// One line per thread or note that the caps left out or shortened.
    public var cut: [String]

    public init(threads: [Thread] = [], withheld: [String] = [], cut: [String] = []) {
        self.threads = threads
        self.withheld = withheld
        self.cut = cut
    }

    /// Nothing for the worker to see, so its brief gets no review section.
    public var isEmpty: Bool { threads.isEmpty && withheld.isEmpty }

    public static let maxThreads = 50
    public static let maxNoteLength = 4000

    /// Keeps the first `maxThreads` threads, redacts every note body and cuts it to
    /// `maxNoteLength` characters, and adds a line to `cut` for everything left out or shortened.
    public func capped(redact: (String) -> String) -> ReviewFeedback {
        var out = self
        if threads.count > Self.maxThreads {
            out.cut.append("\(threads.count - Self.maxThreads) threads after the first \(Self.maxThreads) were left out")
        }
        out.threads = threads.prefix(Self.maxThreads).map { thread in
            var t = thread
            t.notes = thread.notes.map { note in
                var n = note
                let body = redact(note.body)
                if body.count > Self.maxNoteLength {
                    out.cut.append("a note by @\(note.author) in thread \(thread.id) was cut to \(Self.maxNoteLength) characters")
                }
                n.body = String(body.prefix(Self.maxNoteLength))
                return n
            }
            return t
        }
        return out
    }
}

// MARK: - Selection and trust

extension ReviewFeedback {
    /// How a note's body was last edited.
    public enum Edit: Sendable, Equatable {
        case never
        /// `owner`: the editor is the forge token's user.
        case edited(by: String, owner: Bool, at: Date)
        /// The forge didn't say; the note is withheld.
        case unknown
    }

    /// A note as the forge returned it, before the trust check.
    public struct RawNote: Sendable, Equatable {
        public var id: String
        public var author: String
        /// The author is the forge token's user, the card's owner.
        public var byOwner: Bool
        public var createdAt: Date
        public var body: String
        public var edit: Edit
        /// A note that the forge wrote (a pushed version, a label change); never shown.
        public var system: Bool

        public init(id: String, author: String, byOwner: Bool, createdAt: Date, body: String, edit: Edit, system: Bool = false) {
            self.id = id
            self.author = author
            self.byOwner = byOwner
            self.createdAt = createdAt
            self.body = body
            self.edit = edit
            self.system = system
        }
    }

    /// A thread as the forge returned it. A plain comment is a thread of its own that isn't
    /// resolvable.
    public struct RawThread: Sendable, Equatable {
        public var id: String
        public var position: Position?
        public var resolvable: Bool
        public var resolved: Bool
        public var notes: [RawNote]

        public init(id: String, position: Position?, resolvable: Bool, resolved: Bool, notes: [RawNote]) {
            self.id = id
            self.position = position
            self.resolvable = resolvable
            self.resolved = resolved
            self.notes = notes
        }
    }

    /// Selects the feedback for a round and runs the trust check.
    ///
    /// - A resolvable thread counts while it is unresolved, with all its notes; a resolved one
    ///   means "don't do this" and is skipped.
    /// - A thread that isn't resolvable counts only with its notes created after the Manager's
    ///   latest note on the review request, or after `openedAt` when there is none.
    /// - A note by the owner is trusted unless someone else edited it (after `vouchedAt`, when
    ///   set). Anyone else's note is trusted only when created at or before `vouchedAt` and not
    ///   edited after it by someone other than the owner. A nil `vouchedAt` trusts only the
    ///   owner. A note whose edit history is unknown is withheld.
    /// - The Manager's own notes (the owner's, starting with `ReviewMarker.manager`) keep their
    ///   place with the header removed and `byLoopWorker` set. A thread left with no other
    ///   trusted note is dropped. System notes are ignored.
    ///
    /// - Parameters:
    ///   - owner: The owner's handle, for the withheld lines.
    ///   - openedAt: When the review request was opened.
    public static func build(_ threads: [RawThread], owner: String, openedAt: Date, vouchedAt: Date?) -> ReviewFeedback {
        let isManager = { (n: RawNote) in n.byOwner && ReviewMarker.isManagerNote(n.body) }
        let since = threads.flatMap(\.notes).filter { !$0.system && isManager($0) }.map(\.createdAt).max() ?? openedAt
        var out = ReviewFeedback()
        for thread in threads {
            if thread.resolvable && thread.resolved { continue }
            var notes: [Note] = []
            for raw in thread.notes.sorted(by: { $0.createdAt < $1.createdAt }) where !raw.system {
                let manager = isManager(raw)
                if !thread.resolvable && (manager || raw.createdAt <= since) { continue }
                if let reason = distrust(raw, owner: owner, vouchedAt: vouchedAt) {
                    out.withheld.append("note \(raw.id) by @\(raw.author) in thread \(thread.id): \(reason)")
                    continue
                }
                notes.append(Note(author: raw.author, createdAt: raw.createdAt,
                                  body: manager ? ReviewMarker.text(of: raw.body) : raw.body, byLoopWorker: manager))
            }
            if notes.contains(where: { !$0.byLoopWorker }) {
                out.threads.append(Thread(id: thread.id, position: thread.position, notes: notes))
            }
        }
        return out
    }

    /// Why the trust check withholds `note`, or nil when it is trusted.
    static func distrust(_ note: RawNote, owner: String, vouchedAt: Date?) -> String? {
        func time(_ d: Date) -> String { d.formatted(.iso8601) }
        switch note.edit {
        case .unknown:
            return "its edit history couldn't be read"
        case .edited(let editor, false, let at) where vouchedAt.map({ at > $0 }) ?? true:
            return "edited by @\(editor) at \(time(at))" + (vouchedAt.map { ", after the card was vouched for at \(time($0))" } ?? "")
        default:
            break
        }
        if note.byOwner { return nil }
        guard let vouchedAt else {
            return "only @\(owner)'s notes are trusted, because the backlog records no time when the card was vouched for"
        }
        return note.createdAt <= vouchedAt ? nil : "posted at \(time(note.createdAt)), after the card was vouched for at \(time(vouchedAt))"
    }
}

/// The hidden header that marks what the Manager posts on a review request or a card: the first
/// line is `manager`, more marker lines may follow, and a blank line ends the header. Text that
/// a worker wrote only ever follows that blank line, so a marker inside it is never read as one.
public enum ReviewMarker {
    public static let manager = "<!-- loopworker -->"

    /// Marks the note that the Manager posts for a round that pushed `commit`.
    public static func round(_ commit: String) -> String { "<!-- loopworker:round=\(commit) -->" }

    /// Marks the Manager's reply in `thread` for a round that pushed `commit`.
    public static func reply(_ commit: String, thread: String) -> String {
        "<!-- loopworker:reply=\(commit) thread=\(thread.filter { $0.isLetter || $0.isNumber || "_-".contains($0) }) -->"
    }

    /// `text` under a header of `manager` and `markers`.
    public static func note(_ text: String, markers: [String] = []) -> String {
        ([manager] + markers).joined(separator: "\n") + "\n\n" + text
    }

    /// The header lines of `body`; empty when the body doesn't start with `manager`.
    public static func header(_ body: String) -> [Substring] {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == Substring(manager) else { return [] }
        return Array(lines.prefix { !$0.isEmpty })
    }

    public static func isManagerNote(_ body: String) -> Bool { !header(body).isEmpty }

    /// Whether `body` is a Manager note whose header holds `marker`.
    public static func has(_ marker: String, _ body: String) -> Bool { header(body).contains(Substring(marker)) }

    /// `body` without its header.
    public static func text(of body: String) -> String {
        let header = header(body)
        guard !header.isEmpty else { return body }
        return body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(header.count + 1).joined(separator: "\n")
    }
}
