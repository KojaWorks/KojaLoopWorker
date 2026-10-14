import Foundation

/// Worker sessions on the Manager's own tmux server. Session names are `SlotSpec.session`.
public protocol TmuxDriving: Sendable {
    /// Names of live sessions that start with `prefix`.
    func sessions(prefix: String) async throws -> [String]

    /// Starts a detached session running `script` (an executable file) in `directory`.
    /// Secrets reach the worker through files that the script sources, never through tmux
    /// arguments, which other users can read with `ps`. The pane stays after the script exits
    /// (`remain-on-exit`), so its last screen can be captured; `kill` removes it.
    func spawn(session: String, directory: URL, script: URL) async throws

    /// True when the session exists and its pane's process (the worker) hasn't exited. A
    /// finished-but-idle `claude` counts as alive; the outcome file says when it is done.
    func isAlive(_ session: String) async throws -> Bool

    /// The last `lines` lines of the session's pane, for auth-failure and trust-dialog
    /// detection and for the status file.
    func capture(_ session: String, lines: Int) async throws -> String

    /// Presses `keys` (tmux key names such as `Down` and `Enter`) in the session. Used only to
    /// accept claude's folder-trust dialog after `capture` showed it.
    func sendKeys(_ session: String, _ keys: [String]) async throws

    /// Kills the session. Killing a session that doesn't exist is not an error.
    func kill(_ session: String) async throws
}


/// A tmux command failed or timed out.
public struct TmuxError: Error, CustomStringConvertible {
    /// The tmux arguments after `-S <socket>`.
    public var command: [String]
    public var result: ProcessResult?
    /// Set instead of `result` when the command couldn't run at all.
    public var reason: String?

    public var description: String {
        let why = result.map { $0.timedOut ? "timed out" : "exited \($0.status): \($0.output.suffix(1000))" } ?? reason ?? ""
        return "tmux \(command.joined(separator: " ")) \(why)"
    }
}

/// `TmuxDriving` on the Manager's own tmux server, so worker sessions never collide with a
/// human's tmux on a shared host. Every command runs with a 10 s timeout; a timeout throws.
public struct Tmux: TmuxDriving {
    private let runner: any ProcessRunning
    private let socket: URL
    private let environment: [String: String?]

    /// - Parameters:
    ///   - runner: Runs every tmux command.
    ///   - socket: The server socket, `$LOOPWORKER_HOME/state/tmux`. Its parent directory is
    ///     created when missing.
    ///   - scrubbedVariables: Environment variables removed from every tmux command (the
    ///     backlog and forge token variables, `CLAUDE_CODE_OAUTH_TOKEN`), so the server that
    ///     the first command starts never holds a secret.
    public init(runner: any ProcessRunning, socket: URL, scrubbedVariables: [String]) {
        self.runner = runner
        self.socket = socket
        self.environment = Dictionary(uniqueKeysWithValues: scrubbedVariables.map { ($0, nil) })
    }

    public func sessions(prefix: String) async throws -> [String] {
        let command = ["list-sessions", "-F", "#{session_name}"]
        let result = try await tmux(command)
        if !result.succeeded {
            if !result.timedOut && (Self.noServer(result) || result.output.contains("no sessions")) { return [] }
            throw TmuxError(command: command, result: result)
        }
        return result.output.split(separator: "\n").map(String.init).filter { $0.hasPrefix(prefix) }
    }

    public func spawn(session: String, directory: URL, script: URL) async throws {
        // tmux runs a single-argument command through the user's shell, so quote it for sh and fish alike.
        guard !script.path.contains("'") && !script.path.contains("\\") else {
            throw TmuxError(command: ["new-session", "-s", session], reason: "script path \(script.path) contains a quote or backslash")
        }
        // remain-on-exit is set server-wide before the session exists, so even a script that
        // dies at once leaves its pane (and its error) behind. The server is LoopWorker's own.
        try await check(["start-server", ";", "set-option", "-g", "remain-on-exit", "on", ";",
                         "new-session", "-d", "-s", session, "-c", directory.path, "'\(script.path)'"])
    }

    public func isAlive(_ session: String) async throws -> Bool {
        let command = ["display-message", "-p", "-t", Self.pane(session), "#{session_name}:#{pane_dead}"]
        let result = try await tmux(command)
        if !result.succeeded {
            if !result.timedOut && (Self.noServer(result) || Self.noSession(result)) { return false }
            throw TmuxError(command: command, result: result)
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // The pane runs the launch script, which execs claude, so the pane's process is the
        // worker. The foreground command is no signal: it is a shell whenever claude runs one.
        return output == session + ":0"
    }

    public func capture(_ session: String, lines: Int) async throws -> String {
        try await check(["capture-pane", "-p", "-t", Self.pane(session), "-S", "-\(lines)"]).output
    }

    public func sendKeys(_ session: String, _ keys: [String]) async throws {
        try await check(["send-keys", "-t", Self.pane(session)] + keys)
    }

    public func kill(_ session: String) async throws {
        let command = ["kill-session", "-t", "=\(session)"]
        let result = try await tmux(command)
        if !result.succeeded && (result.timedOut || !(Self.noServer(result) || Self.noSession(result))) {
            throw TmuxError(command: command, result: result)
        }
    }


    // "=" makes tmux match the session name exactly; otherwise `lw_x_1` also finds `lw_x_10`.
    private static func pane(_ session: String) -> String { "=\(session):" }

    // A missing socket says "error connecting to <socket> (No such file or directory)".
    private static func noServer(_ result: ProcessResult) -> Bool {
        result.output.contains("no server running")
            || (result.output.contains("error connecting to") && result.output.contains("No such file or directory"))
    }

    private static func noSession(_ result: ProcessResult) -> Bool {
        result.output.contains("can't find session")
    }

    @discardableResult
    private func check(_ command: [String]) async throws -> ProcessResult {
        let result = try await tmux(command)
        guard result.succeeded else { throw TmuxError(command: command, result: result) }
        return result
    }

    private func tmux(_ command: [String]) async throws -> ProcessResult {
        do {
            try FileManager.default.createDirectory(
                at: socket.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw TmuxError(command: command, reason: "can't create the socket directory: \(error)")
        }
        return try await runner.run(ProcessSpec(
            "tmux", ["-S", socket.path] + command, environment: environment, timeout: .seconds(10)))
    }
}
