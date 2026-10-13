import Foundation
import TOMLDecoder

public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// The host config, `$LOOPWORKER_HOME/config.toml`. The only config source: nothing is read
/// from a backlog. Backend sections (`[backlog.<kind>]`, `[forge.<kind>]`) are decoded by the
/// backend itself from `toml`, so Core never learns their shape.
public struct HostConfig: Sendable {
    /// Root of all Manager state. `$LOOPWORKER_HOME`, else `~/.loopworker`.
    public var home: URL
    public var clonesDir: URL
    /// Host-wide budget in weighted slot units.
    public var maxSlots: Double
    public var maxConcurrentWorkers: Int
    /// Claims per card before a crash marks it stuck instead of releasing it.
    public var maxAttempts: Int
    public var basePort: Int
    public var portStep: Int
    /// Shell command that receives an alert on stdin; empty disables alerts.
    public var notifyCommand: String
    public var engine: EngineConfig
    public var backlogKind: String
    public var forgeKind: String
    public var projects: [ProjectSpec]
    /// The full file, for backends to decode their own sections.
    public var toml: String

    public struct EngineConfig: Sendable, Equatable {
        /// Try to restart the container engine when a lifecycle script's output says it is down.
        public var recover: Bool
        public var startCommand: String
        public var probeCommand: String
    }

    public var stateDir: URL { home.appending(path: "state") }
    public var slotsStateDir: URL { home.appending(path: "slots") }

    /// Resolves `LOOPWORKER_HOME` from `environment`, defaulting to `~/.loopworker`.
    public static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = environment["LOOPWORKER_HOME"], !h.isEmpty { return URL(filePath: expandTilde(h)) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".loopworker")
    }

    public static func load(home: URL = HostConfig.home()) throws -> HostConfig {
        let file = home.appending(path: "config.toml")
        let text: String
        do { text = try String(contentsOf: file, encoding: .utf8) }
        catch { throw ConfigError("can't read \(file.path): \(error.localizedDescription)") }
        return try parse(text, home: home)
    }

    public static func parse(_ text: String, home: URL) throws -> HostConfig {
        let raw: RawFile
        do { raw = try TOMLDecoder().decode(RawFile.self, from: text) }
        catch { throw ConfigError("config.toml: \(error)") }

        guard let backlog = raw.backlog?.kind else { throw ConfigError("config.toml: [backlog] kind is required") }
        let maxSlots = raw.max_slots ?? 4
        guard maxSlots > 0 else { throw ConfigError("config.toml: max_slots must be > 0") }
        let maxAttempts = raw.max_attempts ?? 3
        guard maxAttempts > 0 else { throw ConfigError("config.toml: max_attempts must be > 0") }

        var projects: [ProjectSpec] = []
        var keys: [String: String] = [:]
        for p in raw.project ?? [] {
            guard !p.path.isEmpty else { throw ConfigError("config.toml: a [[project]] has an empty path") }
            let spec = ProjectSpec(
                path: p.path, slots: p.slots ?? 1, hot: p.hot ?? false,
                weight: (p.weight ?? 1) > 0 ? p.weight ?? 1 : 1,
                model: p.model, contract: p.contract.map(expandTilde),
                baseBranch: p.base_branch, draftReviewRequests: p.draft ?? true)
            guard spec.slots >= 0 else { throw ConfigError("config.toml: \(p.path): slots must be >= 0") }
            if let other = keys[spec.key] {
                throw ConfigError("config.toml: projects \(other) and \(p.path) map to the same key \(spec.key)")
            }
            keys[spec.key] = p.path
            projects.append(spec)
        }

        let clones = raw.clones_dir.map(expandTilde) ?? home.appending(path: "clones").path
        return HostConfig(
            home: home,
            clonesDir: URL(filePath: clones),
            maxSlots: maxSlots,
            maxConcurrentWorkers: raw.max_concurrent_workers ?? Int(maxSlots.rounded(.up)),
            maxAttempts: maxAttempts,
            basePort: raw.base_port ?? 54400,
            portStep: raw.port_step ?? 100,
            notifyCommand: raw.notify_command ?? "",
            engine: EngineConfig(
                recover: raw.engine?.recover ?? true,
                startCommand: raw.engine?.start_command ?? "orb start",
                probeCommand: raw.engine?.probe_command ?? "docker ps"),
            backlogKind: backlog,
            forgeKind: raw.forge?.kind ?? backlog,
            projects: projects,
            toml: text)
    }

    // Field names mirror the TOML keys.
    private struct RawFile: Decodable {
        var clones_dir: String?
        var max_slots: Double?
        var max_concurrent_workers: Int?
        var max_attempts: Int?
        var base_port: Int?
        var port_step: Int?
        var notify_command: String?
        var engine: RawEngine?
        var backlog: RawKind?
        var forge: RawKind?
        var project: [RawProject]?
    }
    private struct RawEngine: Decodable {
        var recover: Bool?
        var start_command: String?
        var probe_command: String?
    }
    private struct RawKind: Decodable { var kind: String? }
    private struct RawProject: Decodable {
        var path: String
        var slots: Int?
        var hot: Bool?
        var weight: Double?
        var model: String?
        var contract: String?
        var base_branch: String?
        var draft: Bool?
    }
}

/// Expands a leading `~` to the current user's home directory.
public func expandTilde(_ path: String) -> String {
    guard path.hasPrefix("~") else { return path }
    return FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
}
