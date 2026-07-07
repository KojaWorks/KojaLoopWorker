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

    /// Parse the fields the Connect form edits back out of an existing config.toml. Re-onboarding
    /// ("Replace token…") prefills these so it can't silently reset a customized install to defaults;
    /// `write` then round-trips the same values. Returns nil when there's no config yet (first-time
    /// onboarding keeps the defaults). Best-effort: a key it can't find keeps its default, so a
    /// partial or hand-edited file still round-trips whatever it does have. `token` stays empty — the
    /// PAT lives in the Keychain and the user is pasting a fresh one.
    static func read() -> ConnectSettings? {
        guard let text = try? String(contentsOf: configPath, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            values[key] = unquoted(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        }
        var s = ConnectSettings()
        if let v = values["worker_manager"] { s.workerManager = v }
        if let v = values["clones_dir"] { s.clonesDir = v }
        if let v = values["max_slots"], let n = Int(v) { s.maxSlots = n }
        if let v = values["api_base"] { s.apiBase = v }
        if let v = values["anon_key"] { s.anonKey = v }
        return s
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

    /// Upsert a `KEY=value` line in ~/.loopworker/.env, preserving every other line. How the app
    /// persists the headless-worker login (CLAUDE_CODE_OAUTH_TOKEN from `claude setup-token`): the
    /// Manager and `doctor` both load it from .env at launch (cwd ~/.loopworker), same as the
    /// CLI/systemd path. (PATCH_PAT is the exception — it lives in the Keychain, never .env.)
    /// Throws on write failure so onboarding can surface it, like Keychain.store.
    static func upsertEnvVar(key: String, value: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: envPath, encoding: .utf8)) ?? ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isAssignment($0, key: key) }
            .map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        lines.append("\(key)=\(value)")
        try (lines.joined(separator: "\n") + "\n").write(to: envPath, atomically: true, encoding: .utf8)
        // A long-lived credential (the CLAUDE_CODE_OAUTH_TOKEN) sits here, so lock the file to the
        // owner — the same posture that moved PATCH_PAT off plaintext .env into the Keychain. Surface
        // a chmod failure rather than silently leaving a world-readable token on disk.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envPath.path)
    }

    /// True if a .env line assigns `key` (bare or `export key=`) — so the migration, the scrub, and
    /// the upsert all agree on which line carries a given variable.
    private static func isAssignment(_ line: Substring, key: String) -> Bool {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("export ") { t = String(t.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces) }
        return t.hasPrefix("\(key)=")
    }

    /// True if a .env line assigns PATCH_PAT — both the migration and the scrub use this to find the
    /// cleartext token line.
    private static func isTokenLine(_ line: Substring) -> Bool { isAssignment(line, key: "PATCH_PAT") }

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

    /// Inverse of `quoted` for reading config.toml back in: strip surrounding quotes and unescape.
    /// A bare (unquoted) value — e.g. the numeric max_slots — is returned as-is.
    private static func unquoted(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
