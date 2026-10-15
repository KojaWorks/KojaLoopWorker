import Foundation
import LoopWorkerCore

public enum NotionBackend {
    /// Builds the Notion backlog from `[backlog.notion]`:
    ///
    /// ```toml
    /// [backlog.notion]
    /// token_env         = "LOOPWORKER_NOTION_TOKEN"  # an internal integration's secret
    /// trusted_users     = ["<notion user id>"]       # required: people whose edits vouch for cards
    /// state_property    = "LoopWorker"               # select with next/working/ci/review/stuck
    /// priority_property = "Priority"                 # optional: number, select or multi_select
    /// model_property    = "Model"                    # optional: select or rich_text
    ///
    /// [backlog.notion.projects]                      # every [[project]] needs one
    /// "group/app" = "<database URL or id>"
    /// ```
    ///
    /// Does no network I/O: the integration's identity and each database's data source are
    /// read on first use.
    /// - Parameters:
    ///   - config: The host config; its projects are the only ones the backlog serves.
    ///   - log: Receives skipped-card notes and failed comment deletions.
    ///   - environment: The Manager's `secrets.env` values overlaid on its process
    ///     environment; the token is looked up here only.
    /// - Throws: `ConfigError` naming the key for a missing or invalid setting, an unmapped
    ///   project, or an unset token variable.
    public static func makeBacklog(config: HostConfig, log: LogSink, environment: [String: String]) throws -> NotionBacklog {
        try makeBacklog(config: config, log: log, environment: environment, transport: urlSessionTransport)
    }

    /// The environment variables that `makeBacklog` reads credentials from for this config.
    /// - Throws: `ConfigError` for an invalid `[backlog.notion]` section.
    public static func credentialVariables(config: HostConfig) throws -> [String] {
        [try NotionConfig.from(config).tokenEnv]
    }

    static func makeBacklog(
        config: HostConfig, log: LogSink, environment: [String: String], transport: @escaping HTTPTransport,
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
        now: @escaping @Sendable () -> Date = Date.init,
        host: String = hostName()
    ) throws -> NotionBacklog {
        let notion = try NotionConfig.from(config)
        guard let token = environment[notion.tokenEnv], !token.isEmpty else {
            throw ConfigError("\(notion.tokenEnv) is not set: create an internal integration (https://www.notion.com/help/add-and-manage-connections-with-the-api) and put its secret in secrets.env ([backlog.notion] token_env)")
        }
        let client = NotionClient(tokenEnv: notion.tokenEnv, token: token, transport: transport, now: now, sleep: sleep)
        return NotionBacklog(config: notion, client: client, log: log, now: now, host: host)
    }

    static func hostName() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "unknown-host" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
