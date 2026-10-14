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

    /// The environment variables that `make` reads credentials from for this config, so the
    /// caller can treat them as secrets before building anything.
    /// - Throws: `ConfigError` when the config file doesn't decode.
    public static func credentialVariables(config: HostConfig) throws -> [String] {
        try GitLabConfig.tokenVariables(toml: config.toml, backlog: config.backlogKind == "gitlab", forge: config.forgeKind == "gitlab")
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
            forge = GitLabForge(client: client, baseURL: connection.baseURL, gitEnvironment: env, log: log)
        }
        return (backlog, forge)
    }
}

extension GitLabBacklog: Diagnosable {
    /// Reads the token's user (`GET /user`) and reports who it is.
    public func diagnose() async -> [DoctorCheck] { [await client.identityCheck("backlog gitlab")] }
}

extension GitLabForge: Diagnosable {
    /// Reads the token's user (`GET /user`) and reports who it is.
    public func diagnose() async -> [DoctorCheck] { [await client.identityCheck("forge gitlab")] }
}

extension GitLabClient {
    func identityCheck(_ name: String) async -> DoctorCheck {
        let base = connection.baseURL.absoluteString
        do {
            let user = try await me()
            return DoctorCheck(name, .ok, "\(connection.tokenEnv) belongs to @\(user.username) (id \(user.id)) on \(base)")
        } catch {
            return DoctorCheck(name, .fail, "\(error)", remedy: "check that this host reaches \(base) and that \(connection.tokenEnv) holds a token for it with the api scope")
        }
    }
}
