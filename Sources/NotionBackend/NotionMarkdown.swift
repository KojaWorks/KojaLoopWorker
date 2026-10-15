import Foundation
import LoopWorkerCore

/// One body block and, unless it is a child page or database, its children.
struct Block: Sendable {
    var json: JSON
    var children: [Block]

    var id: String { json["id"]?.string ?? "?" }
    var type: String { json["type"]?.string ?? "unknown" }
    var editor: String? { json["last_edited_by"]?["id"]?.string.map { NotionID.normalize($0) ?? $0 } }
    var content: JSON { json[type] ?? .null }
}

/// A page comment.
struct Comment: Sendable, Equatable {
    var id: String
    var author: String
    var created: Date
    var richText: [JSON]
    var text: String { richText.map { $0["plain_text"]?.string ?? $0["text"]?["content"]?.string ?? "" }.joined() }

    init(_ j: JSON) throws {
        guard let id = j["id"]?.string, let author = j["created_by"]?["id"]?.string,
              let created = j["created_time"]?.string.flatMap(NotionTime.parse)
        else { throw NotionError.malformed("a comment without id, created_by or created_time: \(j)") }
        self.id = id
        self.author = NotionID.normalize(author) ?? author
        self.created = created
        richText = j["rich_text"]?.array ?? []
    }
}

enum NotionTime {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()
    static func parse(_ s: String) -> Date? { (try? fractional.parse(s)) ?? (try? whole.parse(s)) }
}

/// The comments that the Manager posts, each under its own header line (B195).
enum ManagerComment: Equatable {
    case claim(host: String, nonce: String)
    case release
    case failedRelease
    case stuck
    case review
    case ci
    case merging
    case merged

    static let claimPrefix = "LoopWorker claimed this card ("
    static let vouchedTitlePrefix = "Vouched title: "

    var header: String {
        switch self {
        case .claim(let host, let nonce): "\(Self.claimPrefix)host \(host), \(nonce))."
        case .release: "LoopWorker released this card:"
        case .failedRelease: "LoopWorker released this card after a failed attempt:"
        case .stuck: "LoopWorker needs a human to unblock this card:"
        case .review: "LoopWorker opened a review request:"
        case .ci: "LoopWorker is waiting for CI on its review request:"
        case .merging: "LoopWorker is merging its review request:"
        case .merged: "LoopWorker merged its review request:"
        }
    }

    /// The kind of a comment's text by its first line; nil when it has no Manager header.
    /// Only call it for comments that the integration wrote.
    static func kind(_ text: String) -> ManagerComment? {
        let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if first.hasPrefix(claimPrefix) { return .claim(host: "", nonce: "") }
        return [.release, .failedRelease, .stuck, .review, .ci, .merging, .merged].first { $0.header == first }
    }

    var isClaim: Bool { if case .claim = self { true } else { false } }
    var isRelease: Bool { self == .release || self == .failedRelease }
    /// A comment of this kind as the integration's newest one leaves a `working` or `ci` card the Manager's.
    var keepsOwnership: Bool { isClaim || isRelease || self == .ci || self == .merging }

    /// The title that a claim comment records as vouched; nil for any other text.
    static func vouchedTitle(_ text: String) -> String? {
        guard kind(text)?.isClaim == true else { return nil }
        let body = body(text)
        return body.hasPrefix(vouchedTitlePrefix) ? String(body.dropFirst(vouchedTitlePrefix.count)) : nil
    }

    /// The text after the header line and the blank line that follows it.
    static func body(_ text: String) -> String {
        let rest = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first ?? ""
        return String(rest.drop { $0 == "\n" })
    }
}

/// Renders a page for the worker, and builds the rich text of the Manager's comments.
enum NotionMarkdown {
    /// Notion's limit on one rich-text object's content.
    static let chunk = 2000
    /// The longest comment text that the Manager posts, in UTF-16 units. 100 rich-text objects
    /// of 2000 would be the API's limit; this stays under the 500 KB request limit too.
    static let maxComment = 150_000

    // MARK: Comments

    /// Rich-text objects for a comment: each segment's text split into objects of at most
    /// `chunk` UTF-16 units, a segment with a URL linked to it. Text over `maxComment` is cut
    /// and ends with a note that says how much was cut.
    static func richText(_ segments: [(text: String, link: URL?)]) -> [JSON] {
        var budget = maxComment
        var cut = 0
        var out: [JSON] = []
        for (text, link) in segments {
            var kept = ""
            var keptUnits = 0
            for ch in text {
                let units = ch.utf16.count
                if keptUnits + units > budget { cut += units; continue }
                kept.append(ch)
                keptUnits += units
            }
            budget -= keptUnits
            out += split(kept).map { object($0, link: link) }
        }
        if cut > 0 {
            out.append(object("\n\n[LoopWorker cut this comment here: \(cut) more characters don't fit in a Notion comment.]", link: nil))
        }
        return out
    }

    private static func object(_ s: String, link: URL?) -> JSON {
        var text: [String: JSON] = ["content": .string(s)]
        if let link { text["link"] = .object(["url": .string(link.absoluteString)]) }
        return .object(["type": .string("text"), "text": .object(text)])
    }

    /// `s` in pieces of at most `chunk` UTF-16 units, never splitting a character.
    static func split(_ s: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var units = 0
        for ch in s {
            let n = ch.utf16.count
            if units + n > chunk {
                pieces.append(current)
                current = ""
                units = 0
            }
            current.append(ch)
            units += n
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: Snapshot

    /// The worker's view of a card (B191): the vouched title, the blocks whose own last editor
    /// is trusted (a withheld block's children are judged one by one), and the comments that a
    /// trusted user wrote. The integration's comments are left out; they reach the worker as
    /// Manager notes. Every withheld block or comment is named in `excluded`, never with its text.
    /// - Parameters:
    ///   - vouchedTitle: The title that the newest claim comment records; nil withholds the title.
    ///   - pageTitle: The page's title now, untrusted; only compared with `vouchedTitle`.
    ///   - comments: Oldest first.
    ///   - names: Display names by user id; a missing name falls back to the id.
    static func snapshot(vouchedTitle: String?, pageTitle: String, blocks: [Block], comments: [Comment], trusted: Set<String>, me: String, names: [String: String]) -> CardSnapshot {
        var excluded: [String] = []
        let name = { (id: String?) in id.map { names[$0] ?? $0 } ?? "an unknown user" }
        var parts: [String] = []
        if let vouchedTitle {
            parts.append("# \(vouchedTitle)")
            if vouchedTitle != pageTitle {
                excluded.append("the page title changed after the vouch; the worker sees the vouched title")
            }
        } else {
            parts.append("# (withheld: no LoopWorker claim comment records a vouched title)")
            excluded.append("the page title, because no LoopWorker claim comment records a vouched title")
        }
        parts += renderBlocks(blocks, trusted: trusted, name: name, excluded: &excluded)

        var commentParts: [String] = []
        for c in comments {
            if c.author == me {
                excluded.append("LoopWorker comment \(c.id)")
            } else if trusted.contains(c.author) {
                commentParts.append("**\(name(c.author))** (\(c.created.formatted(.iso8601))):\n\n\(text(c.richText))")
            } else {
                commentParts.append("(withheld: comment \(c.id) by \(name(c.author)), who is not a trusted user)")
                excluded.append("comment \(c.id) by \(name(c.author)), who is not a trusted user")
            }
        }
        if !commentParts.isEmpty { parts.append("## Comments") }
        parts += commentParts
        return CardSnapshot(markdown: parts.joined(separator: "\n\n") + "\n", excluded: excluded)
    }

    /// Markdown chunks for sibling blocks; consecutive list items share one chunk.
    static func renderBlocks(_ blocks: [Block], trusted: Set<String>, name: (String?) -> String, excluded: inout [String]) -> [String] {
        var chunks: [String] = []
        var previousWasListItem = false
        for b in blocks {
            var lines: [String] = []
            let own: String?
            if let editor = b.editor, trusted.contains(editor) {
                own = render(b)
            } else {
                own = "(withheld: \(b.type) block \(b.id), last edited by \(name(b.editor)), who is not a trusted user)"
                excluded.append("\(b.type) block \(b.id), last edited by \(name(b.editor)), who is not a trusted user")
            }
            if let own { lines.append(own) }
            if b.type == "table" {
                lines.append(table(b.children, trusted: trusted, name: name, excluded: &excluded))
            } else if !b.children.isEmpty {
                let nested = renderBlocks(b.children, trusted: trusted, name: name, excluded: &excluded).joined(separator: "\n\n")
                // Transparent containers (columns, synced blocks) keep their children at this depth.
                lines.append(own == nil ? nested : indent(nested))
            }
            guard !lines.isEmpty else { continue }
            let chunk = lines.joined(separator: "\n")
            let isListItem = ["bulleted_list_item", "numbered_list_item", "to_do", "toggle"].contains(b.type) && own != nil
            if isListItem && previousWasListItem, let last = chunks.popLast() {
                chunks.append(last + "\n" + chunk)
            } else {
                chunks.append(chunk)
            }
            previousWasListItem = isListItem
        }
        return chunks
    }

    private static func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : "  " + $0 }.joined(separator: "\n")
    }

    private static func table(_ rows: [Block], trusted: Set<String>, name: (String?) -> String, excluded: inout [String]) -> String {
        var lines: [String] = []
        var width = 0
        for row in rows {
            let cells = row.content["cells"]?.array ?? []
            width = max(width, cells.count)
            if let editor = row.editor, trusted.contains(editor) {
                lines.append("| " + cells.map { text($0.array).replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |")
            } else {
                lines.append("| (withheld: row \(row.id), last edited by \(name(row.editor)), who is not a trusted user) |")
                excluded.append("table row \(row.id), last edited by \(name(row.editor)), who is not a trusted user")
            }
        }
        guard !lines.isEmpty else { return "" }
        lines.insert("|" + String(repeating: " --- |", count: max(width, 1)), at: 1)
        return lines.joined(separator: "\n")
    }

    /// One block's own markdown, without its children; nil for transparent containers.
    static func render(_ b: Block) -> String? {
        let c = b.content
        let rt = text(c["rich_text"]?.array ?? [])
        switch b.type {
        case "paragraph": return rt
        case "heading_1": return "# " + rt
        case "heading_2": return "## " + rt
        case "heading_3": return "### " + rt
        case "bulleted_list_item", "toggle": return "- " + rt
        case "numbered_list_item": return "1. " + rt
        case "to_do": return (c["checked"]?.bool == true ? "- [x] " : "- [ ] ") + rt
        case "quote": return quoted(rt)
        case "callout":
            let icon = c["icon"]?["emoji"]?.string.map { $0 + " " } ?? ""
            return quoted(icon + rt)
        case "code":
            let code = (c["rich_text"]?.array ?? []).map { $0["plain_text"]?.string ?? "" }.joined()
            let caption = text(c["caption"]?.array ?? [])
            return "```\(c["language"]?.string ?? "")\n\(code)\n```" + (caption.isEmpty ? "" : "\n\(caption)")
        case "divider": return "---"
        case "equation": return "$$\n\(c["expression"]?.string ?? "")\n$$"
        case "child_page": return "[child page: \(c["title"]?.string ?? "untitled")]"
        case "child_database": return "[child database: \(c["title"]?.string ?? "untitled")]"
        case "image", "file", "pdf", "video", "audio":
            let url = c["external"]?["url"]?.string ?? c["file"]?["url"]?.string
            let label = nonEmpty(text(c["caption"]?.array ?? [])) ?? c["name"]?.string ?? b.type
            return url.map { "[\(label)](\($0))" } ?? "[\(b.type): \(label)]"
        case "bookmark", "embed", "link_preview":
            let url = c["url"]?.string ?? ""
            return "[\(nonEmpty(text(c["caption"]?.array ?? [])) ?? url)](\(url))"
        case "table": return nil
        case "column_list", "column", "synced_block": return nil
        default: return "[\(b.type) block not rendered]"
        }
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    private static func quoted(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
    }

    /// Rich text as markdown: bold, italic, strikethrough, code, links and inline equations.
    static func text(_ items: [JSON]) -> String {
        items.map { item in
            if item["type"]?.string == "equation" { return "$\(item["equation"]?["expression"]?.string ?? "")$" }
            // A page's or database's current title is untrusted text, so a mention shows only the link.
            if item["type"]?.string == "mention", let kind = item["mention"]?["type"]?.string, kind == "page" || kind == "database" {
                let target = item["mention"]?[kind]?["id"]?.string.map { "https://www.notion.so/" + $0.replacingOccurrences(of: "-", with: "") }
                return "[linked \(kind)](\(item["href"]?.string ?? target ?? ""))"
            }
            var s = item["plain_text"]?.string ?? item["text"]?["content"]?.string ?? ""
            guard !s.isEmpty else { return "" }
            let a = item["annotations"] ?? .null
            if a["code"]?.bool == true { s = "`\(s)`" }
            if a["bold"]?.bool == true { s = "**\(s)**" }
            if a["italic"]?.bool == true { s = "*\(s)*" }
            if a["strikethrough"]?.bool == true { s = "~~\(s)~~" }
            if let href = item["href"]?.string ?? item["text"]?["link"]?["url"]?.string { s = "[\(s)](\(href))" }
            return s
        }.joined()
    }
}
