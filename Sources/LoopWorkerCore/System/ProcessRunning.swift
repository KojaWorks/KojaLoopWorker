import Foundation

/// One subprocess invocation. Every subprocess the Manager starts goes through
/// `ProcessRunning`, including git and tmux, so the safety rules below hold everywhere.
public struct ProcessSpec: Sendable {
    /// Executable name (resolved on `PATH`) or absolute path.
    public var executable: String
    public var arguments: [String]
    /// Added to the Manager's environment. A nil value removes the variable.
    public var environment: [String: String?]
    public var workingDirectory: URL?
    /// Hard limit. On expiry the whole process group gets SIGKILL and the result says
    /// `timedOut`. Required: there is no "no timeout".
    public var timeout: Duration
    /// Called with each output line (stdout and stderr merged) as it arrives, already
    /// redacted. Used to stream lifecycle script output into the log.
    public var onLine: (@Sendable (String) -> Void)?

    public init(
        _ executable: String, _ arguments: [String] = [], environment: [String: String?] = [:],
        workingDirectory: URL? = nil, timeout: Duration, onLine: (@Sendable (String) -> Void)? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.onLine = onLine
    }
}

public struct ProcessResult: Sendable, Equatable {
    /// Exit status, or the negated signal number when killed by a signal.
    public var status: Int32
    /// stdout and stderr merged, unredacted. Callers redact before logging.
    public var output: String
    public var timedOut: Bool

    public init(status: Int32, output: String, timedOut: Bool = false) {
        self.status = status
        self.output = output
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Runs subprocesses safely. The implementation guarantees, for every call:
/// - the child runs in its own process group, and a timeout kills the whole group;
/// - stdin is `/dev/null` (a GUI- or launchd-started Manager may have no valid fd 0);
/// - `GIT_TERMINAL_PROMPT=0` is set, so git fails instead of prompting;
/// - the call returns when the child exits, even if a grandchild still holds the output
///   pipe open (it stops reading after a short drain period);
/// - a cancelled task kills the process group.
/// Throws only when the process can't be started at all; a non-zero exit is a result.
public protocol ProcessRunning: Sendable {
    func run(_ spec: ProcessSpec) async throws -> ProcessResult
}
