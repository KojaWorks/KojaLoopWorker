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

    @Test("B205: a watch of a project that left the config keeps reading CI and moves to review, never merging")
    func projectLeftTheConfig() async throws {
        let h = try await finished("ci_then_merge")
        try h.writeConfig(projects: "")
        h.clock.advance(121)
        await h.cycle()
        #expect(h.forge.state.get.pipelineCalls == ["commit-1"])
        #expect(h.backlog.card(id: "id-12")?.state == .verifying)
        h.forge.state { $0.pipelines["commit-1"] = PipelineStatus(state: .passed, url: pipelineURL) }
        h.clock.advance(121)
        await h.cycle()
        #expect(h.backlog.card(id: "id-12")?.state == .review)
        #expect(h.backlog.state.get.reviewNotes["id-12"] == "CI passed on `commit-1`: \(pipelineURL.absoluteString)")
        #expect(h.forge.state.get.mergeCalls.isEmpty)
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

    /// Card 12 of a `finish` project: the forge refused its merge as outdated, and its rebase
    /// round runs.
    func rebasing(_ finish: String = "merge", manifest: String = "", results: [MergeResult] = [.outdated("need_rebase")]) async throws -> ManagerHarness {
        let h = try await finished(finish, manifest: manifest)
        h.git.state { $0.refs["origin/main"] = "base-1" }
        h.forge.state { $0.mergeResults = results }
        if finish == "ci_then_merge" {
            h.forge.state { $0.pipelines["commit-1"] = PipelineStatus(state: .passed, url: pipelineURL) }
            h.clock.advance(121)
        }
        await h.cycle()
        await h.cycle()
        return h
    }

    func finishRound(_ h: ManagerHarness) async throws {
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"Rebased."}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
    }

    @Test("B208: outdated runs a rebase round on the card branch, which pushes under the lease, returns to verifying and merges")
    func rebaseRound() async throws {
        let h = try await rebasing()
        #expect(h.backlog.writes.contains(.resumeFix("id-12")))
        #expect(h.tmux.spawned.count == 2)
        #expect(h.lifecycle.state.get.acquiredBases.last == "loopworker-12-fix-it")
        let card = try #require(CardRecord.read(h.stateDir().appending(path: "card.json")))
        #expect(card.ciRound == 1 && card.ciCommit == "commit-1" && card.rebaseRound == true && card.rebases == 1 && card.rebaseTarget == "base-1")
        #expect(!FileManager.default.fileExists(atPath: h.stateDir().appending(path: "ci.md").path))
        let brief = try String(contentsOf: h.stateDir().appending(path: "brief.md"), encoding: .utf8)
        #expect(brief.contains("## Rebase"))
        #expect(brief.contains("because `main` moved since commit `commit-1` was pushed. The forge's reason: need_rebase"))
        #expect(brief.contains("Rebase this branch onto `base-1`, which is `origin/main` as of this round: `git rebase base-1`."))
        #expect(brief.contains("pushed as `commit-1`"))
        #expect(!brief.contains("## CI failed"))
        #expect(h.log.contains("spawned worker for rebase round 1 for g/app#12", level: .info))

        try await finishRound(h)
        #expect(h.git.calls.contains("isAncestor base-1"))
        #expect(h.git.state.get.pushes.map(\.expected) == [nil, "commit-1"])
        #expect(h.forge.state.get.opened.count == 1)
        let r = try #require(try record(h))
        #expect(r.sha == "commit-2" && r.round == 1 && r.rebases == 1)
        #expect(h.backlog.state.get.verifyingPlans["id-12"] == .merge)
        await h.cycle()
        #expect(h.forge.state.get.mergeCalls.last == "\(reviewURL.absoluteString) @ commit-2")
        #expect(h.backlog.card(id: "id-12")?.state == .reviewMerged)
    }

    @Test("B208: outdated again after a rebase round marks the card stuck")
    func outdatedTwice() async throws {
        let h = try await rebasing(results: [.outdated("need_rebase"), .outdated("conflict")])
        try await finishRound(h)
        await h.cycle()
        #expect(blocker(h)?.hasPrefix("The forge still can't merge g/app!1 after a rebase round, because `main` moved: conflict.") == true)
        #expect(h.backlog.writes.filter { $0 == .resumeFix("id-12") }.count == 1)
    }

    @Test("B208: a rebase round whose branch isn't based on origin/<base> is stuck and pushes nothing")
    func rebaseNotBased() async throws {
        let h = try await rebasing()
        h.git.state { $0.ancestors["base-1"] = false }
        try await finishRound(h)
        #expect(blocker(h) == "The worker reported done for rebase round 1, but `loopworker-12-fix-it` isn't based on `main` at `base-1`, which the round rebased onto.")
        #expect(h.git.state.get.pushes.count == 1)
    }

    @Test("B208: origin/<base> moving during a rebase round doesn't fail a branch rebased onto the pinned commit")
    func baseMovesDuringTheRound() async throws {
        let h = try await rebasing()
        h.git.state {
            $0.refs["origin/main"] = "base-2"
            $0.ancestors["origin/main"] = false
            $0.ancestors["base-2"] = false
        }
        try await finishRound(h)
        #expect(blocker(h) == nil)
        #expect(h.git.calls.filter { $0.hasPrefix("isAncestor") } == ["isAncestor base-1"])
        #expect(try record(h)?.sha == "commit-2")
        #expect(h.backlog.card(id: "id-12")?.state == .verifying)
    }

    @Test("B208: a rebase round survives a Manager restart with its pinned target")
    func rebaseTargetSurvivesARestart() async throws {
        let h = try await rebasing()
        try h.restart()
        h.git.state { $0.ancestors["origin/main"] = false }
        try await h.boot()
        try await finishRound(h)
        #expect(blocker(h) == nil)
        #expect(h.git.calls.contains("isAncestor base-1"))
    }

    @Test("B208: rebase rounds don't use up ci_fix_attempts")
    func rebaseIsNotACIFix() async throws {
        let h = try await rebasing("ci_then_merge", manifest: ciManifest)
        try await finishRound(h)
        #expect(h.backlog.state.get.verifyingPlans["id-12"] == .ciThenMerge)
        h.forge.state {
            $0.pipelines["commit-2"] = PipelineStatus(state: .failed, url: pipelineURL, failedJobs: [CIJob(name: "test", stage: "", url: nil, logTail: "")])
        }
        h.clock.advance(121)
        await h.cycle()
        await h.cycle()
        #expect(blocker(h) == nil)
        #expect(h.backlog.writes.filter { $0 == .resumeFix("id-12") }.count == 2)
        let brief = try String(contentsOf: h.stateDir().appending(path: "brief.md"), encoding: .utf8)
        #expect(brief.contains("CI fix round 1 of 1"))
        #expect(CardRecord.read(h.stateDir().appending(path: "card.json"))?.ciRound == 2)
    }

    @Test("B208: watch and card records without the rebase fields still decode")
    func oldRecordsDecode() throws {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let watch = """
            {"base":"main","branch":"b","card":{"display":"g/app#12","id":"id-12"},"project":"g/app",
             "pushedAt":"2026-10-01T00:00:00Z","review":{"display":"g/app!1","url":"\(reviewURL.absoluteString)"},"round":1,"sha":"abc"}
            """
        let r = try d.decode(CIWatchRecord.self, from: Data(watch.utf8))
        #expect(r.rebases == nil && r.ciRounds == 1)
        let card = """
            {"base":"main","branch":"b","claimedAt":"2026-10-01T00:00:00Z","project":"g/app","ref":{"display":"g/app#12","id":"id-12"},
             "slot":0,"ciRound":1,"ciCommit":"abc"}
            """
        let c = try d.decode(CardRecord.self, from: Data(card.utf8))
        #expect(c.rebaseRound == nil && c.rebases == nil && c.rebaseTarget == nil && c.ciRound == 1)
    }

    @Test("B210: the status shows merging, merge pending, rebase queued and rebase starting")
    func statusStrings() async throws {
        let h = try await finished("merge")
        #expect(try h.status().ci?.first?.state == "merging")
        h.forge.state { $0.mergeResults = [.pending("checking"), .outdated("need_rebase")] }
        await h.cycle()
        #expect(try h.status().ci?.first?.state == "merge pending: checking")
        try Data().write(to: h.home.appending(path: "state/PAUSED"))
        h.clock.advance(121)
        await h.cycle()
        #expect(try h.status().ci?.first?.state == "rebase queued")
        h.lifecycle.state { $0.acquireFailure = SlotFailure("reset.sh exited 1") }
        try FileManager.default.removeItem(at: h.home.appending(path: "state/PAUSED"))
        await h.cycle()
        #expect(h.log.contains("g/app#12: rebase round 1 failed to start (1 in a row): preparing the slot failed: reset.sh exited 1", level: .error))
        #expect(try h.status().ci?.first?.state == "rebase queued")
        let text = StatusReport.render(try h.status(), lockHolder: 1, now: h.clock.now()).text
        #expect(text.contains("waiting for CI or merge:\n  g/app#12 round 0 at commit-1: rebase queued"))
    }

    @Test("B202: the Manager logs a deprecated config key at start and when a reload changes the config")
    func configWarningsAreLogged() async throws {
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/app\"\ndraft = true")
        try await h.boot()
        let warning = "config.toml: g/app: draft is deprecated; replace it with finish = \"draft\""
        #expect(h.log.contains(warning, level: .warning))
        try h.writeConfig(projects: "[[project]]\npath = \"g/app\"\ndraft = false")
        h.clock.advance(61)
        await h.cycle()
        #expect(h.log.contains("config.toml: g/app: draft is deprecated; replace it with finish = \"ready\"", level: .warning))
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
