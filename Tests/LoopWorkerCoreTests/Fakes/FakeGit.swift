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
        /// `commitsAhead` per base branch, before `commitsAhead` per worktree.
        var aheadOfBase: [String: Int] = [:]
        /// `commitsSince` per commit; else `defaultCommitsAhead`.
        var commitsSince: [String: Int] = [:]
        var failCloneOrFetch = false
        var failPushOnce = false
        var usesLFS = false
        var failLFSPushOnce = false
        /// Branches on the forge; a push adds its branch.
        var remoteBranches: Set<String> = []
        var failHasRemoteBranch = false
        /// `resolve` per ref; else `resolved-<ref>`.
        var refs: [String: String] = [:]
        /// `isAncestor` per ancestor ref; else true.
        var ancestors: [String: Bool] = [:]
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

    func hasRemoteBranch(_ repo: URL, branch: String) async throws -> Bool {
        try state {
            $0.calls.append("hasRemoteBranch \(branch)")
            if $0.failHasRemoteBranch { throw FakeError("git rev-parse origin/\(branch) failed") }
            return $0.remoteBranches.contains(branch)
        }
    }

    func commitsAhead(_ worktree: URL, base: String) async throws -> Int {
        state {
            $0.calls.append("commitsAhead \(base)")
            return $0.aheadOfBase[base] ?? $0.commitsAhead[worktree.path] ?? $0.defaultCommitsAhead
        }
    }

    func commitsSince(_ worktree: URL, commit: String) async throws -> Int {
        state {
            $0.calls.append("commitsSince \(commit)")
            return $0.commitsSince[commit] ?? $0.defaultCommitsAhead
        }
    }

    func resolve(_ repo: URL, ref: String) async throws -> String {
        state {
            $0.calls.append("resolve \(ref)")
            return $0.refs[ref] ?? "resolved-\(ref)"
        }
    }

    func isAncestor(_ worktree: URL, ancestor: String) async throws -> Bool {
        state {
            $0.calls.append("isAncestor \(ancestor)")
            return $0.ancestors[ancestor] ?? true
        }
    }

    /// Returns `commit-<n>` for the n-th successful push.
    func push(_ worktree: URL, to url: String, branch: String, expected: String?, environment: [String: String]) async throws -> String {
        try state {
            if $0.failPushOnce { $0.failPushOnce = false; throw FakeError("git push \(branch) failed") }
            if let e = $0.pushFailure { $0.pushFailure = nil; throw e }
            $0.pushes.append((worktree, url, branch, expected, environment))
            $0.calls.append("push \(branch)")
            $0.remoteBranches.insert(branch)
            return "commit-\($0.pushes.count)"
        }
    }

    func usesLFS(_ worktree: URL) async throws -> Bool { state.get.usesLFS }

    func lfsPull(_ worktree: URL, url: String, include: [String], exclude: [String], timeout: Duration, environment: [String: String]) async throws {
        state { $0.calls.append("lfsPull \(url)") }
    }

    func lfsPush(_ worktree: URL, url: String, environment: [String: String]) async throws {
        try state {
            if $0.failLFSPushOnce { $0.failLFSPushOnce = false; throw FakeError("git lfs push failed") }
            $0.calls.append("lfsPush \(url) \(environment == FakeForge.environment ? "forge-env" : "other-env")")
        }
    }

    func removeWorktree(clone: URL, worktree: URL) async {
        state { $0.calls.append("removeWorktree \(worktree.path)") }
    }
}
