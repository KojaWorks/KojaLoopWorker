import Foundation
import LoopWorkerCore
import TOMLDecoder

/// The `[backlog.notion]` section of the host config.
struct NotionConfig: Sendable, Equatable {
    var tokenEnv: String
    /// Normalized user ids (`NotionID.normalize`) whose edits vouch for cards.
    var trustedUsers: [String]
    var stateProperty: String
    var priorityProperty: String?
    var modelProperty: String?
    /// Normalized database id -> `ProjectSpec.path`.
    var projectPaths: [String: String]

    func databaseID(for project: ProjectSpec) -> String? {
        projectPaths.first { ProjectSpec(path: $0.value).key == project.key }?.key
    }

    /// Decodes and validates `[backlog.notion]`. Every configured project must map to a
    /// database and every mapped path must be a configured project (B187).
    static func from(_ host: HostConfig) throws -> NotionConfig {
        let raw: Raw.Section
        do {
            guard let s = try TOMLDecoder().decode(Raw.self, from: host.toml).backlog?.notion else {
                throw ConfigError("config.toml: [backlog.notion] is required when [backlog] kind = \"notion\"")
            }
            raw = s
        } catch let e as ConfigError { throw e }
        catch { throw ConfigError("config.toml: [backlog.notion]: \(error)") }

        let trusted = raw.trusted_users ?? []
        guard !trusted.isEmpty else {
            throw ConfigError("config.toml: [backlog.notion] trusted_users is required: the Notion user ids of the people whose edits vouch for cards")
        }
        let trustedIDs = try trusted.map { id in
            guard let n = NotionID.normalize(id) else {
                throw ConfigError("config.toml: [backlog.notion] trusted_users: \"\(id)\" is not a Notion user id (32 hex digits, dashes optional)")
            }
            return n
        }

        var projectPaths: [String: String] = [:]
        for (path, ref) in (raw.projects ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard host.projects.contains(where: { $0.key == ProjectSpec(path: path).key }) else {
                throw ConfigError("config.toml: [backlog.notion.projects] maps \(path), which is not a configured [[project]]")
            }
            guard let id = NotionID.database(ref) else {
                throw ConfigError("config.toml: [backlog.notion.projects] \(path): \"\(ref)\" is neither a database URL nor a database id (32 hex digits, dashes optional)")
            }
            if let other = projectPaths[id] {
                throw ConfigError("config.toml: [backlog.notion.projects] \(other) and \(path) map to the same database \(id)")
            }
            projectPaths[id] = path
        }
        for p in host.projects where !projectPaths.values.contains(where: { ProjectSpec(path: $0).key == p.key }) {
            throw ConfigError("config.toml: [backlog.notion.projects] has no database for \(p.path)")
        }

        let state = raw.state_property ?? "LoopWorker"
        guard !state.isEmpty else { throw ConfigError("config.toml: [backlog.notion] state_property must not be empty") }
        return NotionConfig(
            tokenEnv: raw.token_env ?? "LOOPWORKER_NOTION_TOKEN", trustedUsers: trustedIDs, stateProperty: state,
            priorityProperty: raw.priority_property.flatMap { $0.isEmpty ? nil : $0 },
            modelProperty: raw.model_property.flatMap { $0.isEmpty ? nil : $0 },
            projectPaths: projectPaths)
    }

    // Field names mirror the TOML keys.
    private struct Raw: Decodable {
        var backlog: Backlog?
        struct Backlog: Decodable { var notion: Section? }
        struct Section: Decodable {
            var token_env: String?
            var trusted_users: [String]?
            var state_property: String?
            var priority_property: String?
            var model_property: String?
            var projects: [String: String]?
        }
    }
}

enum NotionID {
    private static let hex = Set("0123456789abcdef")

    /// The dashed lowercase UUID form that the API returns, from 32 hex digits with or
    /// without dashes; nil for anything else.
    static func normalize(_ s: String) -> String? {
        let h = s.lowercased().replacingOccurrences(of: "-", with: "")
        guard h.count == 32, h.allSatisfy(hex.contains) else { return nil }
        let c = Array(h)
        return [c[0..<8], c[8..<12], c[12..<16], c[16..<20], c[20..<32]].map { String($0) }.joined(separator: "-")
    }

    /// A database id from a bare id or a database URL, whose last path component ends in the
    /// id (`https://www.notion.so/ws/Title-<32 hex>?v=...`).
    static func database(_ s: String) -> String? {
        guard s.contains("/") else { return normalize(s) }
        let path = s.split(separator: "?", maxSplits: 1).first.map(String.init) ?? s
        let last = path.split(separator: "#", maxSplits: 1).first?.split(separator: "/").last ?? ""
        let digits = last.replacingOccurrences(of: "-", with: "")
        guard digits.count >= 32 else { return nil }
        return normalize(String(digits.suffix(32)))
    }
}
