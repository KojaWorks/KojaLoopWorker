import Foundation
import LoopWorkerCore
import TOMLDecoder

/// How the GitLab backlog mirrors card states into a team's own workflow, on top of the
/// `<prefix>*` labels that always carry the state.
enum StatusMode: String, Sendable {
    /// Only the `<prefix>*` labels change.
    case none
    /// The configured status names are labels too: a move adds the target's and removes the others.
    case labels
    /// The configured status names are native work-item statuses (Premium and up).
    case workItemStatus = "work_item_status"
}

/// Where and as whom the client talks to GitLab.
struct GitLabConnection: Sendable, Equatable {
    /// Without a trailing slash, e.g. `https://gitlab.com`.
    var baseURL: URL
    /// Name of the variable that holds the token; errors name it so an operator knows what to fix.
    var tokenEnv: String
    var token: String
}

/// The decoded `[backlog.gitlab]` section.
struct GitLabBacklogSettings: Sendable, Equatable {
    var connection: GitLabConnection
    /// Project path prefixes, lowercased. A card outside every prefix is never trusted.
    var allowed: [String]
    var labelPrefix: String
    var statusMode: StatusMode
    /// Status names per state, for `labels` and `work_item_status` modes.
    var statusNames: [CardState: String]

    func label(_ state: CardState) -> String? {
        switch state {
        case .ready: labelPrefix + "next"
        case .working: labelPrefix + "working"
        case .review: labelPrefix + "review"
        case .stuck: labelPrefix + "stuck"
        case .other: nil
        }
    }

    func isAllowed(_ projectPath: String) -> Bool {
        let path = projectPath.lowercased()
        return allowed.contains { path.hasPrefix($0) }
    }
}

enum GitLabConfig {
    static let defaultBaseURL = "https://gitlab.com"
    static let defaultTokenEnv = "LOOPWORKER_GITLAB_TOKEN"
    static let defaultStatusNames: [CardState: String] = [
        .ready: "To do", .working: "In progress", .review: "In review", .stuck: "To do",
    ]

    /// Decodes `[backlog.gitlab]`. Throws `ConfigError` naming the key for a missing token,
    /// an empty `allowed` or an unknown `status_mode`.
    static func backlog(toml: String, environment: [String: String]) throws -> GitLabBacklogSettings {
        let section = try decode(toml).backlog?.gitlab ?? RawGitLab()
        let key = "[backlog.gitlab]"
        let connection = try connection(section, fallback: nil, key: key, environment: environment)
        let allowed = (section.allowed ?? []).filter { !$0.isEmpty }.map { $0.lowercased() }
        guard !allowed.isEmpty else {
            throw ConfigError("config.toml: \(key) allowed must list at least one project path prefix")
        }
        let modeName = section.status_mode ?? StatusMode.none.rawValue
        guard let mode = StatusMode(rawValue: modeName) else {
            throw ConfigError("config.toml: \(key) status_mode must be none, labels or work_item_status, got \"\(modeName)\"")
        }
        var names = defaultStatusNames
        if let s = section.status {
            for (state, value) in [(CardState.ready, s.ready), (.working, s.working), (.review, s.review), (.stuck, s.stuck)] {
                if let value { names[state] = value }
            }
        }
        if let empty = names.first(where: { $0.value.isEmpty }) {
            throw ConfigError("config.toml: \(key).status \(empty.key.rawValue) must not be empty")
        }
        let prefix = section.label_prefix ?? "loopworker:"
        guard !prefix.isEmpty else { throw ConfigError("config.toml: \(key) label_prefix must not be empty") }
        return GitLabBacklogSettings(
            connection: connection, allowed: allowed, labelPrefix: prefix, statusMode: mode, statusNames: names)
    }

    /// The `token_env` names that the backlog and forge sections read, without needing them set.
    static func tokenVariables(toml: String, backlog: Bool, forge: Bool) throws -> [String] {
        let raw = try decode(toml)
        var names: [String] = []
        if backlog { names.append(raw.backlog?.gitlab?.token_env ?? defaultTokenEnv) }
        if forge { names.append(raw.forge?.gitlab?.token_env ?? raw.backlog?.gitlab?.token_env ?? defaultTokenEnv) }
        return names
    }

    /// Decodes `[forge.gitlab]`, falling back to `[backlog.gitlab]` for each key it doesn't set.
    static func forge(toml: String, environment: [String: String]) throws -> GitLabConnection {
        let raw = try decode(toml)
        return try connection(
            raw.forge?.gitlab ?? RawGitLab(), fallback: raw.backlog?.gitlab,
            key: "[forge.gitlab]", environment: environment)
    }

    private static func connection(
        _ section: RawGitLab, fallback: RawGitLab?, key: String, environment: [String: String]
    ) throws -> GitLabConnection {
        let base = section.base_url ?? fallback?.base_url ?? defaultBaseURL
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil
        else { throw ConfigError("config.toml: \(key) base_url must be an http(s) URL, got \"\(base)\"") }
        let tokenEnv = section.token_env ?? fallback?.token_env ?? defaultTokenEnv
        guard let token = environment[tokenEnv], !token.isEmpty else {
            throw ConfigError("config.toml: \(key) token_env names \(tokenEnv), which is not set in secrets.env or the environment")
        }
        return GitLabConnection(baseURL: url, tokenEnv: tokenEnv, token: token)
    }

    private static func decode(_ toml: String) throws -> RawFile {
        do { return try TOMLDecoder().decode(RawFile.self, from: toml) }
        catch { throw ConfigError("config.toml: \(error)") }
    }

    // Field names mirror the TOML keys.
    private struct RawFile: Decodable {
        var backlog: RawSection?
        var forge: RawSection?
    }
    private struct RawSection: Decodable { var gitlab: RawGitLab? }
    private struct RawGitLab: Decodable {
        var base_url: String?
        var token_env: String?
        var allowed: [String]?
        var label_prefix: String?
        var status_mode: String?
        var status: RawStatus?
    }
    private struct RawStatus: Decodable {
        var ready: String?
        var working: String?
        var review: String?
        var stuck: String?
    }
}
