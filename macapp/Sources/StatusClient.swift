import Foundation

/// Reads the Manager's status contract over the local dashboard, and runs `loopworker doctor`
/// for host-prerequisite readiness. This is the *client* side of the seam — the app never
/// reimplements Manager logic, it consumes /health, /json, and the doctor CLI.
struct StatusClient {
    var dashboardPort: Int = 8787
    var loopworkerPath: String

    func health() async throws -> Health {
        try await get(Health.self, path: "/health")
    }

    func snapshot() async throws -> Snapshot {
        try await get(Snapshot.self, path: "/json")
    }

    private func get<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let url = URL(string: "http://127.0.0.1:\(dashboardPort)\(path)")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw StatusError.badResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Runs `loopworker doctor --json` and decodes it. Heavier than /health (it shells out to
    /// `claude -p` etc.), so callers poll it on a slow timer, not every status tick.
    func doctor() async throws -> DoctorReport {
        // Inject the login-shell PATH so the frozen Manager finds claude/tmux/docker (a GUI app's
        // own PATH is minimal) — otherwise readiness falsely reports everything missing. Run from
        // ~/.loopworker (when it exists) so doctor loads the same .env the Manager will.
        let cwd = FileManager.default.fileExists(atPath: ConfigStore.dir.path) ? ConfigStore.dir : nil
        let out = try await ProcessRunner.run(loopworkerPath, ["doctor", "--json"], cwd: cwd,
                                              environment: LoginEnvironment.childEnvironment())
        // doctor exits non-zero when a check fails but still prints valid JSON on stdout.
        guard let data = out.stdout.data(using: .utf8), !data.isEmpty else {
            throw StatusError.doctorNoOutput(out.stderr)
        }
        return try JSONDecoder().decode(DoctorReport.self, from: data)
    }
}

enum StatusError: LocalizedError {
    case badResponse
    case doctorNoOutput(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Manager did not return a valid status response"
        case .doctorNoOutput(let err): return "doctor produced no output: \(err)"
        }
    }
}
