import Foundation
import LoopWorkerCore

public enum GitLabBackend {
    /// Builds the GitLab backlog and forge that the host config asks for.
    ///
    /// - Parameters:
    ///   - config: The host config. The backlog is built when `backlogKind == "gitlab"`, from
    ///     `[backlog.gitlab]`; the forge when `forgeKind == "gitlab"`, from `[forge.gitlab]`
    ///     with `[backlog.gitlab]` filling the keys it leaves out.
    ///   - log: Receives skipped-card notices and work-item status failures.
    ///   - environment: `secrets.env` overlaid on the process environment. Tokens are read
    ///     only from here, never from `ProcessInfo`.
    /// - Returns: Each part, or nil when the config names another kind for it. When both are
    ///   built against the same instance and token they share one client and its caches.
    /// - Throws: `ConfigError` naming the key for a missing token, an empty `allowed`, an
    ///   unknown `status_mode` or a bad `base_url`; any error writing the git askpass helper
    ///   into `config.stateDir`.
    public static func make(
        config: HostConfig, log: LogSink, environment: [String: String]
    ) throws -> (backlog: GitLabBacklog?, forge: GitLabForge?) {
        try make(config: config, log: log, environment: environment, transport: URLSessionTransport()) {
            try await Task.sleep(for: $0)
        }
    }

    static func make(
        config: HostConfig, log: LogSink, environment: [String: String],
        transport: any HTTPTransport, sleep: @escaping GitLabClient.Sleep
    ) throws -> (backlog: GitLabBacklog?, forge: GitLabForge?) {
        var backlog: GitLabBacklog?
        var forge: GitLabForge?
        var backlogClient: GitLabClient?
        if config.backlogKind == "gitlab" {
            let settings = try GitLabConfig.backlog(toml: config.toml, environment: environment)
            let client = GitLabClient(connection: settings.connection, transport: transport, sleep: sleep)
            backlogClient = client
            backlog = GitLabBacklog(client: client, settings: settings, projects: config.projects, log: log)
        }
        if config.forgeKind == "gitlab" {
            let connection = try GitLabConfig.forge(toml: config.toml, environment: environment)
            let client = backlogClient.flatMap { $0.connection == connection ? $0 : nil }
                ?? GitLabClient(connection: connection, transport: transport, sleep: sleep)
            let env = try GitAskPass.environment(scriptDirectory: config.stateDir, username: "oauth2", password: connection.token)
            forge = GitLabForge(client: client, baseURL: connection.baseURL, gitEnvironment: env)
        }
        return (backlog, forge)
    }
}
