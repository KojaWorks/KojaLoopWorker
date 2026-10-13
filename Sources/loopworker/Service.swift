import Foundation
import LoopWorkerCore

/// Installs and removes the launchd job that runs `loopworker run`.
///
/// As a LaunchAgent (the default) the job runs in the user's GUI session and this type loads
/// it with `launchctl`. As a LaunchDaemon (for a host where nobody logs in) it needs root, so
/// this type writes the plist to the state dir and prints the `sudo` commands for a human.
struct LaunchdService {
    static let label = "dev.nevyn.loopworker"

    /// Absolute path of the `loopworker` binary that the job runs.
    var binary: String
    /// `$LOOPWORKER_HOME`, passed to the job.
    var home: URL
    /// The user's home directory: where `Library/LaunchAgents` lives.
    var userHome: URL
    var userName: String
    var uid: uid_t
    /// Runs `launchctl`.
    var runner: any ProcessRunning
    /// Receives every line of output.
    var output: @Sendable (String) -> Void

    var agentPlist: URL { userHome.appending(path: "Library/LaunchAgents/\(Self.label).plist") }
    static let daemonPlist = "/Library/LaunchDaemons/\(label).plist"
    var stagedDaemonPlist: URL { home.appending(path: "state/\(Self.label).plist") }

    /// The job's `PATH`. `~/.local/bin` is where Claude Code's own installer puts `claude`.
    static func path(userHome: URL) -> [String] {
        [userHome.appending(path: ".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    }

    /// The job definition. `daemon` adds `UserName` (and `HOME`, which a daemon has no session to supply).
    func plist(daemon: Bool) -> [String: Any] {
        var environment = [
            "LOOPWORKER_HOME": home.path,
            "PATH": Self.path(userHome: userHome).joined(separator: ":"),
        ]
        let out = home.appending(path: "state/manager.out").path
        var job: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [binary, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 30,
            // Force-stop releases every in-flight card before exiting; give it time.
            "ExitTimeOut": 180,
            "StandardOutPath": out,
            "StandardErrorPath": out,
            "ProcessType": "Background",
        ]
        if daemon {
            job["UserName"] = userName
            environment["HOME"] = userHome.path
        }
        job["EnvironmentVariables"] = environment
        return job
    }

    func plistData(daemon: Bool) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist(daemon: daemon), format: .xml, options: 0)
    }

    /// Writes the plist and loads it (agent) or prints the root commands (daemon). With
    /// `dryRun`, prints the plist and the commands and changes nothing.
    /// - Throws: `CompositionError` naming the file or the `launchctl` command that failed.
    func install(daemon: Bool, dryRun: Bool) async throws {
        let data = try plistData(daemon: daemon)
        let target = daemon ? stagedDaemonPlist : agentPlist
        if dryRun {
            output("Would write \(target.path):")
            output(String(decoding: data, as: UTF8.self))
            output(daemon ? daemonCommands().joined(separator: "\n") : "Would run: launchctl bootstrap \(domain) \(agentPlist.path)")
            return
        }
        do {
            try FileManager.default.createDirectory(at: home.appending(path: "state"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            throw CompositionError(description: "can't write \(target.path): \(error.localizedDescription)")
        }
        output("Wrote \(target.path)")
        guard !daemon else {
            output("A LaunchDaemon must be installed as root. Run:")
            output(daemonCommands().joined(separator: "\n"))
            return
        }
        if try await isLoaded() {
            try await launchctl(["bootout", "\(domain)/\(Self.label)"])
            output("Unloaded the previous \(Self.label)")
        }
        try await launchctl(["bootstrap", domain, agentPlist.path])
        output("Loaded \(Self.label) into \(domain); it runs `\(binary) run` now and at every login.")
        output("Log: \(home.appending(path: "state/manager.log").path). Check it with `loopworker status`.")
    }

    /// Unloads and removes the LaunchAgent, and prints the root commands when a LaunchDaemon
    /// is installed.
    func uninstall() async throws {
        var found = false
        if try await isLoaded() {
            try await launchctl(["bootout", "\(domain)/\(Self.label)"])
            output("Unloaded \(Self.label) from \(domain)")
            found = true
        }
        if FileManager.default.fileExists(atPath: agentPlist.path) {
            do { try FileManager.default.removeItem(at: agentPlist) }
            catch { throw CompositionError(description: "can't remove \(agentPlist.path): \(error.localizedDescription)") }
            output("Removed \(agentPlist.path)")
            found = true
        }
        if FileManager.default.fileExists(atPath: Self.daemonPlist) {
            output("A LaunchDaemon is installed. Remove it as root:")
            output("sudo launchctl bootout system/\(Self.label)\nsudo rm \(Self.daemonPlist)")
            found = true
        }
        if !found { output("No \(Self.label) service is installed") }
    }

    func daemonCommands() -> [String] {
        [
            "sudo launchctl bootout system/\(Self.label) 2>/dev/null  # only when reinstalling",
            "sudo cp \(stagedDaemonPlist.path) \(Self.daemonPlist)",
            "sudo chown root:wheel \(Self.daemonPlist)",
            "sudo chmod 644 \(Self.daemonPlist)",
            "sudo launchctl bootstrap system \(Self.daemonPlist)",
        ]
    }

    private var domain: String { "gui/\(uid)" }

    private func isLoaded() async throws -> Bool {
        try await run(["print", "\(domain)/\(Self.label)"]).succeeded
    }

    private func launchctl(_ arguments: [String]) async throws {
        let r = try await run(arguments)
        guard r.succeeded else {
            let why = r.timedOut ? "timed out" : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CompositionError(description: "launchctl \(arguments.joined(separator: " ")) failed (exit \(r.status)): \(why)")
        }
    }

    private func run(_ arguments: [String]) async throws -> ProcessResult {
        try await runner.run(ProcessSpec("launchctl", arguments, timeout: .seconds(30)))
    }
}

/// The absolute path this binary was started as, keeping symlinks: Homebrew's
/// `bin/loopworker` link survives an upgrade, its versioned Cellar target doesn't.
func invokedBinaryPath(_ argv0: String = CommandLine.arguments[0], environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if argv0.contains("/") {
        return URL(filePath: argv0, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)).standardizedFileURL.path
    }
    for dir in (environment["PATH"] ?? "").split(separator: ":") {
        let candidate = URL(filePath: String(dir)).appending(path: argv0).path
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return Bundle.main.executablePath ?? argv0
}
