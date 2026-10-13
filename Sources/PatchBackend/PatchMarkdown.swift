import Foundation
import LoopWorkerCore

/// Renders a roadmap row and its page-body blocks as the worker's snapshot.
enum PatchMarkdown {
    /// The `content` key that tags a block the Manager wrote.
    static let markerKey = "loopworker"

    /// `blocks` in body order (`sort`). A block is left out when the Manager wrote it, or when
    /// its last editor (`updated_by`) is not trusted; the title is withheld when the row's
    /// author is not trusted. Each left-out piece is named in `excluded`.
    static func snapshot(title: String, createdBy: String?, blocks: [JSON], trusted: Set<String>) -> CardSnapshot {
        var excluded: [String] = []
        var lines: [String] = []
        if let author = createdBy, trusted.contains(author) {
            lines.append("# \(title)")
        } else {
            lines.append("# (withheld: the card's author \(createdBy ?? "(none)") is not trusted)")
            excluded.append("title, by untrusted author \(createdBy ?? "(none)")")
        }

        let byParent = Dictionary(grouping: blocks) { $0["parent_id"]?.string ?? "" }
        func emit(_ parent: String) {
            for b in byParent[parent] ?? [] {
                let id = b["id"]?.string ?? "?"
                if b["content"]?[markerKey] != nil {
                    excluded.append("LoopWorker note \(id)")
                    continue
                }
                guard let editor = b["updated_by"]?.string, trusted.contains(editor) else {
                    let who = b["updated_by"]?.string ?? "(none)"
                    lines.append("(withheld: block \(id), last edited by \(who), who is not trusted)")
                    excluded.append("block \(id), last edited by untrusted \(who)")
                    continue
                }
                if let md = render(b) { lines.append(md) }
                emit(id)
            }
        }
        emit("")
        return CardSnapshot(markdown: lines.joined(separator: "\n\n") + "\n", excluded: excluded)
    }

    /// One block as markdown; nil for pure containers. Embeds the worker can't read are named.
    static func render(_ b: JSON) -> String? {
        let c = b["content"] ?? .null
        let text = c["text"]?.string ?? ""
        let indent = String(repeating: "  ", count: Int(c["depth"]?.double ?? 0))
        switch b["type"]?.string ?? "" {
        case "text", "callout": return text
        case "heading": return String(repeating: "#", count: min(Int(c["level"]?.double ?? 1), 4) + 1) + " " + text
        case "bullet", "toggle": return indent + "- " + text
        case "numbered": return indent + "1. " + text
        case "todo": return indent + (c["done"]?.bool == true ? "- [x] " : "- [ ] ") + text
        case "quote": return text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        case "code": return "```\(c["language"]?.string ?? "")\n\(text)\n```"
        case "divider": return "---"
        case "bookmark": return c["url"]?.string
        case "image", "file": return "[\(c["alt"]?.string ?? c["name"]?.string ?? "attachment")](\(c["path"]?.string ?? ""))"
        case "table":
            guard case .array(let rows)? = c["rows"], !rows.isEmpty else { return nil }
            let cells = rows.map { row -> String in
                guard case .array(let cs) = row else { return "|" }
                return "| " + cs.map { $0.string ?? "" }.joined(separator: " | ") + " |"
            }
            var width = 0
            if case .array(let cs) = rows[0] { width = cs.count }
            return ([cells[0], "|" + String(repeating: " --- |", count: width)] + cells.dropFirst()).joined(separator: "\n")
        case "columns": return nil
        case let other: return "(\(other) block not shown)"
        }
    }
}
