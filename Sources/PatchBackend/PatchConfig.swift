import Foundation
import LoopWorkerCore
import TOMLDecoder

/// The `[backlog.patch]` section of the host config.
struct PatchConfig: Sendable, Equatable {
    /// The deployment's API origin; PostgREST is under `/rest/v1`, the PAT exchange under
    /// `/functions/v1/pat-exchange`.
    var apiBase: URL
    /// The deployment's public anon key, sent as `apikey`. Kong needs it to route; it grants nothing.
    var anonKey: String
    var tokenEnv: String
    var roadmapTable: String
    /// Patch `projects` row id -> `ProjectSpec.path`.
    var projectPaths: [String: String]
    /// Author uids trusted besides the PAT owner. Never read from the database.
    var trustedAuthors: Set<String>
    var status: Statuses
    /// The roadmap column that `markReview` writes the review request URL into, if any.
    var reviewLinkField: String?
    /// App origin and the roadmap table's item id, for `Card.url`; both or neither.
    var appBase: URL?
    var roadmapItemID: String?

    struct Statuses: Sendable, Equatable {
        var ready = "Backlog"
        var working = "In progress"
        var review = "In review"
        var stuck = "Needs refinement"
        /// The review request waits for CI. Only written for projects with `wait_for_ci`.
        var verifying = "Verifying"
        /// The status a `blocked_by` target must have before the blocked card is workable.
        var shipped = "Shipped"
    }

    func patchID(for project: ProjectSpec) -> String? {
        projectPaths.first { ProjectSpec(path: $0.value).key == project.key }?.key
    }

    /// Decodes and validates `[backlog.patch]` from the host config. Every configured project
    /// must have a Patch project id and every mapped path must be a configured project, so a
    /// typo fails at startup instead of silently starving a project.
    static func from(_ host: HostConfig) throws -> PatchConfig {
        let raw: Raw.Section
        do {
            guard let s = try TOMLDecoder().decode(Raw.self, from: host.toml).backlog?.patch else {
                throw ConfigError("config.toml: [backlog.patch] is required when [backlog] kind = \"patch\"")
            }
            raw = s
        } catch let e as ConfigError { throw e }
        catch { throw ConfigError("config.toml: [backlog.patch]: \(error)") }

        guard let apiBase = URL(string: raw.api_base ?? ""), apiBase.scheme != nil, apiBase.host != nil else {
            throw ConfigError("config.toml: [backlog.patch] api_base must be an absolute URL, got \(raw.api_base ?? "nothing")")
        }
        guard let anon = raw.anon_key, !anon.isEmpty else {
            throw ConfigError("config.toml: [backlog.patch] anon_key is required (the deployment's public anon key)")
        }
        var projectPaths: [String: String] = [:]
        for (path, id) in raw.projects ?? [:] {
            guard host.projects.contains(where: { $0.key == ProjectSpec(path: path).key }) else {
                throw ConfigError("config.toml: [backlog.patch] projects maps \(path), which is not a configured [[project]]")
            }
            projectPaths[id] = path
        }
        for p in host.projects where !projectPaths.values.contains(where: { ProjectSpec(path: $0).key == p.key }) {
            throw ConfigError("config.toml: [backlog.patch] projects has no Patch project id for \(p.path)")
        }

        var status = Statuses()
        if let s = raw.status {
            status.ready = s.ready ?? status.ready
            status.working = s.working ?? status.working
            status.review = s.review ?? status.review
            status.stuck = s.stuck ?? status.stuck
            status.verifying = s.verifying ?? status.verifying
            status.shipped = s.shipped ?? status.shipped
        }
        let keyed = [("ready", status.ready), ("working", status.working), ("verifying", status.verifying),
                     ("review", status.review), ("stuck", status.stuck), ("shipped", status.shipped)]
        if let empty = keyed.first(where: { $0.1.isEmpty }) {
            throw ConfigError("config.toml: [backlog.patch.status] \(empty.0) must not be empty")
        }
        for (i, a) in keyed.enumerated() {
            if let b = keyed[(i + 1)...].first(where: { $0.1 == a.1 }) {
                throw ConfigError("config.toml: [backlog.patch.status] \(a.0) and \(b.0) are both \"\(a.1)\"; every state needs its own status")
            }
        }

        let appBase = raw.app_base.flatMap { URL(string: $0) }
        guard (appBase == nil) == (raw.roadmap_item_id == nil) else {
            throw ConfigError("config.toml: [backlog.patch] app_base and roadmap_item_id must be set together")
        }
        return PatchConfig(
            apiBase: apiBase, anonKey: anon, tokenEnv: raw.token_env ?? "PATCH_PAT",
            roadmapTable: raw.roadmap_table ?? "roadmap", projectPaths: projectPaths,
            trustedAuthors: Set(raw.trusted_authors ?? []), status: status,
            reviewLinkField: raw.review_link_field, appBase: appBase, roadmapItemID: raw.roadmap_item_id)
    }

    // Field names mirror the TOML keys.
    private struct Raw: Decodable {
        var backlog: Backlog?
        struct Backlog: Decodable { var patch: Section? }
        struct Section: Decodable {
            var api_base: String?
            var anon_key: String?
            var token_env: String?
            var roadmap_table: String?
            var projects: [String: String]?
            var trusted_authors: [String]?
            var review_link_field: String?
            var app_base: String?
            var roadmap_item_id: String?
            var status: Status?
        }
        struct Status: Decodable {
            var ready: String?
            var working: String?
            var review: String?
            var stuck: String?
            var verifying: String?
            var shipped: String?
        }
    }
}
