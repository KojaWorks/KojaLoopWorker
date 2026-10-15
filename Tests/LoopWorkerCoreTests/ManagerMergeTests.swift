import Foundation
import Testing
@testable import LoopWorkerCore

@Suite struct ManagerMergeTests {
    /// Cards finished on a project with `finish`: their review requests are open and they are
    /// `verifying`. Slot n finishes card `cards[n]`.
    func finished(_ finish: String, manifest: String = "", cards: [Int] = [12]) async throws -> ManagerHarness {
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/app\"\nslots = \(cards.count)\nfinish = \"\(finish)\"",
                                   top: "max_slots = \(cards.count)", manifest: manifest)
        for n in cards { h.addCard(n) }
        try await h.boot()
        for _ in cards { await h.cycle() }
        for i in cards.indices {
            try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"Did it."}"#, index: i)
            h.tmux.set(h.session("g--app", i), alive: false)
        }
        await h.cycle()
        return h
    }

    func blocker(_ h: ManagerHarness, _ id: String = "id-12") -> String? {
        h.backlog.writes.lazy.compactMap { if case .markStuck(id, let b) = $0 { b } else { nil } }.first
    }

    func record(_ h: ManagerHarness, _ id: String = "id-12") throws -> CIWatchRecord? {
        try CIWatchRecord.read(stateDir: h.home.appending(path: "state"), cardID: id)
    }

    @Test("B203, B204: finish = merge opens a ready review request and merges at the next tick without reading CI, even with wait_for_ci")
    func mergeFinish() async throws {
        let h = try await finished("merge", manifest: ciManifest)
        #expect(h.forge.state.get.openCalls.map(\.draft) == [false])
        #expect(h.backlog.state.get.verifyingPlans["id-12"] == .merge)
        await h.cycle()
        #expect(h.forge.state.get.mergeCalls == ["\(reviewURL.absoluteString) @ commit-1"])
        #expect(h.backlog.card(id: "id-12")?.state == .reviewMerged)
        #expect(h.backlog.state.get.mergedNotes["id-12"] == "Merged into `main` as `merge-1`.")
        #expect(h.forge.state.get.pipelineCalls.isEmpty)
        #expect(try record(h) == nil)
        #expect(h.log.contains("g/app#12: merged g/app!1 into main as merge-1; moved to review_merged", level: .info))
    }

    @Test("B203: finish = ready opens a ready review request and moves the card to review")
    func readyFinish() async throws {
        let h = try await finished("ready")
        #expect(h.forge.state.get.openCalls.map(\.draft) == [false])
        #expect(h.backlog.card(id: "id-12")?.state == .review)
        #expect(h.forge.state.get.mergeCalls.isEmpty)
    }

    @Test("B205, B206: ci_then_merge merges after the pipeline passed, and the note links it")
    func ciThenMergePassed() async throws {
        let h = try await finished("ci_then_merge")
        #expect(h.backlog.state.get.verifyingPlans["id-12"] == .ciThenMerge)
        h.forge.state { $0.pipelines["commit-1"] = PipelineStatus(state: .running, url: pipelineURL) }
        h.clock.advance(121)
        await h.cycle()
        #expect(h.forge.state.get.mergeCalls.isEmpty)
        h.forge.state { $0.pipelines["commit-1"] = PipelineStatus(state: .passed, url: pipelineURL) }
        h.clock.advance(121)
        await h.cycle()
        #expect(h.backlog.card(id: "id-12")?.state == .reviewMerged)
        #expect(h.backlog.state.get.mergedNotes["id-12"] == "Merged into `main` as `merge-1`. CI passed on `commit-1`: \(pipelineURL.absoluteString)")
    }

    @Test("B205: ci_then_merge moves a pipeline that fails only like the base branch to review without merging")
    func ciThenMergePreexisting() async throws {
        let h = try await finished("ci_then_merge")
        h.forge.state {
            $0.pipelines["commit-1"] = PipelineStatus(state: .failed, url: pipelineURL, failedJobs: [CIJob(name: "lint", stage: "", url: nil, logTail: "")])
            $0.baselines = ["lint": .failed(nil)]
        }
        h.clock.advance(121)
        await h.cycle()
        #expect(h.backlog.card(id: "id-12")?.state == .review)
        #expect(h.backlog.state.get.reviewNotes["id-12"]?.hasPrefix("CI failed on `commit-1` only in jobs that also fail on `main`") == true)
        #expect(h.forge.state.get.mergeCalls.isEmpty)
    }

    @Test("B205: a project switched to draft mid-watch moves its card to review, without a CI note or a merge")
    func switchedToDraft() async throws {
        let h = try await finished("ci_then_merge")
        try h.writeConfig(projects: "[[project]]\npath = \"g/app\"\nfinish = \"draft\"")
        h.forge.state { $0.pipelines["commit-1"] = PipelineStatus(state: .passed, url: pipelineURL) }
        h.clock.advance(121)
        await h.cycle()
        #expect(h.backlog.card(id: "id-12")?.state == .review)
        #expect(h.backlog.state.get.reviewNotes["id-12"] == nil)
        #expect(h.forge.state.get.mergeCalls.isEmpty)
        #expect(h.forge.state.get.pipelineCalls.isEmpty)
    }

    @Test("B206: a failed markMerged backs off, and the retry merges again")
    func markMergedFails() async throws {
        let h = try await finished("merge")
        h.backlog.state { $0.failMarkMerged = FakeError("502 Bad Gateway") }
        await h.cycle()
        #expect(h.log.contains("g/app#12: merged g/app!1, but moving it to review_merged failed: 502 Bad Gateway; trying again in 30 s", level: .error))
        #expect(h.backlog.card(id: "id-12")?.state == .verifying)
        h.backlog.state { $0.failMarkMerged = nil }
        h.clock.advance(31)
        await h.cycle()
        #expect(h.forge.state.get.mergeCalls.count == 2)
        #expect(h.backlog.card(id: "id-12")?.state == .reviewMerged)
    }

    @Test("B206: two cards of one project merge one after the other")
    func oneMergePerProject() async throws {
        let h = try await finished("merge", cards: [12, 13])
        #expect(h.backlog.card(id: "id-12")?.state == .verifying && h.backlog.card(id: "id-13")?.state == .verifying)
        await h.cycle()
        #expect(h.forge.state.get.mergeCalls.count == 1)
        await h.cycle()
        #expect(h.forge.state.get.mergeCalls.count == 2)
        #expect(h.backlog.card(id: "id-12")?.state == .reviewMerged && h.backlog.card(id: "id-13")?.state == .reviewMerged)
    }

    @Test("B207: pending tries again at the next poll, then merges")
    func pendingThenMerged() async throws {
        let h = try await finished("merge")
        h.forge.state { $0.mergeResults = [.pending("checking")] }
        await h.cycle()
        #expect(h.backlog.card(id: "id-12")?.state == .verifying)
        #expect(h.log.contains("g/app#12: the forge can't merge g/app!1 yet: checking; trying again every 120 s", level: .info))
        await h.cycle()
        #expect(h.forge.state.get.mergeCalls.count == 1)
        h.clock.advance(121)
        await h.cycle()
        #expect(h.backlog.card(id: "id-12")?.state == .reviewMerged)
    }

    @Test("B207: still pending ci_timeout_minutes after the first pending marks the card stuck")
    func pendingTimesOut() async throws {
        let h = try await finished("merge", manifest: ciManifest)
        h.forge.state { $0.mergeResults = [.pending("ci_still_running"), .pending("ci_still_running"), .pending("ci_still_running")] }
        await h.cycle()
        h.clock.advance(59 * 60)
        await h.cycle()
        #expect(blocker(h) == nil)
        h.clock.advance(121)
        await h.cycle()
        #expect(blocker(h)?.hasPrefix("The forge couldn't merge g/app!1 within 60 min: ci_still_running.") == true)
        #expect(try record(h) == nil)
    }

    @Test("B207: a thrown merge error backs off; a BackendRejection marks the card stuck")
    func mergeErrors() async throws {
        let h = try await finished("merge")
        h.forge.state { $0.failMerge = FakeError("503 Service Unavailable") }
        await h.cycle()
        #expect(h.log.contains("g/app#12: merging g/app!1 failed: 503 Service Unavailable; trying again in 30 s", level: .error))
        #expect(blocker(h) == nil)
        h.forge.state { $0.failMerge = BackendRejection("PUT /merge: 404 [gone]") }
        h.clock.advance(31)
        await h.cycle()
        #expect(blocker(h)?.hasPrefix(#"The forge refused to merge g/app!1: PUT /merge: 404 \[gone\]"#) == true)
    }

    @Test("B209: blocked marks the card stuck, naming the escaped reason and linking the review request")
    func blocked() async throws {
        let h = try await finished("merge")
        h.forge.state { $0.mergeResults = [.blocked("not_approved](https://evil.example)")] }
        await h.cycle()
        #expect(blocker(h) == """
            The forge refused to merge g/app!1: not_approved\\]\\(https://evil.example\\). Merge it by hand or change the rule that blocks it, then move the card on.

            Review request: [g/app!1](\(reviewURL.absoluteString))
            """)
    }
}

@Suite struct MergeDecisionTests {
    @Test("B206, B207, B208, B209: the merge decision table")
    func table() {
        func d(_ r: MergeResult, pendingFor: TimeInterval? = nil, rebases: Int = 0) -> MergeDecision {
            Reconciler.decideMerge(r, pendingFor: pendingFor, rebases: rebases, timeout: 3600)
        }
        #expect(d(.merged(commit: "abc")) == .merged(commit: "abc"))
        #expect(d(.merged(commit: nil), rebases: 1) == .merged(commit: nil))
        #expect(d(.pending("checking")) == .wait("checking"))
        #expect(d(.pending("checking"), pendingFor: 3599) == .wait("checking"))
        #expect(d(.pending("checking"), pendingFor: 3600) == .stuck(.pendingTooLong("checking")))
        #expect(d(.outdated("need_rebase")) == .rebase("need_rebase"))
        #expect(d(.outdated("need_rebase"), rebases: 1) == .stuck(.outdatedAfterRebase("need_rebase")))
        #expect(d(.blocked("not_approved")) == .stuck(.blocked("not_approved")))
    }
}
