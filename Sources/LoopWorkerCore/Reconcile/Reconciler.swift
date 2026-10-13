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

    public init(
        cardState: CardState?, sessionAlive: Bool, authFailed: Bool = false,
        outcomeAge: TimeInterval? = nil, runningFor: TimeInterval
    ) {
        self.cardState = cardState
        self.sessionAlive = sessionAlive
        self.authFailed = authFailed
        self.outcomeAge = outcomeAge
        self.runningFor = runningFor
    }
}

public enum ReleaseReason: String, Sendable, Equatable {
    case crashed, hung, auth
}

public enum SlotDecision: Sendable, Equatable {
    /// Healthy, or an outcome is still within its grace period.
    case keep
    /// The worker wrote its outcome: reap the session and run the finish task.
    case finish
    /// The card is gone or a human moved it out of `working`: reap and recycle without
    /// writing to the backlog. The string says what happened, for the log.
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
        if let age = o.outcomeAge {
            return (!o.sessionAlive || age >= policy.outcomeGrace) ? .finish : .keep
        }
        if !o.sessionAlive { return .release(.crashed) }
        if o.authFailed { return .release(.auth) }
        if o.runningFor > policy.wallclockCap { return .release(.hung) }
        return .keep
    }
}
