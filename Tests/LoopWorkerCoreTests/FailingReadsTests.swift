import Foundation
import Testing
@testable import LoopWorkerCore

@Suite struct FailingReadsTests {
    static let failing = "backlog reads failing since "
    static let recovered = "backlog reads recovered"
    static let twoProjects = oneColdProject + "\n[[project]]\npath = \"g/lib\"\nslots = 1"

    func alerts(_ h: ManagerHarness, _ fragment: String) -> [String] {
        h.runner.specs.get.compactMap { $0.environment["LOOPWORKER_ALERT"] ?? nil }.filter { $0.contains(fragment) }
    }

    /// Boots, then runs the first fill at the boot time, so the first failure is at minute 0.
    func bootAndFill(_ h: ManagerHarness) async throws {
        try await h.boot()
        await h.cycle()
    }

    /// Advances the clock a minute at a time, one tick per minute.
    func minutes(_ h: ManagerHarness, _ n: Int) async {
        for _ in 0..<n {
            h.clock.advance(60)
            await h.cycle()
        }
    }

    func pause(_ h: ManagerHarness, _ key: String) throws -> URL {
        let file = KillSwitch.file(stateDir: h.home.appending(path: "state"), projectKey: key)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        return file
    }

    @Test("B249: a read failing for 10 minutes alerts once with its error and points at doctor; its recovery alerts once with the duration")
    func persistentFailureAlertsOnceThenRecovers() async throws {
        let h = try ManagerHarness(projects: oneColdProject, top: "notify_command = \"x\"")
        h.backlog.state { $0.failWorkable = true }
        try await bootAndFill(h)
        await minutes(h, 9)
        #expect(alerts(h, Self.failing).isEmpty)
        await minutes(h, 1)
        let alert = try #require(alerts(h, Self.failing).only)
        #expect(alert.hasSuffix("(10m): workable for g/app: workable failed. Run `loopworker doctor` to see which project's query fails."))
        await minutes(h, 20)
        #expect(alerts(h, Self.failing).count == 1)

        h.backlog.state { $0.failWorkable = false }
        await minutes(h, 1)
        #expect(alerts(h, "\(Self.recovered) after failing for 31m: workable for g/app").count == 1)
        await minutes(h, 10)
        #expect(alerts(h, Self.recovered).count == 1)
    }

    @Test("B249: a read that recovers before 10 minutes alerts nothing")
    func shortFailureIsSilent() async throws {
        let h = try ManagerHarness(projects: oneColdProject, top: "notify_command = \"x\"")
        h.backlog.state { $0.failWorkable = true }
        try await bootAndFill(h)
        await minutes(h, 5)
        h.backlog.state { $0.failWorkable = false }
        await minutes(h, 1)
        h.backlog.state { $0.failWorkable = true }
        await minutes(h, 9)
        #expect(alerts(h, "backlog reads").isEmpty)
    }

    @Test("B249: a failure long after the previous one starts a new run instead of alerting at once")
    func staleFailureStartsANewRun() async throws {
        let h = try ManagerHarness(projects: oneColdProject, top: "notify_command = \"x\"")
        h.backlog.state { $0.failWorkable = true }
        try await bootAndFill(h)
        let paused = try pause(h, "g--app")
        await minutes(h, 120)
        try FileManager.default.removeItem(at: paused)
        await minutes(h, 1)
        let restart = h.clock.now()
        let since = try #require(try h.status().failingReads?.only?.since)
        #expect(abs(since.timeIntervalSince(restart)) < 1)
        await minutes(h, 9)
        #expect(alerts(h, "backlog reads").isEmpty)
        await minutes(h, 1)
        #expect(alerts(h, Self.failing).only?.contains("(10m)") == true)
    }

    @Test("B249: reads failing with different errors alert and recover separately")
    func differentErrorsAlertSeparately() async throws {
        let h = try ManagerHarness(projects: oneColdProject, top: "notify_command = \"x\"")
        h.backlog.state {
            $0.failWorkable = true
            $0.failWorking = true
        }
        try await bootAndFill(h)
        await minutes(h, 10)
        #expect(alerts(h, "workable for g/app: workable failed").count == 1)
        #expect(alerts(h, "working for g/app: working failed").count == 1)

        h.backlog.state { $0.failWorkable = false }
        await minutes(h, 5)
        #expect(alerts(h, Self.recovered).map { $0.hasSuffix("workable for g/app") } == [true])
    }

    @Test("B249: one error across reads and projects alerts once, and recovers once when all of them recovered")
    func oneErrorAlertsOnce() async throws {
        let h = try ManagerHarness(projects: Self.twoProjects, top: "notify_command = \"x\"")
        let paused = try pause(h, "g--lib")
        h.backlog.state {
            $0.failWorkable = true
            $0.failWorking = true
            $0.failVerifying = true
            $0.workableError = "GET /issues: 400 bad scope"
            $0.workingError = "GET /issues: 400 bad scope"
            $0.verifyingError = "GET /issues: 400 bad scope"
        }
        try await bootAndFill(h)
        await minutes(h, 2)
        try FileManager.default.removeItem(at: paused)  // g/lib's workable read starts failing at minute 3
        await minutes(h, 15)
        let alert = try #require(alerts(h, Self.failing).only)
        #expect(alert.contains("(10m): verifying for g/app, g/lib; workable for g/app, g/lib; working for g/app, g/lib: GET /issues: 400 bad scope"))

        h.backlog.state { $0.failWorkable = false }
        await minutes(h, 10)
        #expect(alerts(h, Self.recovered).isEmpty)
        h.backlog.state {
            $0.failWorking = false
            $0.failVerifying = false
        }
        await minutes(h, 5)
        #expect(alerts(h, Self.recovered).only?.hasSuffix(": verifying for g/app, g/lib; workable for g/app, g/lib; working for g/app, g/lib") == true)
        #expect(alerts(h, Self.failing).count == 1)
    }

    @Test("B249: a restarted Manager alerts again after its own 10 minutes")
    func restartStartsFresh() async throws {
        let h = try ManagerHarness(projects: oneColdProject, top: "notify_command = \"x\"")
        h.backlog.state { $0.failWorkable = true }
        try await bootAndFill(h)
        await minutes(h, 10)
        try h.restart()
        try await bootAndFill(h)
        await minutes(h, 9)
        #expect(alerts(h, Self.failing).count == 1)
        await minutes(h, 1)
        #expect(alerts(h, Self.failing).count == 2)
    }

    @Test("B250: status.json lists a failing read, redacted, and clears it on success")
    func statusShowsAndClearsTheFailure() async throws {
        let h = try ManagerHarness(projects: oneColdProject)
        h.backlog.state {
            $0.failWorkable = true
            $0.workableError = "400 token SECRET rejected"
        }
        try await bootAndFill(h)
        let start = h.clock.now()
        await minutes(h, 2)
        let failing = try #require(try h.status().failingReads?.only)
        #expect(failing.read == "workable" && failing.project == "g/app" && failing.error == "400 token [REDACTED] rejected")
        #expect(abs(failing.since.timeIntervalSince(start)) < 1)  // status.json keeps whole seconds

        h.backlog.state { $0.failWorkable = false }
        await minutes(h, 1)
        #expect(try h.status().failingReads == [])
    }

    @Test("B249: a success for one project doesn't clear another's failure; pruning closes the alert")
    func successClearsOnlyItsProjects() {
        var reads = FailingReads()
        let t0 = Date()
        _ = reads.failed(.workable, projects: ["a", "b"], error: "400", at: t0)
        #expect(reads.succeeded(.workable, projects: ["b"]).isEmpty)
        let alert = reads.failed(.workable, projects: ["a"], error: "400", at: t0 + 600)
        #expect(alert?.keys == [.init(read: .workable, project: "a")] && alert?.since == t0)
        let pruned = reads.prune(keeping: ["b"])
        #expect(pruned.gone == ["a"] && pruned.closed.map(\.error) == ["400"] && reads.failing.isEmpty && reads.alerts.isEmpty)
    }
}

extension Array {
    /// The one element, or nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
