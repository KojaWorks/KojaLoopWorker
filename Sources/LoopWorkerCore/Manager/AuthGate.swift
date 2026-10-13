import Foundation

/// Whether the host's claude login works, from a cached preflight and from auth releases.
/// Pure state: the Manager runs the preflight as a task and records the result here.
public struct AuthGate: Sendable {
    public enum Health: String, Sendable { case unknown, ok, failing }
    public enum Transition: Sendable, Equatable {
        case failed(String)
        case recovered
    }

    /// Seconds a preflight result stays valid.
    public var ttl: TimeInterval = 180
    public private(set) var health: Health = .unknown
    /// Why the last preflight failed.
    public private(set) var detail: String?
    /// A preflight task is running.
    public var checking = false
    /// Fill claims nothing before this time: the auth circuit breaker.
    public private(set) var backoffUntil: Date?
    private var checkedAt: Date?
    private var streak = 0

    public init() {}

    /// True when the last preflight passed and no auth-release backoff is armed.
    public func allowsDispatch(at now: Date) -> Bool {
        health == .ok && !(backoffUntil.map { now < $0 } ?? false)
    }

    /// True when no preflight runs and the last result is missing or older than `ttl`.
    public func needsCheck(at now: Date) -> Bool {
        !checking && (checkedAt.map { now.timeIntervalSince($0) >= ttl } ?? true)
    }

    /// Records a preflight result. Returns the transition to log and notify, or nil when the
    /// health didn't flip (and on the first success).
    public mutating func record(ok: Bool, detail: String, at now: Date) -> Transition? {
        let was = health
        checking = false
        checkedAt = now
        health = ok ? .ok : .failing
        self.detail = ok ? nil : detail
        if !ok && was != .failing { return .failed(detail) }
        if ok && was == .failing { return .recovered }
        return nil
    }

    /// A worker hit claude's login screen: interactive auth is broken even if the headless
    /// preflight passes. Arms a backoff of `min(30 * 2^(n-1), 600)` seconds for the n-th
    /// release in a row and returns it.
    public mutating func noteAuthRelease(at now: Date) -> TimeInterval {
        streak += 1
        let delay = min(30 * pow(2, Double(streak - 1)), 600)
        backoffUntil = now.addingTimeInterval(delay)
        return delay
    }

    /// A worker finished its card, so interactive auth works. Clears the streak and returns
    /// true when there was one.
    public mutating func noteCleanFinish() -> Bool {
        guard streak > 0 else { return false }
        streak = 0
        backoffUntil = nil
        return true
    }

    /// Runs `claude -p ok --model haiku` with `USER` removed (the same claude-code 401
    /// workaround as the launch script) and `CLAUDE_CODE_OAUTH_TOKEN` passed from
    /// `environment` when present. Never throws: a start failure or timeout is a failure, and
    /// so is claude's login prompt in the output, which comes with exit status 0 when the CLI
    /// has no login of its own.
    public static func preflight(runner: any ProcessRunning, environment: [String: String]) async -> (ok: Bool, detail: String) {
        var env: [String: String?] = ["USER": nil]
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"] { env["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        let spec = ProcessSpec("claude", ["-p", "ok", "--model", "haiku"], environment: env, timeout: .seconds(60))
        do {
            let r = try await runner.run(spec)
            let last = r.output.split(whereSeparator: \.isNewline).last.map(String.init)
            if r.timedOut { return (false, "claude -p timed out after 60 s") }
            if Pane.showsAuthFailure(r.output) { return (false, last ?? "claude -p is not logged in") }
            if r.succeeded { return (true, "") }
            return (false, last ?? "claude -p exited \(r.status)")
        } catch {
            return (false, "can't run claude: \(error)")
        }
    }
}
