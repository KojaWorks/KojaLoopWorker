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

/// Reads/writes the Manager's config the same files the CLI/systemd use: ~/.loopworker/config.toml.
/// The PAT is NOT a file — it lives in the login Keychain (see Keychain); the app injects it into
/// the Manager subprocess's environment at launch (ManagerController). The app still launches the
/// Manager with cwd = ~/.loopworker (for state/ and any non-secret .env), like the systemd unit's
/// WorkingDirectory.
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
        app_base = \(quoted(Instance.appBase))
        roadmap_page_id = \(quoted(Instance.roadmapPageId))
        brief_page = \(quoted(Instance.briefPage))
        """
        try toml.write(to: configPath, atomically: true, encoding: .utf8)
        // The PAT goes in the login Keychain, never a plaintext file. Scrub any token an older
        // build left in .env so re-onboarding an existing install also removes the cleartext copy.
        try Keychain.store(s.token)
        scrubEnvToken()
    }

    /// One-time upgrade for installs from before the Keychain: if the token still lives only in a
    /// plaintext ~/.loopworker/.env, move it into the Keychain and scrub the file. Idempotent and
    /// safe — a no-op once the Keychain holds a token, and it never touches non-PATCH_PAT lines.
    static func migrateEnvTokenToKeychain() {
        guard Keychain.read() == nil, let token = envToken(), !token.isEmpty else { return }
        guard (try? Keychain.store(token)) != nil else { return }  // keep .env if the store failed
        scrubEnvToken()
    }

    /// True if a .env line assigns PATCH_PAT (bare or `export PATCH_PAT=`), so both the migration
    /// and the scrub agree on which lines carry the cleartext token.
    private static func isTokenLine(_ line: Substring) -> Bool {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("export ") { t = String(t.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces) }
        return t.hasPrefix("PATCH_PAT=")
    }

    /// The PATCH_PAT value from a plaintext .env, if present (legacy installs only).
    private static func envToken() -> String? {
        guard let text = try? String(contentsOf: envPath, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where isTokenLine(line) {
            let value = line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
            return value.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    /// Remove the PATCH_PAT line from .env, preserving any other lines; delete the file if it's
    /// then empty. So the cleartext token never lingers once it's in the Keychain.
    private static func scrubEnvToken() {
        guard let text = try? String(contentsOf: envPath, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isTokenLine($0) }
        let remaining = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: envPath)
        } else {
            try? (remaining + "\n").write(to: envPath, atomically: true, encoding: .utf8)
        }
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
