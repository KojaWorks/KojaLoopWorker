import Foundation
import Testing
@testable import LoopWorkerCore

/// A clock that only moves when a test (or the recovery's sleep) advances it.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

private final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    func append(_ s: String) { lock.withLock { sent.append(s) } }
    var all: [String] { lock.withLock { sent } }
}

private struct Fixture {
    let runner = FakeProcessRunner()
    let log = SlotTestLog()
    let clock = TestClock()
    let notes = Notes()
    let engine: EngineRecovery

    init(recover: Bool = true) {
        let clock = clock, notes = notes
        engine = EngineRecovery(
            config: .init(recover: recover, startCommand: "orb start", probeCommand: "docker ps"),
            runner: runner, log: log, notify: { notes.append($0) },
            clock: { clock.now }, sleep: { clock.advance(Double($0.components.seconds)) })
    }

    /// The probe succeeds from its `upFrom`th run on (nil: never); `start` handles the start command.
    func script(probeUpFrom upFrom: Int?, start: @escaping @Sendable () async throws -> ProcessResult = { ProcessResult(status: 0, output: "") }) {
        let probes = Counter()
        runner.on("sh") { spec in
            if spec.arguments == ["-c", "orb start"] { return try await start() }
            #expect(spec.arguments == ["-c", "docker ps"])
            #expect(spec.timeout == .seconds(15))
            let n = probes.next()
            return ProcessResult(status: upFrom.map { n >= $0 } == true ? 0 : 1, output: "")
        }
    }

    var starts: Int { runner.calls.filter { $0.arguments == ["-c", "orb start"] }.count }
    var probes: Int { runner.calls.filter { $0.arguments == ["-c", "docker ps"] }.count }
}

@Suite struct EngineRecoveryTests {
    @Test("B41: daemon-unreachable output reads as engine down; ordinary failures don't")
    func looksLikeEngineDown() {
        for line in [
            "Cannot connect to the Docker daemon at unix:///Users/x/.orbstack/run/docker.sock. Is the docker daemon running?",
            "failed to inspect container health: Is the docker daemon running?",
            "error during connect: Get \"http://%2F%2F.%2Fpipe%2Fdocker_engine/v1.24/containers/json\": open //./pipe/docker_engine: This error may indicate that the docker daemon is not running.",
            "dial unix /var/run/docker.sock: connect: no such file or directory",
            "OrbStack is not running",
            "Cannot connect to Podman. Please verify your connection to the Linux system",
        ] {
            #expect(EngineRecovery.looksLikeEngineDown(line), "\(line)")
        }
        for line in ["npm ERR! code ELIFECYCLE", "error: migration 0042 failed", "docker: invalid reference format", ""] {
            #expect(!EngineRecovery.looksLikeEngineDown(line), "\(line)")
        }
    }

    @Test("B45: engine.recover = false disables recovery")
    func disabled() async {
        let f = Fixture(recover: false)
        #expect(await f.engine.recover() == false)
        #expect(f.runner.calls.isEmpty)
    }

    @Test("B43: an engine that already answers needs no start")
    func alreadyUp() async {
        let f = Fixture()
        f.script(probeUpFrom: 1)
        #expect(await f.engine.recover())
        #expect(f.starts == 0)
        #expect(f.notes.all.isEmpty)
    }

    @Test("B43: starts the engine, then probes every 5 s until it answers")
    func startThenProbe() async {
        let f = Fixture()
        f.script(probeUpFrom: 4)
        let t0 = f.clock.now
        #expect(await f.engine.recover())
        #expect(f.starts == 1)
        #expect(f.probes == 4)
        #expect(f.clock.now.timeIntervalSince(t0) == 10)
        let start = f.runner.calls.first { $0.arguments == ["-c", "orb start"] }
        #expect(start?.executable == "sh")
        #expect(start?.timeout == .seconds(60))
        #expect(f.notes.all.count == 1)
        #expect(f.notes.all[0].contains("orb start"))
    }

    @Test("B45: gives up after 90 s of failed probes and notifies")
    func givesUp() async {
        let f = Fixture()
        f.script(probeUpFrom: nil)
        let t0 = f.clock.now
        #expect(await f.engine.recover() == false)
        #expect(f.clock.now.timeIntervalSince(t0) == 90)
        #expect(f.probes == 1 + 19)
        #expect(f.notes.all.count == 2)
        #expect(f.notes.all[1].contains("still down"))
        #expect(f.log.lines(.error).contains { $0.contains("still unreachable") })
    }

    @Test("B44: the backoff starts before the start command, so a hung start still delays the next attempt")
    func backoff() async {
        let f = Fixture()
        let clock = f.clock
        f.script(probeUpFrom: nil) {
            clock.advance(60)
            return ProcessResult(status: -9, output: "", timedOut: true)
        }
        let t0 = f.clock.now
        #expect(await f.engine.recover() == false)
        #expect(f.starts == 1)

        let calls = f.runner.calls.count
        #expect(await f.engine.recover() == false)
        f.clock.advance(t0.addingTimeInterval(299).timeIntervalSince(f.clock.now))
        #expect(await f.engine.recover() == false)
        #expect(f.runner.calls.count == calls)

        f.clock.advance(1)
        #expect(await f.engine.recover() == false)
        #expect(f.starts == 2)
    }

    @Test("B44: a start command that can't launch is a failed recovery, not a crash")
    func startThrows() async {
        struct SpawnFailed: Error {}
        let f = Fixture()
        f.script(probeUpFrom: nil) { throw SpawnFailed() }
        #expect(await f.engine.recover() == false)
        #expect(f.probes == 1)
        #expect(f.notes.all.count == 2)
        #expect(f.log.lines(.error).contains { $0.contains("couldn't run") })
    }

    @Test func concurrentCallersShareOneAttempt() async {
        let f = Fixture()
        f.script(probeUpFrom: 2) {
            try await Task.sleep(for: .milliseconds(200))
            return ProcessResult(status: 0, output: "")
        }
        async let a = f.engine.recover()
        async let b = f.engine.recover()
        let results = await [a, b]
        #expect(results == [true, true])
        #expect(f.starts == 1)
    }
}
