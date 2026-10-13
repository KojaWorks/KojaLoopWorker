import Foundation

public struct GitError: Error, CustomStringConvertible {
    public var command: String
    public var result: ProcessResult
    public init(command: String, result: ProcessResult) {
        self.command = command
        self.result = result
    }
    public var description: String {
        let why = result.timedOut ? "timed out" : "exited \(result.status)"
        return "git \(command) \(why): \(result.output.suffix(2000))"
    }
}

/// The git operations the Manager needs. Every call takes the forge's environment, so
/// credentials come from the forge's askpass helper, and runs under a timeout.
public protocol GitDriving: Sendable {
    /// Clones `url` to `directory` if it doesn't exist, otherwise fetches `origin`.
    func cloneOrFetch(url: String, into directory: URL, environment: [String: String]) async throws

    /// Hard-resets the clone's own working tree to `origin/<base>`, after a fetch. The repo's
    /// project contract is read from there, so it always matches the base branch.
    func syncCheckout(_ clone: URL, base: String) async throws

    /// Detaches HEAD in `worktree` so the card branch is free for another worktree.
    func detach(_ worktree: URL) async throws

    /// Ensures a worktree for slot `slot` exists at `worktree`, on the local branch
    /// `loopworker-slot-<slot>`, without nesting it inside the clone.
    func ensureWorktree(clone: URL, worktree: URL, slot: Int) async throws

    /// Fetches, hard-resets the worktree to `origin/<base>`, removes untracked files (and
    /// ignored agent files such as `CLAUDE.local.md` and `.claude/`, so one card's worker can't
    /// leave instructions for the next), and checks out a fresh `branch` there. Returns the
    /// resolved base commit.
    func resetWorktree(_ worktree: URL, base: String, branch: String, environment: [String: String]) async throws -> String

    /// Number of commits on HEAD that `origin/<base>` doesn't have.
    func commitsAhead(_ worktree: URL, base: String) async throws -> Int

    /// Pushes HEAD to `branch` on origin, creating or force-updating it.
    func push(_ worktree: URL, branch: String, environment: [String: String]) async throws

    /// Removes the worktree directory (`git worktree remove --force`) and prunes. Best effort:
    /// logs failures, never throws.
    func removeWorktree(clone: URL, worktree: URL) async
}
