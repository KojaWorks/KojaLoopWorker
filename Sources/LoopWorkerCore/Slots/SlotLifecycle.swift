import Foundation

/// Where one slot lives. Built by the Manager from the host config; see DESIGN.md "State on disk".
public struct SlotSpec: Sendable, Hashable {
    public var project: ProjectSpec
    public var index: Int
    /// `<clones_dir>/<key>`.
    public var clone: URL
    /// `<clones_dir>/<key>.slots/<index>`, never inside the clone.
    public var worktree: URL
    /// First port of this slot's band, passed to scripts as `LOOPWORKER_PORT`.
    public var port: Int
    /// `$LOOPWORKER_HOME/slots/<key>/<index>`: brief, snapshot, launch script, outcome.
    public var stateDir: URL

    public init(project: ProjectSpec, index: Int, clone: URL, worktree: URL, port: Int, stateDir: URL) {
        self.project = project
        self.index = index
        self.clone = clone
        self.worktree = worktree
        self.port = port
        self.stateDir = stateDir
    }

    public var session: String { "lw-\(project.key)-\(index)" }
    public var outcomeFile: URL { stateDir.appending(path: "outcome.json") }
}

/// A lifecycle step failed; the Manager marks the slot broken and retries with backoff.
public struct SlotFailure: Error, CustomStringConvertible, Equatable {
    /// What failed and the tail of its redacted output, for the log and the status file.
    public var description: String
    /// The output looked like the container engine is down, so recovering the engine may
    /// fix this and every other slot that failed the same way.
    public var engineDown: Bool

    public init(_ description: String, engineDown: Bool = false) {
        self.description = description
        self.engineDown = engineDown
    }
}

/// Builds and tears down slots. Lifecycle scripts run from the contract directory with
/// `LOOPWORKER_SLOT_DIR` (the worktree) and `LOOPWORKER_PORT` set, under the contract's
/// timeouts, with output streamed to the log.
public protocol SlotLifecycle: Sendable {
    /// Hot slots: ensures the worktree exists and runs `provision.sh` once. Cold slots: no-op.
    func prepare(_ slot: SlotSpec, contract: ProjectContract) async throws(SlotFailure)

    /// Gets a slot ready for a card: resets the worktree to `origin/<base>`, checks out
    /// `branch`, then runs `reset.sh` (hot) or `provision.sh` (cold). Returns the base commit.
    func acquire(_ slot: SlotSpec, contract: ProjectContract, base: String, branch: String) async throws(SlotFailure) -> String

    /// After a card: cold slots run `teardown.sh`; hot slots do nothing, because `acquire`
    /// resets them. Best effort: logs failures, never throws.
    func recycle(_ slot: SlotSpec, contract: ProjectContract) async

    /// Removes a slot for good: `teardown.sh`, then the worktree. Best effort.
    func retire(_ slot: SlotSpec, contract: ProjectContract) async
}

/// Restarts the host's container engine after lifecycle scripts reported it down. One
/// instance per host, shared by every slot.
public protocol EngineRecovering: Sendable {
    /// Tries to bring the engine back. Returns true when it answers again. Returns false
    /// without doing anything when recovery is disabled or still backing off from the last
    /// attempt, so callers can call it freely.
    func recover() async -> Bool
}
