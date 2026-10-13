import Foundation

/// Sends operator alerts through the host config's `notify_command`.
///
/// The command runs under `sh -c` with the message on its stdin and also in the environment
/// as `LOOPWORKER_ALERT`, so both `curl -F 'message=<-' ...` and
/// `printf '%s' "$LOOPWORKER_ALERT" | ...` work.
public actor Notifier {
    private let command: String
    private let runner: any ProcessRunning
    private let log: any LogSink
    private let now: @Sendable () -> Date
    private let dedupe: TimeInterval
    private var lastSent: [String: Date] = [:]

    /// - Parameters:
    ///   - command: the shell command; empty disables alerts.
    ///   - dedupe: a second alert with the same key within this many seconds is dropped.
    public init(
        command: String, runner: any ProcessRunning, log: any LogSink,
        now: @escaping @Sendable () -> Date = Date.init, dedupe: TimeInterval = 300
    ) {
        self.command = command
        self.runner = runner
        self.log = log
        self.now = now
        self.dedupe = dedupe
    }

    public var enabled: Bool { !command.isEmpty }

    /// Sends `message` unless an alert with `key` went out within the dedupe window. Never
    /// throws: a failed or rejected send is logged.
    public func send(key: String, _ message: String) async {
        guard enabled else { return }
        let t = now()
        if let last = lastSent[key], t.timeIntervalSince(last) < dedupe { return }
        lastSent[key] = t
        // The command reads stdin, but ProcessRunning gives every child /dev/null; a pipe
        // inside the shell feeds it the message instead.
        let spec = ProcessSpec(
            "sh", ["-c", #"printf '%s' "$LOOPWORKER_ALERT" | sh -c "$1""#, "loopworker-notify", command],
            environment: ["LOOPWORKER_ALERT": message], timeout: .seconds(20))
        let result: ProcessResult
        do { result = try await runner.run(spec) }
        catch {
            log.error("notify \(key): can't run notify_command: \(error)")
            return
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded else {
            let why = result.timedOut ? "timed out after 20 s" : "exited \(result.status)"
            log.error("notify \(key): notify_command \(why): \(output.prefix(200))")
            return
        }
        // Pushover answers HTTP errors with exit 0 and {"status":0,...}.
        if let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
           let status = json["status"], (status as? Int) != 1 {
            log.error("notify \(key): rejected by the notification service: \(output.prefix(200))")
        }
    }
}
