import Foundation

/// Worker sessions on the Manager's own tmux server. Session names are `SlotSpec.session`.
public protocol TmuxDriving: Sendable {
    /// Names of live sessions that start with `prefix`.
    func sessions(prefix: String) async throws -> [String]

    /// Starts a detached session running `script` (an executable file) in `directory`.
    /// Secrets reach the worker through files that the script sources, never through tmux
    /// arguments, which other users can read with `ps`.
    func spawn(session: String, directory: URL, script: URL) async throws

    /// True when the session exists and its pane runs something other than a shell. A
    /// finished-but-idle `claude` counts as alive; the outcome file says when it is done.
    func isAlive(_ session: String) async throws -> Bool

    /// The last `lines` lines of the session's pane, for auth-failure and trust-dialog
    /// detection and for the status file.
    func capture(_ session: String, lines: Int) async throws -> String

    /// Presses Enter in the session. Used only to accept claude's folder-trust dialog after
    /// `capture` showed it.
    func sendEnter(_ session: String) async throws

    /// Kills the session. Killing a session that doesn't exist is not an error.
    func kill(_ session: String) async throws
}
