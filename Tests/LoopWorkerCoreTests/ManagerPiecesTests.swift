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

    @Test func lightHotProjectsStayInsideTheirBand() {  // B50
        // 0.5 weight affords 8 slots of a 4-unit budget, but the band holds 4.
        #expect(Budget.slotTargets(for: [ProjectSpec(path: "a", slots: 6, hot: true, weight: 0.5)], maxSlots: 4) == [4])
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
    @Test func secondHolderIsRefusedWithThePid() async throws {  // B109
        let dir = try temporaryDirectory()
        let file = dir.appending(path: "manager.lock")
        let log = CollectingLog()
        let lock = try ManagerLock.acquire(at: file, log: log)
        let held = #expect(throws: ManagerLock.Held.self) { try ManagerLock.acquire(at: file, log: log) }
        #expect(held?.pid == getpid())
        #expect(ManagerLock.holder(at: file) == getpid())
        lock.release()
        #expect(await lockReleased(file))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func staleLockFromADeadPidIsTakenOver() throws {
        let dir = try temporaryDirectory()
        let file = dir.appending(path: "manager.lock")
        try "999999\n".write(to: file, atomically: true, encoding: .utf8)
        let log = CollectingLog()
        let lock = try ManagerLock.acquire(at: file, log: log)
        defer { lock.release() }
        #expect(log.contains("previous Manager pid 999999 has exited", level: .info))
        #expect(try String(contentsOf: file, encoding: .utf8) == "\(getpid())\n")
    }

    @Test func aConcurrentHolderProbeDoesNotFailAStart() throws {
        let dir = try temporaryDirectory()
        let file = dir.appending(path: "manager.lock")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let probe = open(file.path, O_RDONLY | O_CLOEXEC)  // parallel tests fork; an inherited fd would keep the lock
        #expect(flock(probe, LOCK_SH | LOCK_NB) == 0)  // what holder(at:) holds while it reads
        #expect(ManagerLock.holder(at: file) == nil)  // two probes don't collide
        // A plain thread, not GCD: on a loaded CI runner the global queue can miss the window.
        Thread { usleep(200_000); close(probe) }.start()
        try ManagerLock.acquire(at: file, log: CollectingLog(), attempts: 200).release()
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
        do { let r = g.record(.ok, at: t0); #expect(r == nil) }
        #expect(g.allowsDispatch(at: t0))
        #expect(!g.needsCheck(at: t0 + 179))
        #expect(g.needsCheck(at: t0 + 180))
        do { let r = g.record(.failed("401"), at: t0); #expect(r == .failed("401")) }
        do { let r = g.record(.failed("401"), at: t0); #expect(r == nil) }
        #expect(g.detail == "failed (2 in a row): 401; next check in 180 s")
        #expect(!g.allowsDispatch(at: t0))
        do { let r = g.record(.ok, at: t0); #expect(r == .recovered) }
        #expect(g.detail == nil)
    }

    @Test func inconclusiveKeepsTheHealthAndRechecksSooner() {  // B176
        var g = AuthGate()
        _ = g.record(.ok, at: t0)
        do { let r = g.record(.inconclusive("claude -p timed out after 120 s"), at: t0); #expect(r == nil) }
        #expect(g.health == .ok)
        #expect(g.allowsDispatch(at: t0))
        #expect(g.detail == "inconclusive (1 in a row): claude -p timed out after 120 s; next check in 30 s")
        #expect(!g.needsCheck(at: t0 + 29))
        #expect(g.needsCheck(at: t0 + 30))
        do { let r = g.record(.ok, at: t0 + 30); #expect(r == nil) }
        #expect(g.detail == nil)
        #expect(!g.needsCheck(at: t0 + 209))
    }

    @Test func threeInconclusiveInARowCountAsFailing() {  // B176
        var g = AuthGate()
        _ = g.record(.ok, at: t0)
        do { let r = g.record(.inconclusive("killed"), at: t0); #expect(r == nil) }
        do { let r = g.record(.inconclusive("killed"), at: t0); #expect(r == nil) }
        #expect(g.health == .ok)
        do { let r = g.record(.inconclusive("killed"), at: t0); #expect(r == .failed("killed, 3 checks in a row")) }
        #expect(g.health == .failing)
        do { let r = g.record(.inconclusive("killed"), at: t0); #expect(r == nil) }
        #expect(g.detail == "inconclusive (4 in a row): killed; next check in 30 s")
        do { let r = g.record(.ok, at: t0); #expect(r == .recovered) }
    }

    @Test func inconclusiveBeforeTheFirstOkKeepsClaimsOff() {  // B176
        var g = AuthGate()
        _ = g.record(.inconclusive("killed"), at: t0)
        #expect(g.health == .unknown)
        #expect(!g.allowsDispatch(at: t0))
    }

    @Test func authReleaseBackoffIsExponentialAndCapped() {  // B98
        var g = AuthGate()
        _ = g.record(.ok, at: t0)
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
        #expect(r == .failed("Invalid API key"))
        let spec = runner.specs.get[0]
        #expect(spec.executable == "claude")
        #expect(spec.arguments == ["-p", "ok", "--model", "haiku"])
        #expect(spec.environment["USER"] == .some(nil))
        #expect(spec.environment["CLAUDE_CODE_OAUTH_TOKEN"] == "fabricated")
        #expect(spec.timeout == .seconds(120))
    }

    @Test func preflightLoginPromptIsAFailureDespiteExitZero() async {  // B95
        let runner = ScriptedRunner { _ in ProcessResult(status: 0, output: "Not logged in \u{00B7} Please run /login\n") }
        let r = await AuthGate.preflight(runner: runner, environment: [:])
        guard case .failed(let why) = r else { Issue.record("not failed: \(r)"); return }
        #expect(why.contains("Not logged in"))
    }

    @Test func preflightTimeoutOrSignalIsInconclusive() async {  // B176
        let timedOut = ScriptedRunner { _ in ProcessResult(status: -9, output: "", timedOut: true) }
        #expect(await AuthGate.preflight(runner: timedOut, environment: [:]) == .inconclusive("claude -p timed out after 120 s"))
        let killed = ScriptedRunner { _ in ProcessResult(status: -15, output: "") }
        #expect(await AuthGate.preflight(runner: killed, environment: [:]) == .inconclusive("claude -p was killed by signal 15"))
    }

    @Test("B183: a kill by a signal while claude is quarantined fails with the xattr remedy")
    func preflightKilledWhileQuarantinedFails() async throws {
        let dir = try temporaryDirectory()
        let claude = dir.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let killed = ScriptedRunner { _ in ProcessResult(status: -9, output: "") }
        let env = ["PATH": dir.path]
        let r = await AuthGate.preflight(runner: killed, environment: env, isQuarantined: { $0.lastPathComponent == "claude" })
        let path = claude.resolvingSymlinksInPath().path
        #expect(r == .failed("claude -p was killed by signal 9, and \(path) carries com.apple.quarantine: \(Quarantine.why); run `xattr -d com.apple.quarantine \(path)`"))
        #expect(await AuthGate.preflight(runner: killed, environment: env, isQuarantined: { _ in false }) == .inconclusive("claude -p was killed by signal 9"))
        let timedOut = ScriptedRunner { _ in ProcessResult(status: -9, output: "", timedOut: true) }
        #expect(await AuthGate.preflight(runner: timedOut, environment: env, isQuarantined: { _ in true }) == .inconclusive("claude -p timed out after 120 s"))
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

@Suite struct StatusReportTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func status(updated: Date) -> ManagerStatus {
        ManagerStatus(
            pid: 7, host: "box", started: updated.addingTimeInterval(-3700), updated: updated, paused: true, draining: false,
            auth: .init(state: "failing", detail: "Invalid API key"),
            projects: [.init(path: "g/app", key: "g--app", hot: false, ready: true, error: nil, paused: false, removing: false,
                             slots: [.init(index: 0, state: "busy", task: "finishing", card: "g/app#12", branch: "loopworker-12-x",
                                           runningFor: 125, lastError: "finish failed: 502", port: 54400,
                                           pane: ["a", "thinking"], finishFailing: true)])],
            log: ["INFO hello"])
    }

    @Test func runningManagerIsSummarized() {  // B149
        let r = StatusReport.render(status(updated: now.addingTimeInterval(-5)), lockHolder: 7, now: now)
        #expect(r.running)
        #expect(r.text == """
            LoopWorker \(loopworkerVersion) on box, pid 7, up 1h 01m, PAUSED
            auth: failing (Invalid API key)
            g/app (cold)
              slot 0: busy g/app#12 on loopworker-12-x for 2m, finishing, FINISH FAILING
                last error: finish failed: 502
                > thinking
            recent log:
              INFO hello

            """)
    }

    @Test func noLockHolderMeansNotRunning() {
        let r = StatusReport.render(status(updated: now), lockHolder: nil, now: now)
        #expect(!r.running)
        #expect(r.text.hasPrefix("The Manager is not running.\nIts last status, from "))
        #expect(StatusReport.render(nil, lockHolder: nil, now: now).text == "The Manager is not running.\n")
    }

    @Test func staleStatusWhileLockedIsWedged() {
        let r = StatusReport.render(status(updated: now.addingTimeInterval(-61)), lockHolder: 7, now: now)
        #expect(!r.running)
        #expect(r.text.hasPrefix("The Manager (pid 7) looks wedged"))
    }
}

@Suite struct SecretsOverlayTests {
    @Test func secretsOverrideTheProcessEnvironment() throws {
        let dir = try temporaryDirectory()
        let file = dir.appending(path: "secrets.env")
        try "CLAUDE_CODE_OAUTH_TOKEN=from-file\nLOOPWORKER_GITLAB_TOKEN=glpat-fabricated\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let merged = try Secrets.overlay(["PATH": "/bin", "CLAUDE_CODE_OAUTH_TOKEN": "from-env"], with: file)
        #expect(merged == ["PATH": "/bin", "CLAUDE_CODE_OAUTH_TOKEN": "from-file", "LOOPWORKER_GITLAB_TOKEN": "glpat-fabricated"])
    }
}

@Suite struct AttachmentsTests {
    let root: URL
    let outside: URL

    init() throws {
        let dir = try temporaryDirectory()
        root = dir.appending(path: "slot")
        outside = dir.appending(path: "elsewhere")
        for d in [root, outside, root.appending(path: "out"), root.appending(path: ".git"), root.appending(path: "sub/.ssh")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    func write(_ path: String, _ text: String, in dir: URL? = nil) throws {
        try Data(text.utf8).write(to: (dir ?? root).appending(path: path))
    }

    func reason(_ path: String) -> String? {
        if case .failure(let r) = Attachments.check(path, in: root) { return r.reason }
        return nil
    }

    @Test("B185: each referenced file is uploaded once and its reference becomes the URL")
    func resolvesReferences() async throws {
        try write("after.png", "png bytes")
        try write("out/log.txt", "built 3f786850e387550fdab836ed7e6dc881de23001b\n")  // a SHA isn't a secret
        let uploads = Guarded<[String]>([])
        let body = "| Before | After |\n| --- | --- |\n| x | ![after](attachment:after.png) |\n\n[log](attachment:out/log.txt) [again](attachment:after.png) [web](https://x.example)"
        let (out, refused) = try await Attachments.resolve(body, in: root) { file in
            uploads { $0.append(file.lastPathComponent) }
            return URL(string: "https://forge.example/uploads/\(file.lastPathComponent)")
        }
        #expect(refused.isEmpty)
        #expect(uploads.get == ["after.png", "log.txt"])
        #expect(out == "| Before | After |\n| --- | --- |\n| x | ![after](https://forge.example/uploads/after.png) |\n\n[log](https://forge.example/uploads/log.txt) [again](https://forge.example/uploads/after.png) [web](https://x.example)")
    }

    @Test("B185: every refusal names its reason")
    func refusals() throws {
        try write("secret.txt", "x", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link.txt"), withDestinationURL: outside.appending(path: "secret.txt"))
        try write(".env.local", "A=1")
        try FileManager.default.createSymbolicLink(at: root.appending(path: "innocent.txt"), withDestinationURL: root.appending(path: ".env.local"))
        try write("empty.txt", "")
        try write("key.txt", "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n")
        try write("token.txt", "token: glpat-abcdefghijklmnopqrst\n")
        try Data([0xFF, 0xFE, 0x00] + Array("ghp_abcdefghijklmnop".utf8)).write(to: root.appending(path: "blob.bin"))
        let big = root.appending(path: "big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(Attachments.maxBytes))
        try handle.close()

        #expect(reason("../elsewhere/secret.txt")?.contains("outside") == true)
        #expect(reason(outside.appending(path: "secret.txt").path)?.contains("outside") == true)
        #expect(reason("link.txt")?.contains("outside") == true)
        for name in [".env", ".env.local", "server.pem", "tls.key", "cert.p12", "id_rsa.pub", "id_ed25519", ".git/config", "sub/.ssh/known_hosts", ".claude/settings.json"] {
            #expect(reason(name) == "its name looks like a credential file", "\(name)")
        }
        #expect(reason("innocent.txt")?.contains("whose name looks like a credential file") == true)
        #expect(reason("missing.png")?.hasSuffix("doesn't exist") == true)
        #expect(reason("out")?.hasSuffix("isn't a regular file") == true)
        #expect(reason("empty.txt")?.hasSuffix("is empty") == true)
        #expect(reason("big.bin")?.contains("the limit is 20971520") == true)
        #expect(reason("key.txt") == "it contains a PEM private key")
        #expect(reason("token.txt") == "its content looks like it holds a token or password")
        #expect(reason("blob.bin") == "its content looks like it holds a token or password")
    }

    @Test("B185: a forge without attachments, or one that refuses, leaves the reference; other errors throw")
    func forgeOutcomes() async throws {
        try write("a.png", "png")
        let body = "![a](attachment:a.png)"
        let none = try await Attachments.resolve(body, in: root) { _ in nil }
        #expect(none.body == body)
        #expect(none.refused == [Attachments.Refusal(path: "a.png", reason: "this forge has no attachments")])
        let rejected = try await Attachments.resolve(body, in: root) { _ in throw BackendRejection("413 too large") }
        #expect(rejected.refused == [Attachments.Refusal(path: "a.png", reason: "the forge refused it: 413 too large")])
        await #expect(throws: FakeError("timeout")) { _ = try await Attachments.resolve(body, in: root) { _ in throw FakeError("timeout") } }
    }
}
