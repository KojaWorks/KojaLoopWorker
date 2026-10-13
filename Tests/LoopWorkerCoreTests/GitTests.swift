import Foundation
import Testing
@testable import LoopWorkerCore

final class RecordingLog: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(LogLevel, String)] = []
    var lines: [(LogLevel, String)] { lock.withLock { recorded } }
    func log(_ level: LogLevel, _ message: String) { lock.withLock { recorded.append((level, message)) } }
}

/// A bare `origin` with one commit on `main`, a `seed` clone that pushes to it, and a `Git`
/// whose commands can't see the host's git config.
struct GitFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "lw-git-\(UUID().uuidString)")
    let runner = BaseEnvironmentRunner(base: [
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
        "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
    ])
    let log = RecordingLog()
    var origin: URL { root.appending(path: "origin.git") }
    var seed: URL { root.appending(path: "seed") }
    var clone: URL { root.appending(path: "clones/proj") }
    func slot(_ n: Int) -> URL { root.appending(path: "clones/proj.slots/\(n)") }
    var git: Git { Git(runner: runner, log: log) }

    init() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await run(["init", "--bare", "-b", "main", origin.path])
        try await run(["init", "-b", "main", seed.path])
        try await commit(in: seed, file: ".gitignore", "CLAUDE.local.md\n.claude/\n.build/\n")
        try await commit(in: seed, file: "README", "one\n")
        try await run(["-C", seed.path, "remote", "add", "origin", origin.path])
        try await run(["-C", seed.path, "push", "origin", "main"])
    }

    @discardableResult
    func run(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(ProcessSpec("git", arguments, timeout: .seconds(30)))
        guard result.succeeded else { throw GitError(command: arguments.joined(separator: " "), result: result) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commit(in repo: URL, file: String, _ contents: String) async throws {
        try write(contents, to: repo.appending(path: file))
        try await run(["-C", repo.path, "add", file])
        try await run(["-C", repo.path, "commit", "-m", "change \(file)"])
    }

    func write(_ contents: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func read(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }
    func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Cloned, with a worktree for slot 1 reset onto `branch`.
    func slotOnBranch(_ branch: String) async throws -> URL {
        try await git.cloneOrFetch(url: origin.path, into: clone, environment: [:])
        try await git.ensureWorktree(clone: clone, worktree: slot(1), slot: 1)
        _ = try await git.resetWorktree(slot(1), base: "main", branch: branch, environment: [:])
        return slot(1)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct GitTests {
    @Test("B22: clone, then fetch and sync the checkout to origin")
    func cloneFetchSync() async throws {
        let f = try await GitFixture()
        defer { f.cleanUp() }
        try await f.git.cloneOrFetch(url: f.origin.path, into: f.clone, environment: [:])
        #expect(try f.read(f.clone.appending(path: "README")) == "one\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.clone.deletingLastPathComponent().path) == ["proj"])

        try await f.commit(in: f.seed, file: "README", "two\n")
        try await f.run(["-C", f.seed.path, "push", "origin", "main"])
        try f.write("dirty\n", to: f.clone.appending(path: "README"))
        try f.write("stray\n", to: f.clone.appending(path: "untracked"))
        try await f.git.cloneOrFetch(url: f.origin.path, into: f.clone, environment: [:])
        try await f.git.syncCheckout(f.clone, base: "main")
        #expect(try f.read(f.clone.appending(path: "README")) == "two\n")
        #expect(!f.exists(f.clone.appending(path: "untracked")))
    }

    @Test("B23: ensureWorktree creates the slot branch outside the clone, and is idempotent")
    func ensureWorktree() async throws {
        let f = try await GitFixture()
        defer { f.cleanUp() }
        try await f.git.cloneOrFetch(url: f.origin.path, into: f.clone, environment: [:])
        try await f.git.ensureWorktree(clone: f.clone, worktree: f.slot(1), slot: 1)
        #expect(try await f.run(["-C", f.slot(1).path, "branch", "--show-current"]) == "loopworker-slot-1")
        try f.write("keep\n", to: f.slot(1).appending(path: "marker"))
        try await f.git.ensureWorktree(clone: f.clone, worktree: f.slot(1), slot: 1)
        #expect(f.exists(f.slot(1).appending(path: "marker")))
    }

    @Test("B24: resetWorktree discards the last card's state but keeps ignored build caches")
    func resetWorktree() async throws {
        let f = try await GitFixture()
        defer { f.cleanUp() }
        let slot = try await f.slotOnBranch("loopworker-1-first")
        try f.write("dirty\n", to: slot.appending(path: "README"))
        try f.write("stray\n", to: slot.appending(path: "untracked"))
        try f.write("leftover instructions\n", to: slot.appending(path: "CLAUDE.local.md"))
        try f.write("{}\n", to: slot.appending(path: ".claude/settings.local.json"))
        try f.write("cache\n", to: slot.appending(path: ".build/cache"))
        try await f.commit(in: f.seed, file: "README", "two\n")
        try await f.run(["-C", f.seed.path, "push", "origin", "main"])

        let base = try await f.git.resetWorktree(slot, base: "main", branch: "loopworker-2-second", environment: [:])
        #expect(base == (try await f.run(["-C", f.seed.path, "rev-parse", "HEAD"])))
        #expect(try await f.run(["-C", slot.path, "branch", "--show-current"]) == "loopworker-2-second")
        #expect(try f.read(slot.appending(path: "README")) == "two\n")
        #expect(!f.exists(slot.appending(path: "untracked")))
        #expect(!f.exists(slot.appending(path: "CLAUDE.local.md")))
        #expect(!f.exists(slot.appending(path: ".claude")))
        #expect(f.exists(slot.appending(path: ".build/cache")))
    }

    @Test("B26, B27: commitsAhead counts the card's commits, push creates and force-updates the branch")
    func commitsAheadAndPush() async throws {
        let f = try await GitFixture()
        defer { f.cleanUp() }
        let slot = try await f.slotOnBranch("loopworker-1-card")
        #expect(try await f.git.commitsAhead(slot, base: "main") == 0)
        try await f.commit(in: slot, file: "feature", "x\n")
        #expect(try await f.git.commitsAhead(slot, base: "main") == 1)

        try await f.git.push(slot, branch: "loopworker-1-card", environment: [:])
        let remote = { try await f.run(["ls-remote", f.origin.path, "refs/heads/loopworker-1-card"]) }
        #expect(try await remote().hasPrefix(try await f.run(["-C", slot.path, "rev-parse", "HEAD"])))

        try await f.run(["-C", slot.path, "commit", "--amend", "-m", "retried"])
        try await f.git.push(slot, branch: "loopworker-1-card", environment: [:])
        #expect(try await remote().hasPrefix(try await f.run(["-C", slot.path, "rev-parse", "HEAD"])))
    }

    @Test("detach frees the card branch for another worktree")
    func detachFreesBranch() async throws {
        let f = try await GitFixture()
        defer { f.cleanUp() }
        let first = try await f.slotOnBranch("loopworker-1-card")
        try await f.git.ensureWorktree(clone: f.clone, worktree: f.slot(2), slot: 2)
        await #expect(throws: GitError.self) {
            try await f.git.resetWorktree(f.slot(2), base: "main", branch: "loopworker-1-card", environment: [:])
        }
        try await f.git.detach(first)
        _ = try await f.git.resetWorktree(f.slot(2), base: "main", branch: "loopworker-1-card", environment: [:])
        #expect(try await f.run(["-C", f.slot(2).path, "branch", "--show-current"]) == "loopworker-1-card")
    }

    @Test("B28: removeWorktree removes and prunes, and only logs a failure")
    func removeWorktree() async throws {
        let f = try await GitFixture()
        defer { f.cleanUp() }
        let slot = try await f.slotOnBranch("loopworker-1-card")
        try f.write("dirty\n", to: slot.appending(path: "README"))
        await f.git.removeWorktree(clone: f.clone, worktree: slot)
        #expect(!f.exists(slot))
        #expect(!(try await f.run(["-C", f.clone.path, "worktree", "list"])).contains(slot.lastPathComponent + "\n"))
        #expect(f.log.lines.isEmpty)

        await f.git.removeWorktree(clone: f.clone, worktree: slot)
        #expect(f.log.lines.contains { $0.0 == .warning && $0.1.contains(slot.path) })
    }

    /// A runner that "clones" by creating the target directory, and times out on `timingOut`.
    static func fakeGit(timingOut: String) -> FakeRunner {
        FakeRunner { spec in
            if spec.arguments.first == "clone", let target = spec.arguments.last {
                try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
            }
            return spec.arguments.contains(timingOut) ? ProcessResult(status: -9, output: "", timedOut: true)
                : ProcessResult(status: 0, output: "abc\n")
        }
    }

    @Test("B20, B21: per-operation timeouts, the forge environment passed through, a timeout names the command")
    func timeouts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lw-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = Self.fakeGit(timingOut: "rev-list")
        let git = Git(runner: runner, log: RecordingLog())
        let clone = root.appending(path: "clones/proj")
        try await git.cloneOrFetch(url: "https://forge.invalid/a.git", into: clone, environment: ["GIT_ASKPASS": "/x"])
        #expect(FileManager.default.fileExists(atPath: clone.path))
        try await git.cloneOrFetch(url: "https://forge.invalid/a.git", into: clone, environment: [:])
        try await git.push(clone, branch: "b", environment: [:])
        try await git.detach(clone)
        let error = try await #require(throws: GitError.self) { try await git.commitsAhead(clone, base: "main") }
        #expect(error.description.contains("rev-list --count origin/main..HEAD timed out"))

        let calls = runner.calls
        #expect(calls.map { $0.timeout } == [.seconds(1800), .seconds(600), .seconds(600), .seconds(120), .seconds(120)])
        #expect(calls[0].environment["GIT_ASKPASS"] == "/x")
        #expect(calls[1].arguments == ["-C", clone.path, "fetch", "--prune", "origin"])
    }

    @Test("a clone killed at its timeout leaves no half-clone behind")
    func timedOutClone() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lw-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = Git(runner: Self.fakeGit(timingOut: "clone"), log: RecordingLog())
        let clone = root.appending(path: "clones/proj")
        let error = try await #require(throws: GitError.self) {
            try await git.cloneOrFetch(url: "https://forge.invalid/a.git", into: clone, environment: [:])
        }
        #expect(error.description.contains("clone https://forge.invalid/a.git"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: clone.deletingLastPathComponent().path) == [])
    }
}
