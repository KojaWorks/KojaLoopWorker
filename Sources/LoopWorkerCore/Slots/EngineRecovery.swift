import Foundation

/// The host's `EngineRecovering`: restarts the container engine (OrbStack, Docker) after
/// lifecycle scripts reported it down. Create one per Manager and share it with every slot.
///
/// An attempt first runs `probeCommand`; when that succeeds the engine is up and nothing else
/// runs. Otherwise it arms a 300 s backoff, notifies, runs `startCommand` (60 s timeout), then
/// runs `probeCommand` (15 s timeout) every 5 s until it succeeds or 90 s pass. Both commands
/// run through `sh -c`. Concurrent callers share one attempt.
public actor EngineRecovery: EngineRecovering {
    public static let backoff: Duration = .seconds(300)
    static let startTimeout: Duration = .seconds(60)
    static let probeTimeout: Duration = .seconds(15)
    static let probeInterval: Duration = .seconds(5)
    static let probeWindow: Duration = .seconds(90)

    let config: HostConfig.EngineConfig
    let runner: ProcessRunning
    let log: LogSink
    let notify: @Sendable (String) -> Void
    let clock: @Sendable () -> Date
    let sleep: @Sendable (Duration) async -> Void

    private var retryAfter = Date.distantPast
    private var attempt: Task<Bool, Never>?

    /// - Parameters:
    ///   - config: Whether recovery is enabled, and the start and probe commands.
    ///   - runner: Runs the start and probe commands.
    ///   - log: Receives each attempt's progress and failures.
    ///   - notify: Alerts a human with a one-line message when an attempt starts and when it
    ///     gives up.
    ///   - clock: The current time, for the backoff and the 90 s probe window.
    ///   - sleep: Waits between probes. Tests pass one that advances `clock`.
    public init(
        config: HostConfig.EngineConfig, runner: ProcessRunning, log: LogSink,
        notify: @escaping @Sendable (String) -> Void,
        clock: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.config = config
        self.runner = runner
        self.log = log
        self.notify = notify
        self.clock = clock
        self.sleep = sleep
    }

    /// True when `output` (a failed lifecycle script's output) reads like the container engine
    /// is unreachable, rather than like a bug that restarting the engine won't fix.
    public static func looksLikeEngineDown(_ output: String) -> Bool {
        let patterns = [
            #"cannot connect to the docker daemon"#,
            #"is the docker daemon running"#,
            #"docker daemon is not running"#,
            #"dial unix \S*docker\.sock"#,
            #"error during connect.*docker"#,
            #"orbstack is (not running|stopped)"#,
            #"cannot connect to podman"#,
        ]
        let regex = try! NSRegularExpression(pattern: patterns.joined(separator: "|"), options: .caseInsensitive)
        return regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) != nil
    }

    /// Returns true when the engine answers `probeCommand`, possibly after restarting it.
    /// Returns false at once when recovery is disabled or the last attempt started less than
    /// 300 s ago, and false when the engine is still unreachable 90 s after a restart. A caller
    /// that arrives during an attempt awaits that attempt's result.
    public func recover() async -> Bool {
        guard config.recover else { return false }
        if let attempt { return await attempt.value }
        guard clock() >= retryAfter else { return false }
        let task = Task { await self.attemptRecovery() }
        attempt = task
        let up = await task.value
        attempt = nil
        return up
    }

    private func attemptRecovery() async -> Bool {
        if await probe() {
            log.info("container engine answers `\(config.probeCommand)`; nothing to recover")
            return true
        }
        retryAfter = clock().addingTimeInterval(Self.seconds(Self.backoff))
        log.warning("container engine unreachable; running `\(config.startCommand)` to recover it")
        notify("LoopWorker: container engine unreachable; running `\(config.startCommand)` to recover it")

        do {
            let r = try await runner.run(ProcessSpec("sh", ["-c", config.startCommand], timeout: Self.startTimeout))
            if !r.succeeded {
                let why = r.timedOut ? "timed out after 60 s" : "exited \(r.status)"
                log.warning("engine start command `\(config.startCommand)` \(why): \(r.output.suffix(500))")
            }
        } catch {
            log.error("engine start command `\(config.startCommand)` couldn't run: \(error)")
            notify("LoopWorker: couldn't run `\(config.startCommand)` to recover the container engine: \(error). Start the engine by hand.")
            return false
        }

        let deadline = clock().addingTimeInterval(Self.seconds(Self.probeWindow))
        while true {
            if await probe() {
                log.info("container engine back up: `\(config.probeCommand)` succeeds")
                retryAfter = .distantPast
                return true
            }
            if clock() >= deadline { break }
            await sleep(Self.probeInterval)
        }
        log.error("container engine still unreachable 90 s after `\(config.startCommand)`; next attempt in 5 min at the earliest")
        notify("LoopWorker: container engine still down 90 s after `\(config.startCommand)`. Start it by hand; broken slots retry on their own.")
        return false
    }

    private func probe() async -> Bool {
        let spec = ProcessSpec("sh", ["-c", config.probeCommand], timeout: Self.probeTimeout)
        return (try? await runner.run(spec).succeeded) ?? false
    }

    private static func seconds(_ d: Duration) -> TimeInterval { Double(d.components.seconds) }
}
