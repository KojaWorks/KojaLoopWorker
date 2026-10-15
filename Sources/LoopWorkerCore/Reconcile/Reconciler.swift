import Foundation

/// What the Manager observed about one busy slot during a tick.
public struct SlotObservation: Sendable, Equatable {
    /// The card's current state, or nil when the backlog says the card is gone.
    public var cardState: CardState?
    /// The worker's tmux session exists and runs something other than a shell.
    public var sessionAlive: Bool
    /// The worker's pane shows claude's login or 401 screen.
    public var authFailed: Bool
    /// Seconds since the outcome file was last modified, or nil when there is none.
    public var outcomeAge: TimeInterval?
    /// Seconds since the worker was spawned.
    public var runningFor: TimeInterval
    /// The holder id of another Manager whose claim of the card is newer than this one's.
    public var heldBy: String?

    public init(
        cardState: CardState?, sessionAlive: Bool, authFailed: Bool = false,
        outcomeAge: TimeInterval? = nil, runningFor: TimeInterval, heldBy: String? = nil
    ) {
        self.heldBy = heldBy
        self.cardState = cardState
        self.sessionAlive = sessionAlive
        self.authFailed = authFailed
        self.outcomeAge = outcomeAge
        self.runningFor = runningFor
    }
}

public enum ReleaseReason: String, Sendable, Equatable {
    case crashed, hung, auth

    /// Crashes and hangs are the card's fault as far as the loop can tell; an auth failure
    /// is the host's, so it doesn't bring the card closer to `max_attempts`.
    public var countsAsAttempt: Bool { self != .auth }
}

public enum SlotDecision: Sendable, Equatable {
    /// Healthy, or an outcome is still within its grace period.
    case keep
    /// The worker wrote its outcome: reap the session and run the finish task.
    case finish
    /// The card is gone, a human moved it out of `working`, or another Manager holds it: reap
    /// and recycle without writing to the backlog. The string says what happened, for the log.
    case abandon(String)
    /// The worker failed without an outcome: reap, release the card (or mark it stuck at
    /// `max_attempts`) and recycle.
    case release(ReleaseReason)
}

public struct ReconcilePolicy: Sendable {
    /// How long a live session may keep running after writing its outcome, so claude can
    /// finish printing before it is reaped.
    public var outcomeGrace: TimeInterval
    public var wallclockCap: TimeInterval

    public init(outcomeGrace: TimeInterval = 20, wallclockCap: TimeInterval = 90 * 60) {
        self.outcomeGrace = outcomeGrace
        self.wallclockCap = wallclockCap
    }
}

/// Pure decisions over observations, so every reconcile rule is unit-testable without
/// tmux, git or a backlog.
public enum Reconciler {
    public static func decide(_ o: SlotObservation, policy: ReconcilePolicy) -> SlotDecision {
        guard let state = o.cardState else { return .abandon("card no longer exists") }
        // A human took the card back; finishing now would act against their decision.
        guard state == .working else { return .abandon("card moved to \(state.rawValue) outside the loop") }
        // Finishing would push over the other Manager's work on the same card.
        if let other = o.heldBy { return .abandon("card is held by \(other) now") }
        if let age = o.outcomeAge {
            return (!o.sessionAlive || age >= policy.outcomeGrace) ? .finish : .keep
        }
        if !o.sessionAlive { return .release(.crashed) }
        if o.authFailed { return .release(.auth) }
        if o.runningFor > policy.wallclockCap { return .release(.hung) }
        return .keep
    }
}

/// What one CI poll read for a watched card's pushed commit.
enum CIObservation: Sendable, Equatable {
    /// The latest pipeline for the commit, or nil when none exists yet.
    case pipeline(PipelineStatus?)
    /// The forge couldn't be read; the string says why.
    case unreadable(String)
}

enum CIStuckReason: Sendable, Equatable {
    case timedOut
    case noPipeline
    case canceled
    case failedAfterFixes
    case unreadable(String)
}

enum CIDecision: Sendable, Equatable {
    case wait
    /// Move the card to `review`.
    case passed
    /// Queue a worker round that fixes the failed pipeline.
    case fix
    /// Every failed job also fails on the base branch: move the card to `review` with a note.
    case preexisting
    /// Re-run these failed jobs, which pass on the base branch, before any fix round.
    case retry([CIJob])
    case stuck(CIStuckReason)
}

struct CIPolicy: Sendable {
    var timeout: TimeInterval
    /// Fix rounds allowed after the first pipeline.
    var fixAttempts: Int
    var noPipelineAfter: TimeInterval = 15 * 60
}

extension Reconciler {
    /// - Parameters:
    ///   - sincePush: seconds since the Manager pushed the watched commit.
    ///   - round: 0 for the first push, n after the n-th fix round.
    ///   - baselines: how each failed job did on the base branch; a missing name is `.unknown`.
    ///   - retried: the Manager already re-ran this commit's failed jobs.
    static func decideCI(
        _ o: CIObservation, sincePush: TimeInterval, round: Int, policy: CIPolicy,
        baselines: [String: CIJobBaseline] = [:], retried: Bool = false
    ) -> CIDecision {
        switch o {
        case .unreadable(let why):
            return sincePush >= policy.timeout ? .stuck(.unreadable(why)) : .wait
        case .pipeline(nil):
            return sincePush >= policy.noPipelineAfter ? .stuck(.noPipeline) : .wait
        case .pipeline(let p?):
            switch p.state {
            case .running: return sincePush >= policy.timeout ? .stuck(.timedOut) : .wait
            case .passed: return .passed
            case .canceled: return .stuck(.canceled)
            case .failed:
                let jobs = p.failedJobs, base = jobs.map { baselines[$0.name] ?? .unknown }
                if !jobs.isEmpty, base.allSatisfy({ if case .failed = $0 { true } else { false } }) { return .preexisting }
                if !retried, !jobs.isEmpty, !base.contains(.unknown) {
                    return .retry(jobs.filter { if case .passed = baselines[$0.name] { true } else { false } })
                }
                return round < policy.fixAttempts ? .fix : .stuck(.failedAfterFixes)
            }
        }
    }
}
