import Foundation

/// One result of `loopworker doctor`.
public struct DoctorCheck: Codable, Sendable, Equatable {
    /// `fail` makes doctor exit non-zero; `warn` names something that limits a feature or a
    /// service setup but doesn't stop a Manager from running.
    public enum Level: String, Codable, Sendable { case ok, warn, fail }

    /// What was checked, such as `config`, `tool tmux` or `backlog gitlab`.
    public var name: String
    public var level: Level
    /// One line on what was found. Never a secret's value.
    public var detail: String
    /// What a human should do about a `warn` or `fail`.
    public var remedy: String?

    public init(_ name: String, _ level: Level, _ detail: String, remedy: String? = nil) {
        self.name = name
        self.level = level
        self.detail = detail
        self.remedy = remedy
    }
}

/// A backlog or forge that can prove its connection and token work. Optional: doctor reports
/// a backend that doesn't adopt it as unchecked.
public protocol Diagnosable: Sendable {
    /// Makes one cheap authenticated read, such as the token's own user, and reports who the
    /// token belongs to. Never throws: a failed read is a `fail` check that names the URL or
    /// the token variable, never the token.
    func diagnose() async -> [DoctorCheck]
}

/// The host checks behind `loopworker doctor`. Every check reads the same files and builds
/// the backends the same way as `loopworker run`.
public struct Doctor: Sendable {
    /// `$LOOPWORKER_HOME`.
    public var home: URL
    /// The process environment. `secrets.env` is overlaid on it the way `run` does.
    public var environment: [String: String]
    /// Runs the claude preflight and the engine probe.
    public var runner: any ProcessRunning
    /// The directories on the `PATH` that `loopworker service install` gives the service; a
    /// tool found only outside them gets a warning.
    public var servicePath: [String]
    /// The variables that the configured backends read their tokens from.
    public var credentialVariables: @Sendable (HostConfig) throws -> [String]
    /// Builds the backlog and forge from the config and the overlaid environment, as `run` does.
    public var makeBackends: @Sendable (HostConfig, [String: String]) throws -> (backlog: any Backlog, forge: any Forge)

    public init(
        home: URL, environment: [String: String], runner: any ProcessRunning, servicePath: [String],
        credentialVariables: @escaping @Sendable (HostConfig) throws -> [String],
        makeBackends: @escaping @Sendable (HostConfig, [String: String]) throws -> (backlog: any Backlog, forge: any Forge)
    ) {
        self.home = home
        self.environment = environment
        self.runner = runner
        self.servicePath = servicePath
        self.credentialVariables = credentialVariables
        self.makeBackends = makeBackends
    }

    static let requiredTools = ["tmux", "git", "claude", "bash"]
    static let optionalTools = [
        ("git-lfs", "projects whose repos use Git LFS", "brew install git-lfs"),
        ("storygrafter", "projects with [review] guide = true", "brew install nevyn/tap/storygrafter"),
    ]

    /// Runs every check, in a fixed order, with every detail and remedy redacted. Checks that
    /// need the config are skipped when it doesn't load; the config check says why.
    public func run() async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let secretsFile = home.appending(path: "secrets.env")
        let config: HostConfig?
        do {
            let c = try HostConfig.load(home: home)
            config = c
            checks.append(c.projects.isEmpty
                ? DoctorCheck("config", .warn, "no projects", remedy: "add a [[project]] to \(home.appending(path: "config.toml").path)")
                : DoctorCheck("config", .ok, "projects: \(c.projects.map(\.path).joined(separator: ", "))"))
        } catch {
            config = nil
            checks.append(DoctorCheck("config", .fail, "\(error)", remedy: "create or fix \(home.appending(path: "config.toml").path); README.md \"Configuration\" shows a complete one"))
        }

        let (secretsCheck, fileSecrets) = secrets(secretsFile)
        checks.append(secretsCheck)
        let overlaid = environment.merging(fileSecrets) { _, secret in secret }

        var tokenNames = ["CLAUDE_CODE_OAUTH_TOKEN"]
        if let config {
            do { tokenNames += try credentialVariables(config) }
            catch { checks.append(DoctorCheck("tokens", .fail, "\(error)", remedy: "fix the backend section of config.toml")) }
        }
        checks += tokens(Array(Set(tokenNames)).sorted(), fileSecrets: fileSecrets, secretsFile: secretsFile)

        let tools = tools()
        checks += tools
        if tools.contains(where: { $0.name == "tool claude" && $0.level != .fail }) {
            checks.append(await claude(overlaid, secretsFile: secretsFile))
        }

        if let config {
            checks.append(await engine(config.engine))
            checks += await backends(config, overlaid)
        }
        checks += state()

        let literals = tokenNames.compactMap { overlaid[$0] }.filter { $0.count >= 8 }
        return checks.map {
            var c = $0
            c.detail = Redactor.redact(c.detail, literals: literals)
            c.remedy = c.remedy.map { Redactor.redact($0, literals: literals) }
            return c
        }
    }

    /// True when no check failed: doctor's exit status.
    public static func passed(_ checks: [DoctorCheck]) -> Bool {
        !checks.contains { $0.level == .fail }
    }

    /// One line per check (`ok`, `warn` or `FAIL`, the name, the detail), plus an indented
    /// remedy line for each `warn` and `fail`.
    public static func render(_ checks: [DoctorCheck]) -> String {
        let width = checks.map(\.name.count).max() ?? 0
        return checks.map { c in
            let level = c.level == .fail ? "FAIL" : c.level.rawValue
            var line = "\(level.padding(toLength: 5, withPad: " ", startingAt: 0))\(c.name.padding(toLength: width + 2, withPad: " ", startingAt: 0))\(c.detail)\n"
            if c.level != .ok, let remedy = c.remedy { line += "     -> \(remedy)\n" }
            return line
        }.joined()
    }

    // MARK: Checks

    private func secrets(_ file: URL) -> (DoctorCheck, [String: String]) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else {
            return (DoctorCheck("secrets", .ok, "no \(file.path); tokens come from the Manager's environment"), [:])
        }
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if mode & 0o044 != 0 {
            return (DoctorCheck("secrets", .fail, "\(file.path) has mode \(String(mode, radix: 8)); group or others can read it, so the Manager refuses to start",
                                remedy: "chmod 600 \(file.path)"), [:])
        }
        do {
            let values = try Secrets.load(file)
            return (DoctorCheck("secrets", .ok, "\(file.path): mode \(String(mode, radix: 8)), \(values.count) variables"), values)
        } catch {
            return (DoctorCheck("secrets", .fail, "\(error)", remedy: "write one NAME=value per line"), [:])
        }
    }

    private func tokens(_ names: [String], fileSecrets: [String: String], secretsFile: URL) -> [DoctorCheck] {
        names.map { name in
            let check = "token \(name)"
            if let v = fileSecrets[name], !v.isEmpty { return DoctorCheck(check, .ok, "set in secrets.env") }
            let claude = name == "CLAUDE_CODE_OAUTH_TOKEN"
            if let v = environment[name], !v.isEmpty {
                return DoctorCheck(check, .warn, "set in this shell only; a launchd service won't have it",
                                   remedy: "add \(name)=... to \(secretsFile.path)")
            }
            if claude {
                return DoctorCheck(check, .warn, "not set; workers use the host's own claude login, which a launchd daemon can't reach",
                                   remedy: "run `claude setup-token` and add CLAUDE_CODE_OAUTH_TOKEN=... to \(secretsFile.path)")
            }
            return DoctorCheck(check, .fail, "not set; config.toml names it as a backend token",
                               remedy: "add \(name)=... to \(secretsFile.path)")
        }
    }

    private func tools() -> [DoctorCheck] {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        func find(_ tool: String) -> URL? {
            path.lazy.map { URL(filePath: $0).appending(path: tool) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        func found(_ name: String, _ url: URL) -> DoctorCheck {
            let dir = url.deletingLastPathComponent().path
            guard servicePath.contains(dir) else {
                return DoctorCheck("tool \(name)", .warn, "\(url.path), outside the service PATH (\(servicePath.joined(separator: ":")))",
                                   remedy: "link it into one of those directories, or a launchd service won't find it")
            }
            return DoctorCheck("tool \(name)", .ok, url.path)
        }
        return Self.requiredTools.map { tool in
            find(tool).map { found(tool, $0) }
                ?? DoctorCheck("tool \(tool)", .fail, "not on PATH", remedy: tool == "claude" ? "install Claude Code" : "brew install \(tool)")
        } + Self.optionalTools.map { tool, feature, install in
            find(tool).map { found(tool, $0) }
                ?? DoctorCheck("tool \(tool)", .warn, "not on PATH; needed for \(feature)", remedy: install)
        }
    }

    private func claude(_ overlaid: [String: String], secretsFile: URL) async -> DoctorCheck {
        let r = await AuthGate.preflight(runner: runner, environment: overlaid)
        let via = overlaid["CLAUDE_CODE_OAUTH_TOKEN"].map { $0.isEmpty ? "the host login" : "CLAUDE_CODE_OAUTH_TOKEN" } ?? "the host login"
        if r.ok { return DoctorCheck("claude login", .ok, "claude -p answered, using \(via)") }
        return DoctorCheck("claude login", .fail, r.detail,
                           remedy: "run `claude setup-token` and put CLAUDE_CODE_OAUTH_TOKEN=... in \(secretsFile.path); the Manager forwards it to workers and to its own preflight")
    }

    private func engine(_ engine: HostConfig.EngineConfig) async -> DoctorCheck {
        let remedy = "start it with `\(engine.startCommand)`; only projects whose lifecycle scripts start containers need it"
        do {
            let r = try await runner.run(ProcessSpec("bash", ["-c", engine.probeCommand], timeout: .seconds(20)))
            if r.succeeded { return DoctorCheck("engine", .ok, "`\(engine.probeCommand)` succeeded") }
            let why = r.timedOut ? "timed out after 20 s" : r.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(r.status)"
            return DoctorCheck("engine", .warn, "`\(engine.probeCommand)` failed: \(why)", remedy: remedy)
        } catch {
            return DoctorCheck("engine", .warn, "can't run `\(engine.probeCommand)`: \(error)", remedy: remedy)
        }
    }

    private func backends(_ config: HostConfig, _ overlaid: [String: String]) async -> [DoctorCheck] {
        let made: (backlog: any Backlog, forge: any Forge)
        do { made = try makeBackends(config, overlaid) }
        catch { return [DoctorCheck("backends", .fail, "\(error)", remedy: "fix config.toml or secrets.env as named")] }
        var checks: [DoctorCheck] = []
        for (role, kind, backend) in [("backlog", config.backlogKind, made.backlog as Any), ("forge", config.forgeKind, made.forge as Any)] {
            if let d = backend as? any Diagnosable { checks += await d.diagnose() }
            else { checks.append(DoctorCheck("\(role) \(kind)", .warn, "built, but this kind has no connection check", remedy: "watch the Manager log for its first read")) }
        }
        return checks
    }

    private func state() -> [DoctorCheck] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home.path, isDirectory: &isDir), isDir.boolValue else {
            return [DoctorCheck("home", .fail, "\(home.path) doesn't exist", remedy: "mkdir -p \(home.path)")]
        }
        guard FileManager.default.isWritableFile(atPath: home.path) else {
            return [DoctorCheck("home", .fail, "\(home.path) isn't writable", remedy: "chown it to the user that runs the Manager")]
        }
        let holder = ManagerLock.holder(at: ManagerLock.file(stateDir: home.appending(path: "state")))
        return [
            DoctorCheck("home", .ok, "\(home.path) is writable"),
            DoctorCheck("manager", .ok, holder.map { "running, pid \($0)" } ?? "not running"),
        ]
    }
}
