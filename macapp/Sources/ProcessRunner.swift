import Foundation

/// Minimal async wrapper around Process for one-shot commands (`loopworker doctor`, `which`).
/// Long-lived supervision of the Manager lives in ManagerController, not here.
enum ProcessRunner {
    struct Output { let status: Int32; let stdout: String; let stderr: String }

    static func run(_ launchPath: String, _ args: [String], cwd: URL? = nil,
                    environment: [String: String]? = nil) async throws -> Output {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            if let environment { p.environment = environment }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { proc in
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: Output(status: proc.terminationStatus, stdout: o, stderr: e))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

/// A GUI app launched from Finder gets a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so
/// claude / tmux / docker in Homebrew or `~/.local` "aren't found" though they're installed
/// (system `git` in /usr/bin is the one that passes). Capture the user's real login-shell PATH
/// once and inject it into every child — `doctor` AND the Manager (which needs to find tmux/git/
/// claude to actually run workers, not just to report readiness).
enum LoginEnvironment {
    static let path: String? = captureLoginPath()

    /// The current process environment, with PATH replaced by the login-shell PATH.
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let path { env["PATH"] = path }
        return env
    }

    private static func captureLoginPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "printf %s \"$PATH\""]   // login shell: sources the user's profile
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }
}

/// Finds the `loopworker` binary the app supervises. A shipped bundle will embed a frozen
/// Python build (see docs/distribution.md); until then the scaffold resolves it from a
/// user override, then PATH — so a `pipx`/`pip -e` install just works during development.
enum LoopWorkerLocator {
    static let overrideKey = "loopworkerPath"

    static func resolve() -> String? {
        if let override = UserDefaults.standard.string(forKey: overrideKey),
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        // Prefer the frozen Manager bundled in the app (Resources/loopworker) — this is what
        // makes "update the app" == "update the Manager". Falls through to PATH in dev builds
        // that haven't run freeze-manager.sh.
        if let bundled = Bundle.main.url(forResource: "loopworker", withExtension: nil)?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        // `which` under a login shell so it sees the user's real PATH (pipx/homebrew).
        for shell in ["/bin/zsh", "/bin/bash"] {
            guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = ["-lc", "command -v loopworker"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { continue }
            p.waitUntilExit()
            let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
