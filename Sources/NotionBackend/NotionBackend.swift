import Foundation
import LoopWorkerCore

public enum NotionBackend {
    /// Builds the Notion backlog from `[backlog.notion]`:
    ///
    /// ```toml
    /// [backlog.notion]
    /// token_env         = "LOOPWORKER_NOTION_TOKEN"  # an internal integration's secret
    /// trusted_users     = ["<notion user id>"]       # required: people whose edits vouch for cards
    /// state_property    = "LoopWorker"               # select with next/working/ci/review/stuck, plus merged when a project merges
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
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: NotionClient.nanoseconds($0)) },
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

extension NotionBacklog: Diagnosable {
    /// B199: the token's integration, the trusted users, and per project the database's
    /// connection, data source and properties. Never changes the schema.
    public func diagnose() async -> [DoctorCheck] {
        var checks = [await tokenCheck(), await trustedUsersCheck()]
        for (db, path) in config.projectPaths.sorted(by: { $0.value < $1.value }) {
            checks.append(await databaseCheck(db, path: path))
        }
        return checks
    }

    private func tokenCheck() async -> DoctorCheck {
        let env = config.tokenEnv
        do {
            let me = try await client.me()
            let workspace = me["bot"]?["workspace_name"]?.string.map { " in the workspace \($0)" } ?? ""
            return DoctorCheck("backlog notion", .ok, "\(env) belongs to the integration \(me["name"]?.string ?? "unnamed")\(workspace) (id \(me["id"]?.string ?? "?"))")
        } catch NotionError.personToken(let env, let name) {
            return DoctorCheck("backlog notion", .fail, "\(NotionError.personToken(tokenEnv: env, name: name))",
                               remedy: "create an internal integration and put its secret in secrets.env as \(env)")
        } catch {
            return DoctorCheck("backlog notion", .fail, "\(error)",
                               remedy: "check that this host reaches api.notion.com and that \(env) in secrets.env holds an internal integration's secret")
        }
    }

    private func trustedUsersCheck() async -> DoctorCheck {
        var people: [String] = []
        var problems: [String] = []
        for user in config.trustedUsers {
            do {
                guard let u = try await client.request("GET", "users/\(user)", missing: .none) else {
                    problems.append("\(user) is not a user in this workspace")
                    continue
                }
                let name = u["name"]?.string ?? "unnamed"
                if u["type"]?.string == "person" { people.append("\(name) (\(user))") }
                else { problems.append("\(user) is a \(u["type"]?.string ?? "user of unknown type") (\(name)), not a person") }
            } catch {
                problems.append("\(user): \(error)")
            }
        }
        let name = "backlog notion trusted users"
        guard !problems.isEmpty else { return DoctorCheck(name, .ok, "trusted users: \(people.joined(separator: ", "))") }
        let remedy: String
        do {
            let lines = try await client.list("GET", "users")
                .filter { $0["type"]?.string == "person" }
                .map { "\($0["name"]?.string ?? "unnamed"): \($0["id"]?.string ?? "?")" }
                .sorted()
            remedy = "set [backlog.notion] trusted_users to the ids of the people whose edits vouch for cards. The workspace's people:\n" + lines.joined(separator: "\n")
        } catch {
            remedy = "set [backlog.notion] trusted_users to people's ids; the workspace's people can't be listed (\(error)), so give the integration the capability to read user information"
        }
        return DoctorCheck(name, .fail, problems.joined(separator: "; "), remedy: remedy)
    }

    private func databaseCheck(_ db: String, path: String) async -> DoctorCheck {
        let name = "backlog notion \(path)"
        let properties: [String: JSON]
        let source: String
        do {
            source = try await dataSource(db)
            properties = try await schema(source, database: db)
        } catch let e as NotionError {
            let remedy = switch e {
            case .notConnected: "open the database in Notion, choose ••• -> Connections (Add connections) and add the integration"
            case .dataSources: "map \(path) in [backlog.notion.projects] to a database that has exactly one data source"
            default: "check that this host reaches api.notion.com and that \(config.tokenEnv) holds an internal integration's secret"
            }
            return DoctorCheck(name, .fail, "\(e)", remedy: remedy)
        } catch {
            return DoctorCheck(name, .fail, "\(error)", remedy: "check \(db) in [backlog.notion.projects]")
        }

        var problems: [String] = []
        var remedies: [String] = []
        let state = config.stateProperty
        let options = ["next", "working", "ci", "review", "stuck"] + (config.mergingDatabases.contains(db) ? ["merged"] : [])
        if let p = properties[state] {
            if p["type"]?.string != "select" {
                problems.append("\(state) is a \(p["type"]?.string ?? "?") property, not a select")
                remedies.append("replace \(state) with a select property named \(state) with the options \(options.joined(separator: ", ")), or set [backlog.notion] state_property to a property that only LoopWorker uses")
            } else {
                let have = Set((p["select"]?["options"]?.array ?? []).compactMap { $0["name"]?.string })
                let missing = options.filter { !have.contains($0) }
                if !missing.isEmpty {
                    problems.append("\(state) lacks the options \(missing.joined(separator: ", "))")
                    remedies.append("add the options \(missing.joined(separator: ", ")) to the select property \(state)")
                }
            }
        } else {
            problems.append("the database has no property \(state)")
            remedies.append("add a select property named \(state) with the options \(options.joined(separator: ", "))")
        }
        for (key, property, usable) in [("priority_property", config.priorityProperty, ["number", "select", "multi_select"]),
                                        ("model_property", config.modelProperty, ["select", "rich_text"])] {
            guard let property else { continue }
            let kinds = usable.dropLast().joined(separator: ", ") + " or " + usable.last!
            guard let type = properties[property]?["type"]?.string else {
                problems.append("the database has no property \(property)")
                remedies.append("add a \(kinds) property named \(property), or remove [backlog.notion] \(key)")
                continue
            }
            if !usable.contains(type) {
                problems.append("\(property) is a \(type) property, not \(kinds)")
                remedies.append("make \(property) a \(kinds) property, or point [backlog.notion] \(key) at one")
            }
        }
        guard problems.isEmpty else {
            return DoctorCheck(name, .fail, "database \(db): " + problems.joined(separator: "; "), remedy: remedies.joined(separator: "; "))
        }
        return DoctorCheck(name, .ok, "database \(db) (data source \(source)): \(state) has the options \(options.joined(separator: ", "))")
    }
}
