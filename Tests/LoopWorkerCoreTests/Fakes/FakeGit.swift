import Foundation
@testable import LoopWorkerCore

/// Records git calls. `cloneOrFetch` creates the clone directory, so a contract written into
/// it by the test is found where the Manager looks.
final class FakeGit: GitDriving, @unchecked Sendable {
    struct State {
        var calls: [String] = []
        var pushes: [(worktree: URL, url: String, branch: String, expected: String?, environment: [String: String])] = []
        /// When set, the next push throws this instead.
        var pushFailure: (any Error)?
        var fetchEnvironments: [[String: String]] = []
        var commitsAhead: [String: Int] = [:]
        var defaultCommitsAhead = 1
        var failCloneOrFetch = false
        var failPushOnce = false
    }

    let state = Guarded(State())
    var calls: [String] { state.get.calls }
    var pushedBranches: [String] { state.get.pushes.map(\.branch) }

    func cloneOrFetch(url: String, into directory: URL, environment: [String: String]) async throws {
        try state {
            $0.calls.append("cloneOrFetch \(directory.lastPathComponent)")
            $0.fetchEnvironments.append(environment)
            if $0.failCloneOrFetch { throw FakeError("git fetch \(url) failed") }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func syncCheckout(_ clone: URL, base: String) async throws {
        state { $0.calls.append("syncCheckout \(clone.lastPathComponent) \(base)") }
    }

    func detach(_ worktree: URL) async throws {
        state { $0.calls.append("detach \(worktree.path)") }
    }

    func ensureWorktree(clone: URL, worktree: URL, slot: Int) async throws {
        state { $0.calls.append("ensureWorktree \(slot)") }
    }

    func resetWorktree(_ worktree: URL, url: String, base: String, branch: String, environment: [String: String]) async throws -> String {
        state { $0.calls.append("resetWorktree \(branch)") }
        return "base123"
    }

    func commitsAhead(_ worktree: URL, base: String) async throws -> Int {
        state { $0.commitsAhead[worktree.path] ?? $0.defaultCommitsAhead }
    }

    /// Returns `commit-<n>` for the n-th successful push.
    func push(_ worktree: URL, to url: String, branch: String, expected: String?, environment: [String: String]) async throws -> String {
        try state {
            if $0.failPushOnce { $0.failPushOnce = false; throw FakeError("git push \(branch) failed") }
            if let e = $0.pushFailure { $0.pushFailure = nil; throw e }
            $0.pushes.append((worktree, url, branch, expected, environment))
            return "commit-\($0.pushes.count)"
        }
    }

    func removeWorktree(clone: URL, worktree: URL) async {
        state { $0.calls.append("removeWorktree \(worktree.path)") }
    }
}
