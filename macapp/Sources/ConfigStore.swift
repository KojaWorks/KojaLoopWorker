import Foundation

/// The Patch deployment this build targets. api_base + anon_key are the deployment's *public*
/// config (the anon key "grants nothing alone"), so we embed them — onboarding is then one
/// token, not four fields. A future "Connect Manager" deep link (Patch card) will carry these
/// for multi-instance; until then this is the single default instance.
enum Instance {
    static let apiBase = "https://api.patch.d.nevyn.dev"
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzgxNjExMTIyLCJleHAiOjE5MzkyOTExMjJ9.qhtLW8SIb1z9L5l6ecarjDPAZMvE0BcG6Fdjc1cf80k"
    static let appBase = "https://patch.d.nevyn.dev"   // where to mint a token
}

/// What the Connect sheet collects. Only `token` is really per-user; the rest have good defaults.
struct ConnectSettings {
    var token = ""
    var workerManager = ConfigStore.defaultManagerId
    var apiBase = Instance.apiBase
    var anonKey = Instance.anonKey
    var clonesDir = "~/Dev/loopworker-clones"
    var maxSlots = 4
}

/// Reads/writes the Manager's config the same files the CLI/systemd use: ~/.loopworker/config.toml
/// (+ .env for the PAT). The app launches the Manager with cwd = ~/.loopworker so its dotenv
/// loader picks up the token — identical to the systemd unit's WorkingDirectory.
enum ConfigStore {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".loopworker")
    }
    static var configPath: URL { dir.appendingPathComponent("config.toml") }
    static var envPath: URL { dir.appendingPathComponent(".env") }

    static var isConfigured: Bool { FileManager.default.fileExists(atPath: configPath.path) }

    /// Hostname without a trailing .local, lowercased — a sane default the user can change.
    static var defaultManagerId: String {
        ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .lowercased()
    }

    static func write(_ s: ConnectSettings) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let toml = """
        # Written by Koja Loops Manager. One Manager per host serves every project in the
        # shared backlog whose worker_manager is this host's.
        worker_manager = \(quoted(s.workerManager))
        clones_dir     = \(quoted(s.clonesDir))
        max_slots      = \(s.maxSlots)

        [backlog]
        api_base = \(quoted(s.apiBase))
        anon_key = \(quoted(s.anonKey))
        """
        try toml.write(to: configPath, atomically: true, encoding: .utf8)
        // The PAT lives in .env (read by the Manager's dotenv loader), not config.toml.
        try "PATCH_PAT=\(s.token)\n".write(to: envPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envPath.path)
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
