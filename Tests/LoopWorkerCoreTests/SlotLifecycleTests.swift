import Foundation
import Testing
@testable import LoopWorkerCore

private actor SlotFakeGit: GitDriving {
    var calls: [String] = []
    var resetError: (any Error)?

    func failReset(_ error: any Error) { resetError = error }

    func cloneOrFetch(url: String, into directory: URL, environment: [String: String]) async throws { calls.append("cloneOrFetch") }
    func syncCheckout(_ clone: URL, base: String) async throws { calls.append("syncCheckout") }
    func detach(_ worktree: URL) async throws { calls.append("detach \(worktree.lastPathComponent)") }
    func ensureWorktree(clone: URL, worktree: URL, slot: Int) async throws { calls.append("ensureWorktree \(slot)") }
    func resetWorktree(_ worktree: URL, url: String, base: String, branch: String, environment: [String: String]) async throws -> String {
        calls.append("resetWorktree \(url) \(base) \(branch) \(environment["GIT_ASKPASS"] ?? "-")")
        if let resetError { throw resetError }
        return "abc1234def5678901234567890abcdef12345678"
    }
    func commitsAhead(_ worktree: URL, base: String) async throws -> Int { 0 }
    func push(_ worktree: URL, to url: String, branch: String, environment: [String: String]) async throws { calls.append("push") }
    func removeWorktree(clone: URL, worktree: URL) async { calls.append("removeWorktree \(worktree.lastPathComponent)") }
}

private struct Fixture {
    let runner = FakeProcessRunner()
    let git = SlotFakeGit()
    let log = SlotTestLog()
    let contract: ProjectContract
    let root: URL

    init(scripts: [String] = ["provision.sh", "reset.sh", "teardown.sh"], configure: (inout ProjectContract.Scripts) -> Void = { _ in }) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "slots-\(UUID())")
        let dir = root.appending(path: "contract")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "app.slots/0"), withIntermediateDirectories: true)
        for s in scripts { try "exit 0\n".write(to: dir.appending(path: s), atomically: true, encoding: .utf8) }
        var s = ProjectContract.Scripts()
        configure(&s)
        contract = ProjectContract(directory: dir, scripts: s)
    }

    var lifecycle: ScriptedSlotLifecycle {
        ScriptedSlotLifecycle(runner: runner, git: git, log: log, gitRemote: { _ in ("https://forge.invalid/app.git", ["GIT_ASKPASS": "/askpass"]) })
    }

    func slot(hot: Bool) -> SlotSpec {
        SlotSpec(
            project: ProjectSpec(path: "group/app", hot: hot), index: 0,
            clone: root.appending(path: "app"), worktree: root.appending(path: "app.slots/0"),
            port: 54400, stateDir: root.appending(path: "state/0"))
    }

    func scriptsRun() -> [String] {
        runner.calls.filter { $0.executable == "bash" }.map { URL(filePath: $0.arguments[0]).lastPathComponent }
    }
}

@Suite struct SlotLifecycleTests {
    @Test("B29: scripts run from the worktree with the slot environment and the contract timeout")
    func scriptEnvironment() async throws {
        let f = try Fixture()
        f.runner.on("bash") { _ in ProcessResult(status: 0, output: "stack up\nanon key SECRET") }
        let slot = f.slot(hot: true)
        try await f.lifecycle.prepare(slot, contract: f.contract)

        let call = try #require(f.runner.calls.first)
        #expect(call.executable == "bash")
        #expect(call.arguments == [f.contract.directory.appending(path: "provision.sh").path])
        #expect(call.workingDirectory == slot.worktree)
        #expect(call.environment["LOOPWORKER_SLOT_DIR"] == slot.worktree.path)
        #expect(call.environment["LOOPWORKER_PORT"] == "54400")
        #expect(call.environment["LOOPWORKER_PROJECT"] == "group/app")
        #expect(call.timeout == .seconds(45 * 60))
        #expect(f.log.lines.contains("[group--app/0 provision] stack up"))
        #expect(f.log.lines.contains("[group--app/0 provision] anon key [REDACTED]"))
    }

    @Test("B34: prepare provisions a hot slot once and does nothing for a cold one")
    func prepare() async throws {
        let f = try Fixture()
        try await f.lifecycle.prepare(f.slot(hot: true), contract: f.contract)
        #expect(await f.git.calls == ["ensureWorktree 0"])
        #expect(f.scriptsRun() == ["provision.sh"])

        let cold = try Fixture()
        try await cold.lifecycle.prepare(cold.slot(hot: false), contract: cold.contract)
        #expect(await cold.git.calls.isEmpty)
        #expect(cold.runner.calls.isEmpty)
    }

    @Test("B35: a cold slot provisions on acquire and tears down on recycle")
    func coldAcquireAndRecycle() async throws {
        let f = try Fixture()
        let slot = f.slot(hot: false)
        let commit = try await f.lifecycle.acquire(slot, contract: f.contract, base: "main", branch: "loopworker-12-fix")
        #expect(commit == "abc1234def5678901234567890abcdef12345678")
        #expect(await f.git.calls == ["ensureWorktree 0", "resetWorktree https://forge.invalid/app.git main loopworker-12-fix /askpass"])
        #expect(f.scriptsRun() == ["provision.sh"])
        #expect(f.log.lines.contains { Redactor.redact($0).contains("origin/main @ abc1234def56, branch loopworker-12-fix") })

        await f.lifecycle.recycle(slot, contract: f.contract)
        #expect(f.scriptsRun() == ["provision.sh", "teardown.sh"])
        #expect(await !f.git.calls.contains("detach 0"))
    }

    @Test("B35: a hot slot runs reset on acquire and detaches HEAD on recycle")
    func hotAcquireAndRecycle() async throws {
        let f = try Fixture()
        let slot = f.slot(hot: true)
        _ = try await f.lifecycle.acquire(slot, contract: f.contract, base: "main", branch: "b")
        #expect(f.scriptsRun() == ["reset.sh"])
        #expect(f.runner.calls[0].timeout == .seconds(15 * 60))

        await f.lifecycle.recycle(slot, contract: f.contract)
        #expect(f.scriptsRun() == ["reset.sh"])
        #expect(await f.git.calls.last == "detach 0")
    }

    @Test("B33: a failed script names itself, its exit status and the last 20 redacted lines")
    func failureCarriesTail() async throws {
        let f = try Fixture()
        let output = (1...30).map { "line \($0)" } + ["db url postgres://u:SECRET@h"]
        f.runner.on("bash") { _ in ProcessResult(status: 3, output: output.joined(separator: "\n")) }
        do {
            try await f.lifecycle.prepare(f.slot(hot: true), contract: f.contract)
            Issue.record("prepare should fail")
        } catch {
            #expect(error.description.contains("group--app/0: provision.sh exited 3"))
            #expect(error.description.contains("line 30"))
            #expect(error.description.contains("line 12"))
            #expect(!error.description.contains("line 11\n"))
            #expect(error.description.contains("[REDACTED]"))
            #expect(!error.description.contains("SECRET"))
            #expect(!error.engineDown)
        }
    }

    @Test("B33: a timed-out script says how long it ran")
    func timeoutDescription() async throws {
        let f = try Fixture()
        f.runner.on("bash") { _ in ProcessResult(status: -9, output: "", timedOut: true) }
        await #expect(throws: SlotFailure("group--app/0: provision.sh timed out after 45 min; last 0 lines of output:\n(no output)")) {
            try await f.lifecycle.prepare(f.slot(hot: true), contract: f.contract)
        }
    }

    @Test("B41: engine-down output marks the failure engineDown")
    func engineDownFlag() async throws {
        let f = try Fixture()
        f.runner.on("bash") { _ in
            ProcessResult(status: 1, output: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?")
        }
        do {
            _ = try await f.lifecycle.acquire(f.slot(hot: true), contract: f.contract, base: "main", branch: "b")
            Issue.record("acquire should fail")
        } catch {
            #expect(error.engineDown)
            #expect(error.description.contains("reset.sh exited 1"))
        }
    }

    @Test func missingProvisionScriptNamesThePath() async throws {
        let f = try Fixture(scripts: [])
        let path = f.contract.directory.appending(path: "provision.sh").path
        await #expect(throws: SlotFailure("group--app/0: provision script missing at \(path)")) {
            try await f.lifecycle.prepare(f.slot(hot: true), contract: f.contract)
        }
        #expect(f.runner.calls.isEmpty)
    }

    @Test("B37: a missing teardown script is skipped and the worktree is still removed")
    func missingTeardownSkipped() async throws {
        let f = try Fixture(scripts: ["provision.sh"])
        await f.lifecycle.retire(f.slot(hot: true), contract: f.contract)
        #expect(f.runner.calls.isEmpty)
        #expect(f.log.lines(.info).contains { $0.contains("no teardown script") })
        #expect(await f.git.calls == ["removeWorktree 0"])
    }

    @Test("B37: a teardown timeout is logged and the worktree is still removed")
    func teardownTimeoutBestEffort() async throws {
        let f = try Fixture()
        f.runner.on("bash") { _ in ProcessResult(status: -9, output: "", timedOut: true) }
        await f.lifecycle.retire(f.slot(hot: false), contract: f.contract)
        #expect(f.log.lines(.warning).contains { $0.contains("teardown incomplete") && $0.contains("timed out after 10 min") })
        #expect(await f.git.calls == ["removeWorktree 0"])
    }

    @Test func gitResetFailureBecomesSlotFailure() async throws {
        let f = try Fixture()
        await f.git.failReset(GitError(command: "fetch origin", result: ProcessResult(status: 128, output: "fatal: could not read from remote")))
        do {
            _ = try await f.lifecycle.acquire(f.slot(hot: true), contract: f.contract, base: "main", branch: "b")
            Issue.record("acquire should fail")
        } catch {
            #expect(error.description.contains("to origin/main on branch b failed"))
            #expect(error.description.contains("could not read from remote"))
        }
        #expect(f.runner.calls.isEmpty)
    }

    @Test func scriptThatCannotStartBecomesSlotFailure() async throws {
        struct SpawnFailed: Error {}
        let f = try Fixture()
        f.runner.on("bash") { _ in throw SpawnFailed() }
        do {
            try await f.lifecycle.prepare(f.slot(hot: true), contract: f.contract)
            Issue.record("prepare should fail")
        } catch {
            #expect(error.description.contains("couldn't start"))
            #expect(error.description.contains("provision.sh"))
        }
    }

    @Test("B32: a long script logs that it is still running, repeatedly")
    func stillRunning() async throws {
        let f = try Fixture { $0.provisionTimeout = .milliseconds(200) }
        f.runner.on("bash") { _ in
            try await Task.sleep(for: .milliseconds(500))
            return ProcessResult(status: 0, output: "")
        }
        try await f.lifecycle.prepare(f.slot(hot: true), contract: f.contract)
        let lines = f.log.lines.filter { $0.contains("[group--app/0 provision] still running after") }
        #expect(lines.count >= 2)
        let after = f.log.lines.count
        try await Task.sleep(for: .milliseconds(250))
        #expect(f.log.lines.count == after)
    }

    @Test func describesDurations() {
        #expect(ScriptedSlotLifecycle.describe(.seconds(45 * 60)) == "45 min")
        #expect(ScriptedSlotLifecycle.describe(.seconds(150)) == "2.5 min")
        #expect(ScriptedSlotLifecycle.describe(.seconds(30)) == "30 s")
        #expect(ScriptedSlotLifecycle.describe(.milliseconds(100)) == "0.1 s")
    }
}
