import Foundation

/// Whether the host's claude login works, from a cached preflight and from auth releases.
/// Pure state: the Manager runs the preflight as a task and records the result here.
public struct AuthGate: Sendable {
    public enum Health: String, Sendable { case unknown, ok, failing }
    public enum Transition: Sendable, Equatable {
        case failed(String)
        case recovered
    }
    /// One preflight's result.
    public enum Verdict: Sendable, Equatable {
        case ok
        /// claude answered and the login doesn't work: a login prompt, a non-zero exit, or
        /// claude can't start.
        case failed(String)
        /// claude didn't answer: timed out or killed by a signal, as on a loaded host. Says
        /// nothing about the login.
        case inconclusive(String)
    }

    /// Seconds an ok or failed result stays valid.
    public var ttl: TimeInterval = 180
    /// Seconds until the re-check after an inconclusive result.
    public var inconclusiveRetry: TimeInterval = 30
    /// Inconclusive results in a row that count as failing.
    public static let inconclusiveLimit = 3
    /// The preflight's hard timeout.
    public static let preflightTimeout = 120
    public private(set) var health: Health = .unknown
    /// Why the last preflight failed or was inconclusive, how many in a row, and when the
    /// next check runs; nil after an ok.
    public private(set) var detail: String?
    /// A preflight task is running.
    public var checking = false
    /// Fill claims nothing before this time: the auth circuit breaker.
    public private(set) var backoffUntil: Date?
    private var nextCheckAt: Date?
    private var failedRow = 0
    private var inconclusiveRow = 0
    private var releaseStreak = 0

    public init() {}

    /// True when the last preflight passed and no auth-release backoff is armed.
    public func allowsDispatch(at now: Date) -> Bool {
        health == .ok && !(backoffUntil.map { now < $0 } ?? false)
    }

    /// True when no preflight runs and the next check is due: `ttl` after an ok or failed
    /// result, `inconclusiveRetry` after an inconclusive one, at once before the first.
    public func needsCheck(at now: Date) -> Bool {
        !checking && (nextCheckAt.map { now >= $0 } ?? true)
    }

    /// Records a preflight result and sets `detail`. An inconclusive result leaves the health
    /// as it was, unless it is the `inconclusiveLimit`-th in a row, which counts as failing.
    /// Returns the transition to log and notify, or nil when the health didn't flip (and on
    /// the first success).
    public mutating func record(_ verdict: Verdict, at now: Date) -> Transition? {
        let was = health
        checking = false
        switch verdict {
        case .ok:
            failedRow = 0
            inconclusiveRow = 0
            nextCheckAt = now.addingTimeInterval(ttl)
            health = .ok
            detail = nil
            return was == .failing ? .recovered : nil
        case .failed(let why):
            failedRow += 1
            inconclusiveRow = 0
            nextCheckAt = now.addingTimeInterval(ttl)
            health = .failing
            detail = "failed (\(failedRow) in a row): \(why); next check in \(Int(ttl)) s"
            return was == .failing ? nil : .failed(why)
        case .inconclusive(let why):
            inconclusiveRow += 1
            failedRow = 0
            nextCheckAt = now.addingTimeInterval(inconclusiveRetry)
            detail = "inconclusive (\(inconclusiveRow) in a row): \(why); next check in \(Int(inconclusiveRetry)) s"
            guard inconclusiveRow >= Self.inconclusiveLimit else { return nil }
            health = .failing
            return was == .failing ? nil : .failed("\(why), \(inconclusiveRow) checks in a row")
        }
    }

    /// A worker hit claude's login screen: interactive auth is broken even if the headless
    /// preflight passes. Arms a backoff of `min(30 * 2^(n-1), 600)` seconds for the n-th
    /// release in a row and returns it.
    public mutating func noteAuthRelease(at now: Date) -> TimeInterval {
        releaseStreak += 1
        let delay = min(30 * pow(2, Double(releaseStreak - 1)), 600)
        backoffUntil = now.addingTimeInterval(delay)
        return delay
    }

    /// A worker finished its card, so interactive auth works. Clears the streak and returns
    /// true when there was one.
    public mutating func noteCleanFinish() -> Bool {
        guard releaseStreak > 0 else { return false }
        releaseStreak = 0
        backoffUntil = nil
        return true
    }

    /// Runs `claude -p ok --model haiku` with `USER` removed (the same claude-code 401
    /// workaround as the launch script) and `CLAUDE_CODE_OAUTH_TOKEN` passed from
    /// `environment` when present, under a `preflightTimeout` s timeout. Never throws.
    /// - Returns: `.failed` for claude's login prompt in the output (which comes with exit
    ///   status 0 when the CLI has no login of its own), a non-zero exit, or a claude that
    ///   can't start; `.inconclusive` for a timeout or a kill by a signal; otherwise `.ok`.
    public static func preflight(runner: any ProcessRunning, environment: [String: String]) async -> Verdict {
        var env: [String: String?] = ["USER": nil]
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"] { env["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        let spec = ProcessSpec("claude", ["-p", "ok", "--model", "haiku"], environment: env, timeout: .seconds(preflightTimeout))
        do {
            let r = try await runner.run(spec)
            let last = r.output.split(whereSeparator: \.isNewline).last.map(String.init)
            if Pane.showsAuthFailure(r.output) { return .failed(last ?? "claude -p is not logged in") }
            if r.timedOut { return .inconclusive("claude -p timed out after \(preflightTimeout) s") }
            if r.status < 0 { return .inconclusive("claude -p was killed by signal \(-r.status)") }
            if r.succeeded { return .ok }
            return .failed(last ?? "claude -p exited \(r.status)")
        } catch {
            return .failed("can't run claude: \(error)")
        }
    }
}
