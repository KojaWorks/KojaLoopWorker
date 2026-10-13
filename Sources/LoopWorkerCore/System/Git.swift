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

/// The forge refused a push because `branch` there isn't at the commit the Manager expected:
/// someone else made or moved a branch of that name. Retrying can't fix it.
public struct PushRejected: Error, CustomStringConvertible, Equatable {
    public var branch: String
    public var url: String
    public init(branch: String, url: String) {
        self.branch = branch
        self.url = url
    }
    public var description: String { "\(url) refused the push of \(branch): the branch there is not the one LoopWorker last pushed" }
}

/// The git operations the Manager needs. Every call runs under a timeout.
///
/// Calls that talk to the forge take its URL and environment (askpass credentials). They
/// never use `origin`, hooks, fsmonitor or credential helpers: a worktree shares `.git/config`
/// and hooks with its clone, and the worker controls both, so a rewritten
/// `remote.origin.url`, a `pre-push` hook or a credential helper would otherwise see the token.
public protocol GitDriving: Sendable {
    /// Clones `url` to `directory` if it doesn't exist, otherwise fetches `url`'s branches into
    /// the `origin/*` tracking refs, pruning deleted ones.
    func cloneOrFetch(url: String, into directory: URL, environment: [String: String]) async throws

    /// Hard-resets the clone's own working tree to `origin/<base>`, after a fetch. The repo's
    /// project contract is read from there, so it always matches the base branch.
    func syncCheckout(_ clone: URL, base: String) async throws

    /// Detaches HEAD in `worktree` so the card branch is free for another worktree.
    func detach(_ worktree: URL) async throws

    /// Ensures a worktree for slot `slot` exists at `worktree`, on the local branch
    /// `loopworker-slot-<slot>`, without nesting it inside the clone.
    func ensureWorktree(clone: URL, worktree: URL, slot: Int) async throws

    /// Fetches `url`'s branches into the `origin/*` tracking refs, hard-resets the worktree to
    /// `origin/<base>`, removes untracked files (and ignored agent files such as
    /// `CLAUDE.local.md` and `.claude/`, so one card's worker can't leave instructions for the
    /// next), and checks out a fresh `branch` there. Returns the resolved base commit.
    func resetWorktree(_ worktree: URL, url: String, base: String, branch: String, environment: [String: String]) async throws -> String

    /// Number of commits on HEAD that `origin/<base>` doesn't have.
    func commitsAhead(_ worktree: URL, base: String) async throws -> Int

    /// Pushes HEAD to `branch` at `url` without running hooks, and returns the pushed commit.
    /// - Parameter expected: the commit that `branch` must be at on the forge, the one the
    ///   Manager last pushed for this card; nil means the branch must not exist yet. A branch
    ///   at that commit is force-updated.
    /// - Throws: `PushRejected` when the branch on the forge doesn't match `expected`;
    ///   `GitError` for any other failure.
    func push(_ worktree: URL, to url: String, branch: String, expected: String?, environment: [String: String]) async throws -> String

    /// Removes the worktree directory (`git worktree remove --force`) and prunes. Best effort:
    /// logs failures, never throws.
    func removeWorktree(clone: URL, worktree: URL) async
}

/// `GitDriving` over the `git` CLI. Each call throws `GitError` naming the command when git
/// fails or exceeds its timeout: 30 min for clone, 10 min for fetch and push, 2 min for local
/// operations.
public struct Git: GitDriving {
    private let runner: any ProcessRunning
    private let log: any LogSink

    /// - Parameters:
    ///   - runner: Runs every git command.
    ///   - log: Receives the failures of `removeWorktree`, which never throws.
    public init(runner: any ProcessRunning, log: any LogSink) {
        self.runner = runner
        self.log = log
    }

    private static let cloneTimeout: Duration = .seconds(30 * 60)
    private static let networkTimeout: Duration = .seconds(10 * 60)
    private static let localTimeout: Duration = .seconds(2 * 60)

    /// Prefix for every call that carries forge credentials. The empty `credential.helper`
    /// resets the helper list, so no configured helper is asked to store the password.
    static let credentialed = ["-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "-c", "core.fsmonitor=false"]
    static let trackingRefspec = "+refs/heads/*:refs/remotes/origin/*"

    /// Clones into a temporary sibling and renames it into place, so a clone killed at its
    /// timeout leaves no half-clone at `directory` for later fetches to fail on.
    public func cloneOrFetch(url: String, into directory: URL, environment: [String: String]) async throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try await git(Self.credentialed + ["-C", directory.path, "fetch", "--prune", url, Self.trackingRefspec],
                          Self.networkTimeout, environment)
            return
        }
        let partial = directory.deletingLastPathComponent()
            .appending(path: ".\(directory.lastPathComponent).cloning-\(UUID().uuidString.prefix(8))")
        do {
            try await git(Self.credentialed + ["clone", url, partial.path], Self.cloneTimeout, environment)
            try FileManager.default.moveItem(at: partial, to: directory)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    public func syncCheckout(_ clone: URL, base: String) async throws {
        try await git(["-C", clone.path, "reset", "--hard", "origin/\(base)"])
        try await git(["-C", clone.path, "clean", "-fd"])
    }

    public func detach(_ worktree: URL) async throws {
        try await git(["-C", worktree.path, "checkout", "--detach"])
    }

    public func ensureWorktree(clone: URL, worktree: URL, slot: Int) async throws {
        if try await isWorktree(worktree, of: clone) { return }
        try FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git(["-C", clone.path, "worktree", "prune"])
        try await git(["-C", clone.path, "worktree", "add", "-B", "loopworker-slot-\(slot)", worktree.path, "HEAD"])
    }

    public func resetWorktree(_ worktree: URL, url: String, base: String, branch: String, environment: [String: String]) async throws -> String {
        let path = worktree.path
        try await git(Self.credentialed + ["-C", path, "fetch", url, Self.trackingRefspec], Self.networkTimeout, environment)
        try await git(["-C", path, "reset", "--hard", "origin/\(base)"])
        // Plain -fd keeps ignored build caches, which keeps hot slots fast.
        try await git(["-C", path, "clean", "-fd"])
        try await git(["-C", path, "clean", "-fdx", "--", ".claude", "CLAUDE.local.md"])
        try await git(["-C", path, "checkout", "-B", branch])
        return try await git(["-C", path, "rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func commitsAhead(_ worktree: URL, base: String) async throws -> Int {
        let command = ["-C", worktree.path, "rev-list", "--count", "origin/\(base)..HEAD"]
        let result = try await git(command)
        guard let count = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw GitError(command: command.joined(separator: " "), result: result)
        }
        return count
    }

    /// The lease names its expected value, because a push to a URL has no tracking ref to
    /// lease against.
    public func push(_ worktree: URL, to url: String, branch: String, expected: String?, environment: [String: String]) async throws -> String {
        let head = try await git(["-C", worktree.path, "rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = Self.credentialed + ["-C", worktree.path, "push", "--no-verify",
                                             "--force-with-lease=refs/heads/\(branch):\(expected ?? "")", url, "\(head):refs/heads/\(branch)"]
        let result = try await runner.run(ProcessSpec("git", arguments, environment: environment.mapValues { $0 }, timeout: Self.networkTimeout))
        if result.succeeded { return head }
        if result.output.contains("stale info") { throw PushRejected(branch: branch, url: url) }
        throw GitError(command: arguments.joined(separator: " "), result: result)
    }

    public func removeWorktree(clone: URL, worktree: URL) async {
        for command in [["worktree", "remove", "--force", worktree.path], ["worktree", "prune"]] {
            do {
                try await git(["-C", clone.path] + command)
            } catch {
                log.warning("removing worktree \(worktree.path): \(error)")
            }
        }
    }

    /// True when `worktree` is the top level of a worktree that shares `clone`'s repository.
    private func isWorktree(_ worktree: URL, of clone: URL) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: worktree.path) else { return false }
        let probe = try await runner.run(ProcessSpec(
            "git", ["-C", worktree.path, "rev-parse", "--show-toplevel", "--git-common-dir"], timeout: Self.localTimeout))
        let lines = probe.output.split(separator: "\n").map(String.init)
        guard probe.succeeded, lines.count == 2 else { return false }
        let cloneCommon = try await git(["-C", clone.path, "rev-parse", "--git-common-dir"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.same(URL(filePath: lines[0]), worktree)
            && Self.same(Self.resolve(lines[1], in: worktree), Self.resolve(cloneCommon, in: clone))
    }

    /// rev-parse prints `--git-common-dir` relative to `-C` in a main checkout, absolute in a worktree.
    private static func resolve(_ path: String, in directory: URL) -> URL {
        path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    @discardableResult
    private func git(_ arguments: [String], _ timeout: Duration = localTimeout, _ environment: [String: String] = [:]) async throws -> ProcessResult {
        let result = try await runner.run(ProcessSpec(
            "git", arguments, environment: environment.mapValues { $0 }, timeout: timeout))
        guard result.succeeded else { throw GitError(command: arguments.joined(separator: " "), result: result) }
        return result
    }
}
