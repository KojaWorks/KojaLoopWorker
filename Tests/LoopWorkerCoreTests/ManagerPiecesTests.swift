import Foundation
import Testing
@testable import LoopWorkerCore

func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "lw-test-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct BudgetTests {
    @Test func affordableToleratesFractionalWeights() {  // B47
        #expect(Budget.affordable(remaining: 0.3, weight: 0.1) == 3)
        #expect(Budget.affordable(remaining: 3, weight: 2) == 1)
        #expect(Budget.affordable(remaining: -1, weight: 1) == 0)
    }

    @Test func hotReservesInConfigOrderAndColdIsCappedAtTheBand() {  // B48, B49
        let projects = [
            ProjectSpec(path: "a", slots: 2, hot: true, weight: 1.5),
            ProjectSpec(path: "b", slots: 3, hot: true, weight: 1),
            ProjectSpec(path: "c", slots: 9, hot: false),
        ]
        #expect(Budget.slotTargets(for: projects, maxSlots: 4) == [2, 1, 4])
    }

    @Test func portBandsDoNotOverlap() {  // B50
        #expect(Budget.port(basePort: 54400, portStep: 100, bandSize: Budget.bandSize(maxSlots: 2.5), band: 0, index: 2) == 54600)
        #expect(Budget.port(basePort: 54400, portStep: 100, bandSize: Budget.bandSize(maxSlots: 2.5), band: 1, index: 0) == 54700)
        #expect(Budget.freeBand(used: [0, 2]) == 1)
    }
}

@Suite struct BranchNameTests {
    func card(_ display: String, number: String? = nil, title: String = "Fix the Login, now!") -> Card {
        Card(ref: CardRef(id: "gid://42", display: display), project: "g/app", number: number, title: title, state: .ready)
    }

    @Test func defaultTemplateUsesNumberAndSlug() {  // B25
        #expect(BranchName.make(template: ProjectContract.defaultBranchTemplate, card: card("g/app#12"))
                == "loopworker-12-fix-the-login-now")
    }

    @Test func numberComesFromTheCardThenTheDisplayThenAHash() {
        #expect(BranchName.number(for: card("x", number: "77")) == "77")
        #expect(BranchName.number(for: card("~802")) == "802")
        #expect(BranchName.number(for: card("no number")) == String(SHA256.hex(Array("gid://42".utf8)).prefix(8)))
    }

    @Test func slugIsAsciiWordsAtMostFortyCharacters() {
        #expect(BranchName.slug("Ärger über   Ümlaute & Co") == "rger-ber-mlaute-co")
        let long = BranchName.slug("one two three four five six seven eight nine ten")
        #expect(long == "one-two-three-four-five-six-seven-eight")
        #expect(long.count <= 40)
        #expect(BranchName.slug("!!!") == "card")
    }

    @Test func sha256MatchesTheStandardVector() {
        #expect(SHA256.hex(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256.hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}

@Suite struct SecretsTests {
    @Test func parsesNameValueLinesLiterally() throws {
        let dir = try temporaryDirectory()
        let file = dir.appending(path: "secrets.env")
        try "# tokens\n\nA_TOKEN=abc$HOME\nB = 'quoted value'\nC=\"x=y\"\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Secrets.load(file) == ["A_TOKEN": "abc$HOME", "B": "quoted value", "C": "x=y"])
    }

    @Test func refusesAFileOthersCanRead() throws {
        let dir = try temporaryDirectory()
        let file = dir.appending(path: "secrets.env")
        try "A=b\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let error = #expect(throws: ConfigError.self) { try Secrets.load(file) }
        #expect(error?.description.contains("mode 644") == true)
        #expect(error?.description.contains(file.path) == true)
    }

    @Test func malformedLineNamesTheLineNotTheContent() throws {
        let dir = try temporaryDirectory()
        let file = dir.appending(path: "secrets.env")
        try "A=b\nglpat-secretvalue\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let error = #expect(throws: ConfigError.self) { try Secrets.load(file) }
        #expect(error?.description.contains("line 2") == true)
        #expect(error?.description.contains("glpat") == false)
    }

    @Test func missingFileIsEmpty() throws {
        #expect(try Secrets.load(URL(filePath: "/nonexistent/secrets.env")) == [:])
    }
}

@Suite struct ManagerLockTests {
    @Test func secondHolderIsRefusedWithThePid() throws {  // B109
        let dir = try temporaryDirectory()
        let file = dir.appending(path: "manager.lock")
        let log = CollectingLog()
        let lock = try ManagerLock.acquire(at: file, log: log)
        let held = #expect(throws: ManagerLock.Held.self) { try ManagerLock.acquire(at: file, log: log) }
        #expect(held?.pid == getpid())
        #expect(ManagerLock.holder(at: file) == getpid())
        lock.release()
        #expect(ManagerLock.holder(at: file) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func staleLockFromADeadPidIsTakenOver() throws {
        let dir = try temporaryDirectory()
        let file = dir.appending(path: "manager.lock")
        try "999999\n".write(to: file, atomically: true, encoding: .utf8)
        let log = CollectingLog()
        let lock = try ManagerLock.acquire(at: file, log: log)
        defer { lock.release() }
        #expect(log.contains("from pid 999999", level: .warning))
        #expect(try String(contentsOf: file, encoding: .utf8) == "\(getpid())\n")
    }

    @Test func corruptLockFileDoesNotBlock() throws {
        let dir = try temporaryDirectory()
        let file = dir.appending(path: "manager.lock")
        try "garbage".write(to: file, atomically: true, encoding: .utf8)
        try ManagerLock.acquire(at: file, log: CollectingLog()).release()
    }
}

@Suite struct ManagerStatusTests {
    @Test func roundTripsThroughTheFile() throws {  // B110
        let dir = try temporaryDirectory()
        let file = ManagerStatus.file(stateDir: dir)
        let status = ManagerStatus(
            pid: 42, host: "box", started: Date(timeIntervalSince1970: 1_700_000_000),
            updated: Date(timeIntervalSince1970: 1_700_000_015), paused: false, draining: true,
            auth: .init(state: "ok"),
            projects: [.init(path: "g/app", key: "g--app", hot: true, ready: true, error: nil, paused: false, removing: false,
                             slots: [.init(index: 0, state: "busy", card: "g/app#1", cardURL: URL(string: "https://x/1"),
                                           branch: "loopworker-1-x", runningFor: 12, port: 54400, pane: ["hi"])])],
            log: ["INFO started"])
        try status.write(to: file)
        #expect(try ManagerStatus.read(from: file) == status)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["status.json"])
    }
}

@Suite struct AuthGateTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func transitionsAreReportedOnce() {  // B96
        var g = AuthGate()
        #expect(!g.allowsDispatch(at: t0))
        #expect(g.needsCheck(at: t0))
        do { let r = g.record(ok: true, detail: "", at: t0); #expect(r == nil) }
        #expect(g.allowsDispatch(at: t0))
        #expect(!g.needsCheck(at: t0 + 179))
        #expect(g.needsCheck(at: t0 + 180))
        do { let r = g.record(ok: false, detail: "401", at: t0); #expect(r == .failed("401")) }
        do { let r = g.record(ok: false, detail: "401", at: t0); #expect(r == nil) }
        #expect(!g.allowsDispatch(at: t0))
        do { let r = g.record(ok: true, detail: "", at: t0); #expect(r == .recovered) }
    }

    @Test func authReleaseBackoffIsExponentialAndCapped() {  // B98
        var g = AuthGate()
        _ = g.record(ok: true, detail: "", at: t0)
        do { let r = g.noteAuthRelease(at: t0); #expect(r == 30) }
        #expect(!g.allowsDispatch(at: t0 + 29))
        #expect(g.allowsDispatch(at: t0 + 30))
        do { let r = g.noteAuthRelease(at: t0); #expect(r == 60) }
        for _ in 0..<6 { _ = g.noteAuthRelease(at: t0) }
        do { let r = g.noteAuthRelease(at: t0); #expect(r == 600) }
        do { let r = g.noteCleanFinish(); #expect(r) }
        #expect(g.allowsDispatch(at: t0))
        do { let r = g.noteCleanFinish(); #expect(!r) }
    }

    @Test func preflightStripsUserAndPassesTheToken() async {  // B95
        let runner = ScriptedRunner { _ in ProcessResult(status: 1, output: "warming up\nInvalid API key\n") }
        let r = await AuthGate.preflight(runner: runner, environment: ["CLAUDE_CODE_OAUTH_TOKEN": "fabricated"])
        #expect(r.ok == false)
        #expect(r.detail == "Invalid API key")
        let spec = runner.specs.get[0]
        #expect(spec.executable == "claude")
        #expect(spec.arguments == ["-p", "ok", "--model", "haiku"])
        #expect(spec.environment["USER"] == .some(nil))
        #expect(spec.environment["CLAUDE_CODE_OAUTH_TOKEN"] == "fabricated")
        #expect(spec.timeout == .seconds(60))
    }

    @Test func preflightTimeoutIsAFailure() async {
        let runner = ScriptedRunner { _ in ProcessResult(status: -9, output: "", timedOut: true) }
        let r = await AuthGate.preflight(runner: runner, environment: [:])
        #expect(!r.ok)
        #expect(r.detail.contains("timed out"))
    }
}

@Suite struct NotifierTests {
    @Test func sendsTheMessageOnStdinAndDedupesPerKey() async throws {  // B99, B100
        let dir = try temporaryDirectory()
        let out = dir.appending(path: "alerts")
        let clock = Guarded(Date(timeIntervalSince1970: 0))
        let n = Notifier(command: "cat >> \(WorkerLaunch.shellQuote(out.path)); echo >> \(WorkerLaunch.shellQuote(out.path))",
                         runner: ShellRunner(), log: CollectingLog(), now: { clock.get })
        await n.send(key: "a", "first")
        await n.send(key: "a", "deduped")
        await n.send(key: "b", "other key")
        clock { $0 += 301 }
        await n.send(key: "a", "after window")
        #expect(try String(contentsOf: out, encoding: .utf8) == "first\nother key\nafter window\n")
    }

    @Test func emptyCommandDoesNothing() async {
        let runner = ScriptedRunner()
        await Notifier(command: "", runner: runner, log: CollectingLog()).send(key: "a", "x")
        #expect(runner.specs.get.isEmpty)
    }

    @Test func failuresAndRejectionsAreLogged() async {  // B101
        let log = CollectingLog()
        let failing = ScriptedRunner { _ in ProcessResult(status: 7, output: "curl: (7) refused") }
        await Notifier(command: "x", runner: failing, log: log).send(key: "k", "m")
        #expect(log.contains("exited 7", level: .error))
        let rejected = ScriptedRunner { _ in ProcessResult(status: 0, output: #"{"status":0,"errors":["bad token"]}"#) }
        await Notifier(command: "x", runner: rejected, log: log).send(key: "k", "m")
        #expect(log.contains("rejected", level: .error))
        let ok = ScriptedRunner { _ in ProcessResult(status: 0, output: #"{"status":1}"#) }
        let quiet = CollectingLog()
        await Notifier(command: "x", runner: ok, log: quiet).send(key: "k", "m")
        #expect(quiet.messages.isEmpty)
    }
}

@Suite struct WorkerLaunchTests {
    @Test func scriptQuotesEveryValue() {  // B81, B82
        let s = WorkerLaunch.script(worktree: URL(filePath: "/w/it's"), stateDir: URL(filePath: "/s/0"), port: 54400,
                                    model: "opus'; rm -x")
        #expect(s.contains(#"cd '/w/it'\''s'"#))
        #expect(s.contains(#"--model 'opus'\''; rm -x'"#))
        #expect(s.contains("unset USER"))
        #expect(s.contains("LOOPWORKER=1"))
        #expect(!WorkerLaunch.script(worktree: URL(filePath: "/w"), stateDir: URL(filePath: "/s"), port: 1, model: nil)
            .contains("--model"))
    }
}
