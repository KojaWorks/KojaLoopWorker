import Foundation
import LoopWorkerCore

public enum PatchBackend {
    /// Builds the Patch backlog from `[backlog.patch]`:
    ///
    /// ```toml
    /// [backlog.patch]
    /// api_base        = "https://api.example.dev"  # PostgREST/Kong origin
    /// anon_key        = "..."                       # public anon key, sent as apikey
    /// token_env       = "PATCH_PAT"                 # personal access token, exchanged for a session
    /// roadmap_table   = "roadmap"
    /// projects        = { "owner/repo" = "<projects row id>" }  # every [[project]] needs one
    /// trusted_authors = []                          # author uids trusted besides the PAT owner
    /// review_link_field = "solved_in_pr"            # optional: column that gets the review URL
    /// app_base        = "https://app.example.dev"   # optional, with roadmap_item_id: Card.url
    /// roadmap_item_id = "<roadmap table item id>"
    ///
    /// [backlog.patch.status]                        # defaults shown
    /// ready   = "Backlog"                           # an empty status also counts as ready
    /// working = "In progress"
    /// review  = "In review"
    /// stuck   = "Needs refinement"
    /// shipped = "Shipped"                           # what a blocked_by target must reach
    /// ```
    ///
    /// Does no network I/O: the PAT is exchanged on first use, or by `PatchBacklog.connect()`.
    /// - Parameters:
    ///   - config: The host config; its projects are the only ones the backlog serves.
    ///   - log: Receives skipped-card notes and startup retries.
    ///   - environment: The Manager's `secrets.env` values overlaid on its process
    ///     environment; the token is looked up here only.
    /// - Throws: `ConfigError` naming the key for a missing or invalid setting, an unmapped
    ///   project, or an unset token variable.
    public static func makeBacklog(config: HostConfig, log: LogSink, environment: [String: String]) throws -> PatchBacklog {
        try makeBacklog(config: config, log: log, environment: environment, transport: urlSessionTransport)
    }

    /// The environment variables that `makeBacklog` reads credentials from for this config.
    /// - Throws: `ConfigError` for an invalid `[backlog.patch]` section.
    public static func credentialVariables(config: HostConfig) throws -> [String] {
        [try PatchConfig.from(config).tokenEnv]
    }

    static func makeBacklog(
        config: HostConfig, log: LogSink, environment: [String: String], transport: @escaping HTTPTransport,
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> PatchBacklog {
        let patch = try PatchConfig.from(config)
        guard let pat = environment[patch.tokenEnv], !pat.isEmpty else {
            throw ConfigError("\(patch.tokenEnv) is not set: mint a token in Patch Settings -> Tokens and put it in secrets.env ([backlog.patch] token_env)")
        }
        let client = PatchClient(apiBase: patch.apiBase, anonKey: patch.anonKey, tokenEnv: patch.tokenEnv, pat: pat,
                                 log: log, transport: transport, now: now, sleep: sleep)
        return PatchBacklog(config: patch, client: client, log: log)
    }
}
