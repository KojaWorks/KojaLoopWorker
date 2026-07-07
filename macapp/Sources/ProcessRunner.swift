import Foundation

/// Minimal async wrapper around Process for one-shot commands (`loopworker doctor`, `which`).
/// Long-lived supervision of the Manager lives in ManagerController, not here.
enum ProcessRunner {
    struct Output { let status: Int32; let stdout: String; let stderr: String }

    static func run(_ launchPath: String, _ args: [String], cwd: URL? = nil) async throws -> Output {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
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
