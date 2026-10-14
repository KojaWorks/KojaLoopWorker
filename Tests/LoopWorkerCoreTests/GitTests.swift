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
        _ = try await git.resetWorktree(slot(1), url: origin.path, base: "main", branch: branch, environment: [:])
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

        let base = try await f.git.resetWorktree(slot, url: f.origin.path, base: "main", branch: "loopworker-2-second", environment: [:])
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

        let first = try await f.git.push(slot, to: f.origin.path, branch: "loopworker-1-card", expected: nil, environment: [:])
        let remote = { try await f.run(["ls-remote", f.origin.path, "refs/heads/loopworker-1-card"]) }
        #expect(first == (try await f.run(["-C", slot.path, "rev-parse", "HEAD"])))
        #expect(try await remote().hasPrefix(first))

        try await f.run(["-C", slot.path, "commit", "--amend", "-m", "retried"])
        let second = try await f.git.push(slot, to: f.origin.path, branch: "loopworker-1-card", expected: first, environment: [:])
        #expect(try await remote().hasPrefix(second))
        #expect(second != first)
    }

    @Test("push never overwrites a branch that LoopWorker didn't push")
    func pushLeaseProtectsSomeoneElsesBranch() async throws {
        let f = try await GitFixture()
        defer { f.cleanUp() }
        try await f.run(["-C", f.seed.path, "push", "origin", "main:refs/heads/123-fix-login"])
        let theirs = try await f.run(["ls-remote", f.origin.path, "refs/heads/123-fix-login"])
        let slot = try await f.slotOnBranch("123-fix-login")
        try await f.commit(in: slot, file: "feature", "x\n")

        let rejected = try await #require(throws: PushRejected.self) {
            try await f.git.push(slot, to: f.origin.path, branch: "123-fix-login", expected: nil, environment: [:])
        }
        #expect(rejected.branch == "123-fix-login")
        await #expect(throws: PushRejected.self) {  // a lease on some other commit is refused too
            try await f.git.push(slot, to: f.origin.path, branch: "123-fix-login",
                                 expected: try await f.run(["-C", slot.path, "rev-parse", "HEAD"]), environment: [:])
        }
        #expect(try await f.run(["ls-remote", f.origin.path, "refs/heads/123-fix-login"]) == theirs)
    }

    @Test("credentialed fetch and push run no repo hook or credential helper and ignore a rewritten origin")
    func credentialedCallsIgnoreRepoConfig() async throws {
        let f = try await GitFixture()
        defer { f.cleanUp() }
        let slot = try await f.slotOnBranch("loopworker-1-card")
        let ran = f.root.appending(path: "ran")
        let recorder = f.root.appending(path: "record.sh")
        try f.write("#!/bin/sh\necho \"$0 $*\" >> '\(ran.path)'\ncat >> '\(ran.path)'\n", to: recorder)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorder.path)
        let hooks = f.clone.appending(path: ".git/hooks")
        for hook in ["pre-push", "reference-transaction", "post-merge"] {
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: hooks.appending(path: hook))
            try FileManager.default.createSymbolicLink(at: hooks.appending(path: hook), withDestinationURL: recorder)
        }
        let evil = f.root.appending(path: "evil.git")
        try await f.run(["init", "--bare", "-b", "main", evil.path])
        try await f.run(["-C", f.clone.path, "config", "credential.helper", "!\(recorder.path) helper"])
        try await f.run(["-C", f.clone.path, "config", "remote.origin.url", evil.path])
        try await f.run(["-C", f.clone.path, "config", "remote.origin.pushurl", evil.path])

        try await f.commit(in: slot, file: "feature", "x\n")
        try FileManager.default.removeItem(at: ran)  // the fixture's own commits ran the hooks
        _ = try await f.git.push(slot, to: f.origin.path, branch: "loopworker-1-card", expected: nil, environment: [:])
        // New commits on origin make each fetch update refs, which is what triggers the hooks.
        try await f.commit(in: f.seed, file: "README", "two\n")
        try await f.run(["-C", f.seed.path, "push", "origin", "main"])
        try await f.git.cloneOrFetch(url: f.origin.path, into: f.clone, environment: [:])
        #expect(!f.exists(ran), "\((try? f.read(ran)) ?? "")")
        try await f.commit(in: f.seed, file: "README", "three\n")
        try await f.run(["-C", f.seed.path, "push", "origin", "main"])
        _ = try await f.git.resetWorktree(slot, url: f.origin.path, base: "main", branch: "loopworker-2-next", environment: [:])
        // The local reset and checkout after the fetch still run hooks; they carry no credentials.
        #expect(!((try? f.read(ran)) ?? "").contains("refs/remotes/"))
        #expect(!((try? f.read(ran)) ?? "").contains("helper"))
        #expect(try f.read(slot.appending(path: "README")) == "three\n")
        #expect(try await f.run(["ls-remote", f.origin.path, "refs/heads/loopworker-1-card"]) != "")
        #expect(try await f.run(["ls-remote", evil.path]) == "")

        try await f.run(["-C", slot.path, "push", f.origin.path, "HEAD:refs/heads/control"])
        #expect(try f.read(ran).contains("pre-push"))  // the same hook does run for plain git
    }

    @Test("detach frees the card branch for another worktree")
    func detachFreesBranch() async throws {
        let f = try await GitFixture()
        defer { f.cleanUp() }
        let first = try await f.slotOnBranch("loopworker-1-card")
        try await f.git.ensureWorktree(clone: f.clone, worktree: f.slot(2), slot: 2)
        await #expect(throws: GitError.self) {
            try await f.git.resetWorktree(f.slot(2), url: f.origin.path, base: "main", branch: "loopworker-1-card", environment: [:])
        }
        try await f.git.detach(first)
        _ = try await f.git.resetWorktree(f.slot(2), url: f.origin.path, base: "main", branch: "loopworker-1-card", environment: [:])
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
            if spec.arguments.contains("clone"), let target = spec.arguments.last {
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
        _ = try await git.push(clone, to: "https://forge.invalid/a.git", branch: "b", expected: nil, environment: [:])
        try await git.detach(clone)
        let error = try await #require(throws: GitError.self) { try await git.commitsAhead(clone, base: "main") }
        #expect(error.description.contains("rev-list --count origin/main..HEAD timed out"))

        let calls = runner.calls
        #expect(calls.map { $0.timeout } == [.seconds(1800), .seconds(600), .seconds(120), .seconds(600), .seconds(120), .seconds(120)])  // push resolves HEAD first
        #expect(calls[0].environment["GIT_ASKPASS"] == "/x")
        #expect(calls[1].arguments == Git.credentialed + ["-C", clone.path, "fetch", "--prune", "https://forge.invalid/a.git", Git.trackingRefspec])
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

/// A `GitFixture` whose `main` stores `data.bin` in Git LFS. `url` is the origin as a `file://`
/// URL, so its LFS endpoint `<url>/info/lfs` is a local store that git-lfs's standalone file
/// transfer reads and writes; that store must be a bare repo.
struct LFSFixture {
    static let available = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":")
        .contains { FileManager.default.isExecutableFile(atPath: "\($0)/git-lfs") } ?? false
    static let pointerPrefix = "version https://git-lfs.github.com/spec/v1"

    let f: GitFixture
    var url: String { "file://\(f.origin.path)" }
    var store: URL { f.origin.appending(path: "info/lfs") }

    init() async throws {
        f = try await GitFixture()
        try await f.run(["init", "--bare", "-b", "main", store.path])
        try await f.run(["-C", f.seed.path, "lfs", "install", "--local"])
        try await f.run(["-C", f.seed.path, "lfs", "track", "*.bin"])
        try await f.run(["-C", f.seed.path, "add", ".gitattributes"])
        try await commitData("first content\n")
    }

    /// Commits `data.bin` in the seed and pushes it, LFS content included, to origin.
    func commitData(_ contents: String) async throws {
        try await f.commit(in: f.seed, file: "data.bin", contents)
        try await f.run(["-C", f.seed.path, "-c", "lfs.url=\(url)/info/lfs", "push", "origin", "main"])
    }

    /// The oid of `file`'s LFS object at HEAD in `repo`.
    func oid(_ repo: URL, _ file: String) async throws -> String {
        let pointer = try await f.run(["-C", repo.path, "cat-file", "-p", "HEAD:\(file)"])
        return try #require(pointer.split(separator: "\n").first { $0.hasPrefix("oid sha256:") }).dropFirst("oid sha256:".count).description
    }

    func stored(_ oid: String) -> Bool {
        f.exists(store.appending(path: "lfs/objects/\(oid.prefix(2))/\(oid.dropFirst(2).prefix(2))/\(oid)"))
    }

    func lifecycle(_ remoteURL: String) -> ScriptedSlotLifecycle {
        ScriptedSlotLifecycle(runner: f.runner, git: f.git, log: f.log,
                              gitRemote: { _ in (remoteURL, ["LOOPWORKER_GIT_PASSWORD": "fabricated-forge-password"]) })
    }

    /// Slot 1 of a cold project whose provision script prints `data.bin` and whether it can
    /// see the forge password.
    func slot() throws -> (SlotSpec, ProjectContract) {
        let contract = f.root.appending(path: "contract")
        try f.write("echo \"content: $(cat data.bin)\"\necho \"password: ${LOOPWORKER_GIT_PASSWORD:-none}\"\n",
                    to: contract.appending(path: "provision.sh"))
        let spec = SlotSpec(project: ProjectSpec(path: "proj"), index: 1, clone: f.clone, worktree: f.slot(1),
                            port: 54400, stateDir: f.root.appending(path: "state/1"))
        return (spec, ProjectContract(directory: contract))
    }
}

@Suite(.enabled(if: LFSFixture.available, "git-lfs is not on PATH")) struct GitLFSTests {
    @Test("B157, B159: acquire pulls LFS content that a credential-free provision script then reads")
    func acquirePullsLFSContent() async throws {
        let l = try await LFSFixture()
        defer { l.f.cleanUp() }
        try await l.f.git.cloneOrFetch(url: l.url, into: l.f.clone, environment: [:])
        #expect(try l.f.read(l.f.clone.appending(path: "data.bin")).hasPrefix(LFSFixture.pointerPrefix))
        #expect(try await l.f.git.usesLFS(l.f.clone))

        let (slot, contract) = try l.slot()
        _ = try await l.lifecycle(l.url).acquire(slot, contract: contract, base: "main", branch: "loopworker-1-card")
        #expect(try l.f.read(slot.worktree.appending(path: "data.bin")) == "first content\n")
        let lines = l.f.log.lines.map(\.1)
        #expect(lines.contains("[proj/1 provision] content: first content"), "\(lines)")
        #expect(lines.contains("[proj/1 provision] password: none"))
        #expect(lines.contains { $0.hasPrefix("proj/1: pulled Git LFS content in") })
        #expect(try await l.f.run(["-C", slot.worktree.path, "status", "--porcelain"]) == "")
    }

    @Test("B156, B159: a reset never downloads LFS content, and a failed pull fails the slot")
    func resetSkipsSmudgeAndAFailedPullFailsTheSlot() async throws {
        let l = try await LFSFixture()
        defer { l.f.cleanUp() }
        let slot = try await l.f.slotOnBranch("loopworker-1-first")
        try await l.f.run(["-C", l.f.clone.path, "lfs", "install", "--local"])  // a smudging filter, as a host-wide install gives
        try await l.commitData("second content\n")
        let away = l.f.root.appending(path: "lfs-away")
        try FileManager.default.moveItem(at: l.store, to: away)

        _ = try await l.f.git.resetWorktree(slot, url: l.url, base: "main", branch: "loopworker-2-second", environment: [:])
        #expect(try l.f.read(slot.appending(path: "data.bin")).hasPrefix(LFSFixture.pointerPrefix))
        let error = try await #require(throws: GitError.self) {
            try await l.f.git.lfsPull(slot, url: l.url, include: [], exclude: [], timeout: .seconds(60), environment: [:])
        }
        #expect(error.command.contains("lfs pull"))

        let (spec, contract) = try l.slot()
        let failure = try await #require(throws: SlotFailure.self) {
            try await l.lifecycle(l.url).acquire(spec, contract: contract, base: "main", branch: "loopworker-3-third")
        }
        #expect(failure.description.contains("proj/1: pulling Git LFS content into \(slot.path) failed: git "))
        #expect(!l.f.log.lines.contains { $0.1.contains("provision]") })
    }

    @Test("B158: lfsPush uploads the worker's new LFS object, and the pushed commit holds its pointer")
    func lfsPushUploadsNewObjects() async throws {
        let l = try await LFSFixture()
        defer { l.f.cleanUp() }
        try await l.f.git.cloneOrFetch(url: l.url, into: l.f.clone, environment: [:])
        let (slot, contract) = try l.slot()
        _ = try await l.lifecycle(l.url).acquire(slot, contract: contract, base: "main", branch: "loopworker-1-card")
        try await l.f.commit(in: slot.worktree, file: "data.bin", "worker content\n")
        let oid = try await l.oid(slot.worktree, "data.bin")
        #expect(!l.stored(oid))

        try await l.f.git.lfsPush(slot.worktree, url: l.url, environment: [:])
        _ = try await l.f.git.push(slot.worktree, to: l.url, branch: "loopworker-1-card", expected: nil, environment: [:])
        #expect(l.stored(oid))
        let pushed = try await l.f.run(["-C", l.f.origin.path, "cat-file", "-p", "loopworker-1-card:data.bin"])
        #expect(pushed.hasPrefix(LFSFixture.pointerPrefix))
        #expect(pushed.contains(oid))
    }

    @Test("B157: usesLFS reads every .gitattributes in HEAD, at any depth")
    func usesLFS() async throws {
        let f = try await GitFixture()
        defer { f.cleanUp() }
        #expect(try await !f.git.usesLFS(f.seed))
        try await f.commit(in: f.seed, file: ".gitattributes", "*.txt text\n")
        #expect(try await !f.git.usesLFS(f.seed))
        try await f.commit(in: f.seed, file: "assets/art/.gitattributes", "*.psd filter=lfs diff=lfs merge=lfs -text\n")
        #expect(try await f.git.usesLFS(f.seed))
    }
}
