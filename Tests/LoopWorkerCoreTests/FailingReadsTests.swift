import Foundation
import Testing
@testable import LoopWorkerCore

@Suite struct FailingReadsTests {
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

    @Test("B249: a read failing for 10 minutes alerts once with its error; its recovery alerts once with the duration")
    func persistentFailureAlertsOnceThenRecovers() async throws {
        let h = try ManagerHarness(projects: oneColdProject, top: "notify_command = \"x\"")
        h.backlog.state { $0.failWorkable = true }
        try await bootAndFill(h)
        await minutes(h, 9)
        #expect(alerts(h, "can't read workable cards").isEmpty)
        await minutes(h, 1)
        let alert = try #require(alerts(h, "can't read workable cards").only)
        #expect(alert.contains("for g/app since ") && alert.contains("(10m): workable failed"))
        await minutes(h, 20)
        #expect(alerts(h, "can't read workable cards").count == 1)

        h.backlog.state { $0.failWorkable = false }
        await minutes(h, 1)
        #expect(alerts(h, "reading workable cards for g/app recovered after failing for 31m").count == 1)
        await minutes(h, 10)
        #expect(alerts(h, "recovered").count == 1)
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
        #expect(alerts(h, "workable").isEmpty)
    }

    @Test("B249: each read is tracked separately")
    func readsAreTrackedSeparately() async throws {
        let h = try ManagerHarness(projects: oneColdProject, top: "notify_command = \"x\"")
        h.backlog.state {
            $0.failWorkable = true
            $0.failWorking = true
        }
        try await bootAndFill(h)
        await minutes(h, 10)
        #expect(alerts(h, "can't read workable cards").count == 1)
        #expect(alerts(h, "can't read working cards for g/app").first?.contains("working failed") == true)

        h.backlog.state { $0.failWorkable = false }
        await minutes(h, 5)
        #expect(alerts(h, "reading workable cards").count == 1)
        #expect(alerts(h, "reading working cards").isEmpty)
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
        #expect(alerts(h, "can't read workable cards").count == 1)
        await minutes(h, 1)
        #expect(alerts(h, "can't read workable cards").count == 2)
    }

    @Test("B249: a success for one project doesn't clear another's failure")
    func successClearsOnlyItsProjects() {
        var reads = FailingReads()
        let t0 = Date()
        _ = reads.failed(.workable, projects: ["a", "b"], error: "400", at: t0)
        #expect(reads.succeeded(.workable, projects: ["b"]).isEmpty)
        let due = reads.failed(.workable, projects: ["a"], error: "400 again", at: t0 + 600)
        #expect(due.keys.map(\.project) == ["a"] && due.values.first?.since == t0 && due.values.first?.error == "400 again")
        #expect(reads.prune(keeping: ["b"]) == ["a"] && reads.failing.isEmpty)
    }
}

extension Array {
    /// The one element, or nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
