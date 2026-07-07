import Foundation

/// The Patch deployment this build targets. api_base + anon_key are the deployment's *public*
/// config (the anon key "grants nothing alone"), so we embed them — onboarding is then one
/// token, not four fields. A future "Connect Manager" deep link (Patch card) will carry these
/// for multi-instance; until then this is the single default instance.
enum Instance {
    static let apiBase = "https://api.patch.d.nevyn.dev"
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzgxNjExMTIyLCJleHAiOjE5MzkyOTExMjJ9.qhtLW8SIb1z9L5l6ecarjDPAZMvE0BcG6Fdjc1cf80k"
    static let appBase = "https://patch.d.nevyn.dev"   // where to mint a token
    // The shared "Managed Agent Loop" brief workers read, + card-link parts for the dashboard.
    static let briefPage = "https://patch.d.nevyn.dev/app/b5b7a703-63eb-4159-8fc9-e2b4963586f5"
    static let roadmapPageId = "ea3c65fb-9038-4dcb-8223-34dd395b2af8"
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

    enum WriteError: LocalizedError {
        case setFailed(key: String, message: String)
        var errorDescription: String? {
            switch self {
            case let .setFailed(key, message):
                return "loopworker config set \(key) failed: \(message)"
            }
        }
    }

    /// The config.toml keys the app manages. It writes ONLY these, via `loopworker config set`,
    /// so any hand-set key the app doesn't know about (notify_command, engine.*, base_port,
    /// max_concurrent_workers) survives — Python owns the TOML and does a read-modify-write.
    private static func managedKeys(_ s: ConnectSettings) -> [(String, String)] {
        [("worker_manager", s.workerManager),
         ("clones_dir", s.clonesDir),
         ("max_slots", String(s.maxSlots)),
         ("backlog.api_base", s.apiBase),
         ("backlog.anon_key", s.anonKey),
         ("backlog.app_base", Instance.appBase),
         ("backlog.roadmap_page_id", Instance.roadmapPageId),
         ("backlog.brief_page", Instance.briefPage)]
    }

    /// Persist the connection settings. `loopworker` is the resolved CLI path (the app already
    /// supervises this binary); we shell out to it per managed key rather than hand-writing the
    /// whole file, which used to clobber hand-set keys. The PAT lives in its own .env (a single
    /// app-owned key, no schema) so it's written directly.
    static func write(_ s: ConnectSettings, loopworker: String) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (key, value) in managedKeys(s) {
            let out = try await ProcessRunner.run(
                loopworker, ["config", "set", key, value, "--config", configPath.path],
                environment: LoginEnvironment.childEnvironment())
            guard out.status == 0 else {
                let msg = out.stderr.isEmpty ? out.stdout : out.stderr
                throw WriteError.setFailed(key: key, message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        try "PATCH_PAT=\(s.token)\n".write(to: envPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envPath.path)
    }

    /// Read the app-editable fields back from an existing config so the Setup form shows the
    /// CURRENT values — otherwise a Save would reset a hand-tuned max_slots (or a changed
    /// clones_dir) to the form's defaults. Best-effort: any read failure leaves the default.
    /// The token is deliberately not read back (it lives in .env; we never display it).
    static func read(loopworker: String, into settings: ConnectSettings) async -> ConnectSettings {
        func get(_ key: String) async -> String? {
            guard let out = try? await ProcessRunner.run(
                loopworker, ["config", "get", key, "--config", configPath.path],
                environment: LoginEnvironment.childEnvironment()), out.status == 0 else { return nil }
            let v = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        var s = settings
        if let v = await get("worker_manager") { s.workerManager = v }
        if let v = await get("clones_dir") { s.clonesDir = v }
        if let v = await get("max_slots"), let n = Int(v) { s.maxSlots = n }
        if let v = await get("backlog.api_base") { s.apiBase = v }
        // anon_key isn't a form field, but write() sets it — carry the existing value through
        // so a Save doesn't reset a hand-changed key to the baked Instance default. (app_base/
        // roadmap_page_id/brief_page are intentionally always the Instance constants; see the card.)
        if let v = await get("backlog.anon_key") { s.anonKey = v }
        return s
    }
}
