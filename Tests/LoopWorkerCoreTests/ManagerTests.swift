import Foundation
import Testing
@testable import LoopWorkerCore

let oneColdProject = """
    [[project]]
    path = "g/app"
    slots = 1
    worker_env = ["FORWARD_ME", "NOT_SET_ANYWHERE"]
    """

func fileMode(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
}

@Suite struct ManagerSpawnTests {
    @Test func claimThenSpawnWritesTheWorkerFilesIntoTheStateDirectory() async throws {  // B74, B78, B83, B84
        let h = try ManagerHarness(projects: oneColdProject)
        h.addCard(12, title: "Fix it")
        try await h.boot()
        await h.cycle()

        #expect(h.backlog.card(id: "id-12")?.state == .working)
        #expect(h.lifecycle.state.get.acquiredBranches == ["loopworker-12-fix-it"])
        let dir = h.stateDir()
        let worktree = h.clones.appending(path: "g--app.slots/0")
        #expect(h.tmux.spawned == [.init(session: "lw_g--app_0", directory: worktree, script: dir.appending(path: "launch.sh"))])

        let record = try #require(CardRecord.read(dir.appending(path: "card.json")))
        #expect(record.ref.display == "g/app#12" && record.branch == "loopworker-12-fix-it" && record.base == "main")
        #expect(try String(contentsOf: dir.appending(path: "card.md"), encoding: .utf8) == "# Fix it\n")
        #expect(try String(contentsOf: dir.appending(path: "brief.md"), encoding: .utf8).contains("g/app#12 in g/app"))
        #expect(try String(contentsOf: dir.appending(path: "mcp.json"), encoding: .utf8) == #"{"mcpServers":{}}"#)

        let env = dir.appending(path: "worker.env")
        #expect(try fileMode(env) == 0o600)
        #expect(try String(contentsOf: env, encoding: .utf8) == "CLAUDE_CODE_OAUTH_TOKEN='sk-ant-fabricated'\nFORWARD_ME='yes'\n")
        #expect(h.log.contains("NOT_SET_ANYWHERE", level: .warning))

        let launch = dir.appending(path: "launch.sh")
        #expect(try fileMode(launch) == 0o755)
        #expect(try String(contentsOf: launch, encoding: .utf8)
            == WorkerLaunch.script(worktree: worktree, stateDir: dir, port: 54400, model: nil))
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func snapshotWithheldContentIsListedAndLogged() async throws {  // B79
        let h = try ManagerHarness(projects: oneColdProject)
        let card = h.addCard(1)
        h.backlog.add(card, snapshot: CardSnapshot(markdown: "# Fix it\n", excluded: ["comment 9 by @eve"]))
        try await h.boot()
        await h.cycle()
        let md = try String(contentsOf: h.stateDir().appending(path: "card.md"), encoding: .utf8)
        #expect(md.contains("## Withheld\n\n- comment 9 by @eve"))
        #expect(h.log.contains("withheld from g/app#1: comment 9 by @eve"))
    }

    @Test func modelComesFromTheCardBeforeTheProject() async throws {  // B82
        let h = try ManagerHarness(projects: oneColdProject + "\nmodel = \"sonnet\"")
        var card = h.addCard(1)
        card.model = "opus"
        h.backlog.add(card)
        try await h.boot()
        await h.cycle()
        let launch = try String(contentsOf: h.stateDir().appending(path: "launch.sh"), encoding: .utf8)
        #expect(launch.contains("--model 'opus'"))
    }

    @Test func folderTrustDialogIsAcceptedOnce() async throws {  // B85
        let h = try ManagerHarness(projects: oneColdProject)
        h.tmux.state { $0.spawnPane = "Yes, I trust this folder" }
        h.addCard(1)
        try await h.boot()
        await h.cycle()
        #expect(h.tmux.state.get.keysSent.map(\.session) == ["lw_g--app_0"])
    }

    @Test func lostClaimSkipsTheCardAndClearsTheRecord() async throws {  // B74
        let h = try ManagerHarness(projects: oneColdProject)
        h.addCard(1)
        h.backlog.state { $0.claimOverride = false }
        try await h.boot()
        await h.cycle()
        #expect(h.tmux.spawned.isEmpty)
        #expect(h.lifecycle.calls.filter { $0.hasPrefix("acquire") }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.stateDir().appending(path: "card.json").path))
    }

    @Test func aClaimWhoseResponseWasLostButLandedIsKept() async throws {
        let h = try ManagerHarness(projects: oneColdProject)
        h.addCard(1)
        h.backlog.state { $0.claimThrows = true }
        try await h.boot()
        await h.cycle()
        #expect(h.tmux.spawned.count == 1)
    }

    @Test func aClaimThatFailedWithoutLandingSkipsTheCard() async throws {
        let h = try ManagerHarness(projects: oneColdProject)
        h.addCard(1)
        h.backlog.state { $0.claimThrows = false }
        try await h.boot()
        await h.cycle()
        #expect(h.tmux.spawned.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.stateDir().appending(path: "card.json").path))
    }

    @Test func acquireFailureBreaksTheSlotAndReleasesTheCard() async throws {  // B36, B75
        let h = try ManagerHarness(projects: oneColdProject)
        h.addCard(1)
        h.lifecycle.state { $0.acquireFailure = SlotFailure("provision.sh exited 1: no disk") }
        try await h.boot()
        await h.cycle()
        #expect(h.backlog.writes.last == .release("id-1", reason: "Couldn't start a worker: preparing the slot failed: provision.sh exited 1: no disk", countsAsAttempt: false))
        #expect(h.lifecycle.calls.contains("recycle g--app/0"))
        #expect(try h.status().projects[0].slots[0].state == "broken")
        #expect(h.tmux.spawned.isEmpty)

        h.lifecycle.state { $0.acquireFailure = nil }
        h.clock.advance(181)
        await h.cycle()  // the cold slot returns to the pool
        await h.cycle()
        #expect(h.tmux.spawned.count == 1)
    }

    @Test func oneSpawnPerTick() async throws {  // B70
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/app\"\nslots = 2")
        h.addCard(1, priority: 2)
        h.addCard(2, priority: 1)
        try await h.boot()
        await h.cycle()
        #expect(h.tmux.spawned.map(\.session) == ["lw_g--app_0"])
        #expect(h.backlog.card(id: "id-1")?.state == .working)
        await h.cycle()
        #expect(h.tmux.spawned.map(\.session) == ["lw_g--app_0", "lw_g--app_1"])
    }

    @Test func maxConcurrentWorkersCapsStarts() async throws {  // B70
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/app\"\nslots = 2", top: "max_concurrent_workers = 1")
        h.addCard(1)
        h.addCard(2)
        try await h.boot()
        await h.cycle()
        await h.cycle()
        await h.cycle()
        #expect(h.tmux.spawned.count == 1)
    }

    @Test func weightedBudgetLimitsColdStarts() async throws {  // B47
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/app\"\nslots = 2\nweight = 3")
        h.addCard(1)
        h.addCard(2)
        try await h.boot()
        await h.cycle()
        await h.cycle()
        #expect(h.tmux.spawned.count == 1)
    }

    @Test func hotProjectsFillFirst() async throws {  // B70
        let h = try ManagerHarness(projects: """
            [[project]]
            path = "g/cold"
            [[project]]
            path = "g/hot"
            hot = true
            """)
        h.addCard(1, project: "g/cold", priority: 9)
        h.addCard(2, project: "g/hot")
        try await h.boot()
        #expect(h.lifecycle.calls.contains("prepare g--hot/0"))
        await h.cycle()
        #expect(h.tmux.spawned.map(\.session) == ["lw_g--hot_0"])
    }

    @Test func pausedFilesStopClaims() async throws {  // B72
        let h = try ManagerHarness(projects: oneColdProject)
        h.addCard(1)
        try await h.boot()
        let state = h.home.appending(path: "state")
        let hostPause = state.appending(path: "PAUSED")
        let projectPause = state.appending(path: "projects/g--app/PAUSED")
        try FileManager.default.createDirectory(at: projectPause.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: hostPause)
        await h.cycle()
        #expect(h.tmux.spawned.isEmpty)
        #expect(try h.status().paused)
        try FileManager.default.removeItem(at: hostPause)
        try Data().write(to: projectPause)
        await h.cycle()
        #expect(h.tmux.spawned.isEmpty)
        #expect(try h.status().projects[0].paused)
        try FileManager.default.removeItem(at: projectPause)
        await h.cycle()
        #expect(h.tmux.spawned.count == 1)
    }

    @Test func failedWorkableReadClaimsNothing() async throws {  // B69
        let h = try ManagerHarness(projects: oneColdProject)
        h.addCard(1)
        h.backlog.state { $0.failWorkable = true }
        try await h.boot()
        await h.cycle()
        #expect(h.backlog.writes.isEmpty)
        #expect(h.log.contains("can't read workable cards", level: .error))
    }

    @Test func preflightGetsTheTokenFromTheMergedEnvironment() async throws {  // B95
        let h = try ManagerHarness(projects: oneColdProject)
        try await h.boot()
        let spec = try #require(h.runner.specs.get.first { $0.executable == "claude" })
        #expect(spec.environment["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-ant-fabricated")
        #expect(spec.environment["USER"] == .some(nil))
    }

    @Test func failingPreflightBlocksClaims() async throws {  // B95
        let h = try ManagerHarness(projects: oneColdProject)
        h.runner.handler { $0 = { _ in ProcessResult(status: 1, output: "Invalid API key") } }
        h.addCard(1)
        try await h.boot()
        await h.cycle()
        #expect(h.backlog.writes.isEmpty)
        #expect(h.log.contains("claude login check failing: Invalid API key", level: .error))
        #expect(try h.status().auth.state == "failing")
    }

    @Test func timedOutPreflightDoesNotStopTheNextFill() async throws {  // B176
        let h = try ManagerHarness(projects: oneColdProject)
        h.runner.handler { $0 = { $0.executable == "claude" ? ProcessResult(status: -9, output: "", timedOut: true) : ProcessResult(status: 0, output: "") } }
        h.addCard(1)
        try await h.boot()
        await h.cycle()
        #expect(h.backlog.writes.isEmpty)
        #expect(h.log.contains("claude login check inconclusive (1 in a row): claude -p timed out after 120 s; next check in 30 s", level: .warning))
        #expect(try h.status().auth.state == "unknown")
        #expect(try h.status().auth.detail?.contains("inconclusive (1 in a row)") == true)

        h.runner.handler { $0 = { _ in ProcessResult(status: 0, output: "") } }
        h.clock.advance(30)
        await h.cycle()
        await h.cycle()
        #expect(h.backlog.card(id: "id-1")?.state == .working)
        #expect(!h.log.contains("claude login check failing"))
    }
}

@Suite struct ManagerLaunchScriptTests {
    @Test func launchScriptStartsClaudeWithoutTheManagersSecrets() throws {  // B84, B15
        let dir = try temporaryDirectory()
        let state = dir.appending(path: "state")
        let worktree = dir.appending(path: "work tree")
        let bin = dir.appending(path: "bin")
        for d in [state, worktree, bin] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let out = dir.appending(path: "claude-saw")
        let stub = bin.appending(path: "claude")
        try "#!/bin/sh\n{ pwd; env; printf 'ARG:%s\\n' \"$@\"; } > \(WorkerLaunch.shellQuote(out.path))\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        try WorkerLaunch.environmentFile([("FROM_WORKER_ENV", "it's here")])
            .write(to: state.appending(path: "worker.env"), atomically: true, encoding: .utf8)
        try "the brief".write(to: state.appending(path: "brief.md"), atomically: true, encoding: .utf8)
        let launch = state.appending(path: "launch.sh")
        try WorkerLaunch.script(worktree: worktree, stateDir: state, port: 54400, model: "opus")
            .write(to: launch, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(filePath: "/bin/bash")
        p.arguments = [launch.path]
        p.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": dir.path, "USER": "someone",
                         "LOOPWORKER_GITLAB_TOKEN": "glpat-fabricated", "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-parent"]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)

        let saw = try String(contentsOf: out, encoding: .utf8)
        #expect(saw.hasPrefix(worktree.path + "\n"))
        #expect(saw.contains("FROM_WORKER_ENV=it's here"))
        #expect(saw.contains("LOOPWORKER=1"))
        #expect(saw.contains("LOOPWORKER_OUTCOME=\(state.path)/outcome.json"))
        #expect(saw.contains("LOOPWORKER_PORT=54400"))
        #expect(!saw.contains("glpat-fabricated"))
        #expect(!saw.contains("sk-ant-parent"))
        #expect(!saw.contains("USER="))
        #expect(saw.contains("ARG:--add-dir\nARG:\(state.path)\nARG:--strict-mcp-config\nARG:--mcp-config\nARG:\(state.path)/mcp.json\nARG:--model\nARG:opus\nARG:the brief"))
    }
}

@Suite struct ManagerFinishTests {
    /// Boots with one card spawned on slot 0 of g/app.
    func spawned(_ projects: String = oneColdProject, top: String = "", attempts: Int = 0) async throws -> ManagerHarness {
        let h = try ManagerHarness(projects: projects, top: top)
        h.addCard(12, attempts: attempts)
        try await h.boot()
        await h.cycle()
        #expect(h.tmux.spawned.count == 1)
        return h
    }

    @Test func doneIsPushedReviewedAndRecycled() async throws {  // B88, B89
        let h = try await spawned()
        try "<html/>".write(to: h.stateDir().appending(path: "guide.html"), atomically: true, encoding: .utf8)
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"Did it.","guide":"guide.html"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()

        #expect(h.git.state.get.pushes.map(\.branch) == ["loopworker-12-fix-it"])
        #expect(h.git.state.get.pushes[0].environment == FakeForge.environment)
        #expect(h.git.state.get.pushes[0].url == "https://forge.example/g/app.git")
        let draft = try #require(h.forge.state.get.opened.first)
        #expect(draft.title == "Fix it" && draft.draft && draft.targetBranch == "main" && draft.assignToOwner)  // B182
        #expect(draft.body == "Did it.\n\n---\nCard: [g/app#12](https://forge.example/g/app/-/issues/12)\nReview guide: [guide.html](https://forge.example/uploads/guide.html)\n")
        #expect(h.backlog.writes.last == .markReview("id-12", url: URL(string: "https://forge.example/g/app/-/merge_requests/1")!))
        #expect(h.lifecycle.calls.last == "recycle g--app/0")
        let dir = h.stateDir()
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "last-outcome.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "outcome.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "card.json").path))
        #expect(try h.status().projects[0].slots[0].state == "idle")
    }

    @Test func guideOutsideTheStateDirectoryIsNotAttached() async throws {  // B89, B185
        let h = try await spawned()
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"b","guide":"../../../config.toml"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.forge.state.get.attached.isEmpty)
        let outside = h.stateDir().appending(path: "../../../config.toml").standardizedFileURL.resolvingSymlinksInPath().path
        #expect(h.log.contains("didn't attach ../../../config.toml (\(outside)) to g/app#12's review request: it resolves outside the slot state directory", level: .warning))
        let body = try #require(h.forge.state.get.opened.first?.body)
        #expect(body.hasPrefix("b\n\nLoopWorker didn't attach ../../../config.toml: it resolves outside the slot state directory\n\n---"))
        #expect(!body.contains(h.stateDir().deletingLastPathComponent().path))
        #expect(!body.contains("Review guide:"))
        #expect(h.backlog.writes.last == .markReview("id-12", url: URL(string: "https://forge.example/g/app/-/merge_requests/1")!))
    }

    @Test("B185: attachment references become URLs; refused ones stay and are named under the body")
    func attachmentReferences() async throws {
        let h = try await spawned()
        try "png".write(to: h.stateDir().appending(path: "after.png"), atomically: true, encoding: .utf8)
        try "A=1".write(to: h.stateDir().appending(path: ".env"), atomically: true, encoding: .utf8)
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"![after](attachment:after.png) [env](attachment:.env) <img src='attachment:after.png'>"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        let body = try #require(h.forge.state.get.opened.first?.body)
        #expect(body.hasPrefix("![after](https://forge.example/uploads/after.png) [env](attachment:.env) <img src='attachment:after.png'>\n\nLoopWorker didn't attach .env: its name looks like a credential file\n\nLoopWorker didn't attach attachment:after.png: use `![alt](attachment:path)` or `[text](attachment:path)`\n\n---\nCard: "))
        #expect(h.log.contains("didn't attach .env", level: .warning))
        #expect(h.log.contains("didn't attach attachment:after.png to g/app#12's review request: use", level: .warning))
        #expect(h.backlog.card(id: "id-12")?.state == .review)
    }

    @Test("B185: a forge without attachments names each file under the body, the guide too")
    func forgeWithoutAttachments() async throws {
        let h = try await spawned()
        h.forge.state { $0.supportsAttachments = false }
        try "<html/>".write(to: h.stateDir().appending(path: "guide.html"), atomically: true, encoding: .utf8)
        try "png".write(to: h.stateDir().appending(path: "after.png"), atomically: true, encoding: .utf8)
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"![after](attachment:after.png)","guide":"guide.html"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.forge.state.get.opened.first?.body == "![after](attachment:after.png)\n\nLoopWorker didn't attach after.png: this forge has no attachments\n\nLoopWorker didn't attach guide.html: this forge has no attachments\n\n---\nCard: [g/app#12](https://forge.example/g/app/-/issues/12)\n")
    }

    @Test func outcomeWaitsForTheGraceWhileTheSessionLives() async throws {  // B56
        let h = try await spawned()
        try h.writeOutcome(#"{"outcome":"stuck","blocker":"?"}"#)
        let file = h.stateDir().appending(path: "outcome.json")
        try FileManager.default.setAttributes([.modificationDate: h.clock.now()], ofItemAtPath: file.path)
        await h.cycle()
        #expect(h.tmux.exists("lw_g--app_0"))
        h.clock.advance(21)
        await h.cycle()
        #expect(!h.tmux.exists("lw_g--app_0"))
        #expect(h.backlog.card(id: "id-12")?.state == .stuck)
    }

    @Test func stuckPushesCommitsAndNamesTheBranch() async throws {  // B90
        let h = try await spawned()
        try h.writeOutcome(#"{"outcome":"stuck","blocker":"Which endpoint?"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.git.pushedBranches == ["loopworker-12-fix-it"])
        #expect(h.backlog.writes.last == .markStuck("id-12", blocker: "Which endpoint?\n\nThe worker's commits are on branch `loopworker-12-fix-it`."))
        #expect(h.forge.state.get.opened.isEmpty)
    }

    @Test func doneWithoutCommitsBecomesStuck() async throws {  // B87
        let h = try await spawned()
        h.git.state { $0.defaultCommitsAhead = 0 }
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"b"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.git.pushedBranches.isEmpty)
        #expect(h.forge.state.get.opened.isEmpty)
        #expect(h.backlog.writes.last == .markStuck("id-12", blocker: "The worker reported done, but branch `loopworker-12-fix-it` has no commits ahead of `main`."))
    }

    @Test func failedFinishIsRetriedWithoutADuplicateReviewRequest() async throws {  // B91, B207
        let h = try await spawned()
        h.git.state { $0.head = "commit-1" }
        h.backlog.state { $0.failMarkReview = FakeError("502 Bad Gateway") }
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"b"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.forge.state.get.openCalls.count == 1)
        #expect(h.log.contains("moving g/app#12 to review: 502 Bad Gateway; retrying in 30 s", level: .error))
        let slot = try h.status().projects[0].slots[0]
        #expect(slot.state == "busy")
        #expect(slot.lastError?.contains("502") == true)

        h.backlog.state { $0.failMarkReview = nil }
        await h.cycle()
        #expect(h.forge.state.get.openCalls.count == 1)  // still backing off
        h.clock.advance(31)
        await h.cycle()
        // The retry finds the review request open, and its description already marks this commit.
        #expect(h.forge.state.get.openCalls.count == 1)
        #expect(h.forge.state.get.opened.map(\.commit) == ["commit-1"])
        #expect(h.forge.state.get.notes.isEmpty)
        #expect(h.log.contains("g/app!1 already has the note for commit-1; not posting it again", level: .info))
        #expect(h.git.state.get.pushes.map(\.expected) == [nil, "commit-1"])  // the retry leases on its own push
        #expect(h.backlog.card(id: "id-12")?.state == .review)
        #expect(try h.status().projects[0].slots[0].state == "idle")
    }

    @Test("B160: an LFS repo's objects go up before the branch, and a failed LFS push is retried")
    func lfsPushPrecedesThePush() async throws {
        let h = try await spawned()
        h.git.state { $0.usesLFS = true; $0.failLFSPushOnce = true }
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"b"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.git.state.get.pushes.isEmpty)
        #expect(h.log.contains("pushing Git LFS objects for loopworker-12-fix-it: git lfs push failed; retrying in 30 s", level: .error))
        #expect(try h.status().projects[0].slots[0].state == "busy")

        h.clock.advance(31)
        await h.cycle()
        let calls = h.git.calls.filter { $0.hasPrefix("lfsPush") || $0.hasPrefix("push") }
        #expect(calls == ["lfsPush https://forge.example/g/app.git forge-env", "push loopworker-12-fix-it"])
        #expect(h.backlog.card(id: "id-12")?.state == .review)
    }

    @Test func aBranchSomeoneElsePushedEndsTheCardStuck() async throws {
        let h = try await spawned()
        h.git.state { $0.pushFailure = PushRejected(branch: "loopworker-12-fix-it", url: "https://forge.example/g/app.git") }
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"b"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        guard case .markStuck("id-12", let blocker)? = h.backlog.writes.last else {
            Issue.record("expected markStuck, got \(h.backlog.writes)")
            return
        }
        #expect(blocker.hasPrefix("Branch `loopworker-12-fix-it` already exists on the forge and wasn't created by LoopWorker for this card"))
        #expect(h.forge.state.get.openCalls.isEmpty)
        #expect(try h.status().projects[0].slots[0].state == "idle")
    }

    /// The card went stuck with a pushed commit, and a human sent it back to ready.
    func requeuedAfterStuck(_ h: ManagerHarness) async throws {
        try h.writeOutcome(#"{"outcome":"stuck","blocker":"Which endpoint?"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.backlog.card(id: "id-12")?.state == .stuck)
        #expect(h.git.pushedBranches == ["loopworker-12-fix-it"])
        h.backlog.setState("id-12", .ready)
    }

    @Test func aRequeuedStuckCardResumesItsPushedBranch() async throws {  // B178
        let h = try await spawned()
        try await requeuedAfterStuck(h)
        await h.cycle()
        #expect(h.tmux.spawned.count == 2)
        #expect(h.lifecycle.state.get.acquiredBases == ["main", "loopworker-12-fix-it"])
        #expect(h.git.calls.contains("hasRemoteBranch loopworker-12-fix-it"))
        #expect(h.log.contains("resuming g/app#12 from origin/loopworker-12-fix-it, which an earlier attempt pushed at commit-1", level: .info))
        let brief = try String(contentsOf: h.stateDir().appending(path: "brief.md"), encoding: .utf8)
        #expect(brief.contains("## Resuming"))
        #expect(brief.contains("git log origin/main..HEAD"))

        h.git.state { $0.defaultCommitsAhead = 1 }  // ahead of the project base, though no new commits
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"b"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.git.state.get.pushes.map(\.expected) == [nil, "commit-1"])
        #expect(h.git.calls.filter { $0.hasPrefix("commitsAhead") }.last == "commitsAhead main")
        #expect(h.backlog.card(id: "id-12")?.state == .review)
    }

    @Test("B202: a commit that a human pushed before the resume becomes the lease, so the push succeeds")
    func aHumanCommitBeforeTheResumeKeepsThePush() async throws {
        let h = try await spawned()
        try await requeuedAfterStuck(h)
        h.git.state { $0.remoteTips["loopworker-12-fix-it"] = "human-1" }
        await h.cycle()
        #expect(h.tmux.spawned.count == 2)
        #expect(h.log.contains("continuing g/app#12 from human-1, which includes commits pushed after LoopWorker's last push commit-1", level: .info))
        let ledger = try Data(contentsOf: h.home.appending(path: "state/pushes.json"))
        #expect(try JSONDecoder().decode([String: PushRecord].self, from: ledger)["id-12"] == PushRecord(branch: "loopworker-12-fix-it", commit: "human-1"))

        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"b"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.git.state.get.pushes.map(\.expected) == [nil, "human-1"])
        #expect(h.backlog.card(id: "id-12")?.state == .review)
    }

    /// The card finished in review, and its owner moved it back to ready with the review request open.
    func requeuedFromReview(_ h: ManagerHarness) async throws -> ReviewRequest {
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"Did it."}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.backlog.card(id: "id-12")?.state == .review)
        h.backlog.setState("id-12", .ready)
        return try #require(h.forge.state.get.byBranch["loopworker-12-fix-it"])
    }

    @Test("B206: a card resumed with an open review request gets its feedback in the brief, trust-checked against the snapshot's vouch")
    func aReviewRoundBriefCarriesTheFeedback() async throws {
        let h = try await spawned()
        let review = try await requeuedFromReview(h)
        let vouched = h.clock.now()
        h.backlog.state { $0.snapshots["id-12"] = CardSnapshot(markdown: "# Fix it\n", vouchedAt: vouched) }
        h.forge.state {
            $0.feedback[review.url] = ReviewFeedback(threads: [
                .init(id: "d1", position: nil, notes: [.init(author: "alice", createdAt: vouched, body: "Rename SECRET it.")]),
            ], withheld: ["note 9 by @mallory in thread d2: posted late"])
        }
        await h.cycle()
        #expect(h.tmux.spawned.count == 2)
        #expect(h.forge.state.get.feedbackCalls == [vouched])
        let brief = try String(contentsOf: h.stateDir().appending(path: "brief.md"), encoding: .utf8)
        #expect(brief.contains("## Resuming"))
        #expect(brief.contains("## Review feedback"))
        #expect(brief.contains(review.url.absoluteString))
        #expect(brief.contains("```text\nRename [REDACTED] it.\n```"))
        #expect(h.log.contains("withheld from g/app#12's review round: note 9 by @mallory in thread d2: posted late", level: .info))
    }

    @Test("B206: no review section without feedback; a failed read releases the card without counting an attempt")
    func aReviewRoundWithoutFeedback() async throws {
        let h = try await spawned()
        let review = try await requeuedFromReview(h)
        h.forge.state { $0.failFeedback = FakeError("discussions failed") }
        await h.cycle()
        #expect(h.tmux.spawned.count == 1)
        #expect(h.backlog.writes.last == .release("id-12", reason: "Couldn't start a worker: reading the review feedback on \(review.display): discussions failed", countsAsAttempt: false))

        h.forge.state { $0.failFeedback = nil }
        await h.cycle()
        #expect(h.tmux.spawned.count == 2)
        let brief = try String(contentsOf: h.stateDir().appending(path: "brief.md"), encoding: .utf8)
        #expect(brief.contains("## Resuming") && !brief.contains("## Review feedback"))
    }

    /// A review round on card 12 is running: the open review request has threads d1 and d2.
    func reviewRound() async throws -> (ManagerHarness, ReviewRequest) {
        let h = try await spawned()
        let review = try await requeuedFromReview(h)
        h.forge.state {
            $0.threads[review.url] = ["d1", "d2"]
            $0.feedback[review.url] = ReviewFeedback(threads: [.init(id: "d1", position: nil, notes: [.init(author: "alice", createdAt: Date(), body: "Rename it.")])])
        }
        await h.cycle()
        #expect(h.tmux.spawned.count == 2)
        return (h, review)
    }

    @Test("B207: a review round replies per thread and posts its body as a note; failed and unknown replies are listed under it")
    func aReviewRoundPostsRepliesAndANote() async throws {
        let (h, review) = try await reviewRound()
        h.forge.state { $0.failReplies = ["d2"] }
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"Renamed things.","replies":{"d1":"Renamed it.","d2":"Kept it.","d`9\n":"Huh?"}}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        let f = h.forge.state.get, host = await h.manager.hostName
        #expect(f.opened.count == 1 && f.openCalls.count == 1)
        #expect(f.replies == [FakeForge.Posted(review: review.url, thread: "d1", commit: "commit-2", text: "Renamed it.")])
        #expect(f.notes.map(\.text) == ["""
            LoopWorker pushed `commit-2` to this branch.

            Renamed things.

            LoopWorker couldn't post the worker's reply in thread `d2`; the Manager's log on \(host) has the error. The reply:

            Kept it.

            LoopWorker didn't post the worker's reply to thread `d9`: g/app!1 has no such thread. The reply:

            Huh?
            """])
        #expect(h.log.contains("replying in thread d2 of g/app!1 failed: reply in d2 failed", level: .error))
        #expect(h.log.contains("g/app#12's worker replied to thread d`9\n, which g/app!1 doesn't have", level: .warning))
        #expect(h.backlog.card(id: "id-12")?.state == .review)
    }

    @Test("B207: a failed round note fails the finish, and the retry posts it once without repeating the replies")
    func aRetriedReviewRoundPostsOnce() async throws {
        let (h, _) = try await reviewRound()
        h.git.state { $0.head = "head-2" }
        h.forge.state { $0.failNextNote = FakeError("note 502") }
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"Renamed things.","replies":{"d1":"Renamed it."}}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.log.contains("posting this round's note on g/app!1: note 502; retrying in 30 s", level: .error))
        #expect(h.forge.state.get.replies.count == 1 && h.forge.state.get.notes.isEmpty)

        h.backlog.state { $0.failMarkReview = FakeError("502 Bad Gateway") }
        h.clock.advance(31)
        await h.cycle()
        #expect(h.forge.state.get.replies.count == 1 && h.forge.state.get.notes.count == 1)
        #expect(h.log.contains("thread d1 of g/app!1 already has this round's reply", level: .info))

        h.backlog.state { $0.failMarkReview = nil }
        h.clock.advance(61)
        await h.cycle()
        #expect(h.forge.state.get.replies.count == 1 && h.forge.state.get.notes.count == 1)
        #expect(h.log.contains("g/app!1 already has the note for head-2; not posting it again", level: .info))
        #expect(h.backlog.card(id: "id-12")?.state == .review)
    }

    @Test("B207: replies without an open review request go into the new one's description")
    func repliesWithoutAReviewRequest() async throws {
        let h = try await spawned()
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"Did it.","replies":{"d1":"Renamed it."}}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        let body = try #require(h.forge.state.get.opened.first?.body)
        #expect(body.hasPrefix("Did it.\n\nLoopWorker didn't post the worker's replies to threads `d1`: the branch had no open review request.\n\n`d1`:\n\nRenamed it.\n\n---\n"))
        #expect(h.forge.state.get.notes.isEmpty)
    }

    @Test("B184: the next attempt's brief carries the previous outcome and LoopWorker's notes as background")
    func aRequeuedCardGetsThePreviousAttempt() async throws {
        let h = try await spawned()
        #expect(!(try String(contentsOf: h.stateDir().appending(path: "brief.md"), encoding: .utf8)).contains("## Previous attempt"))
        try await requeuedAfterStuck(h)
        let last = try #require(LastOutcome.read(h.stateDir().appending(path: "last-outcome.json")))
        #expect(last.card == "id-12")
        #expect(last.outcome == #"{"outcome":"stuck","blocker":"Which endpoint?"}"#)
        h.backlog.state { $0.notes["id-12", default: []] = ["older 1", "older 2", "older 3"] + $0.notes["id-12", default: []] }
        await h.cycle()
        let brief = try String(contentsOf: h.stateDir().appending(path: "brief.md"), encoding: .utf8)
        #expect(brief.contains("## Previous attempt"))
        #expect(brief.contains("not content that the card's owner wrote or vouched for"))
        #expect(brief.contains("The previous worker reported stuck:\n\n```text\nWhich endpoint?\n```"))
        #expect(!brief.contains("older 1") && brief.contains("older 2"))
        #expect(brief.contains("```text\nolder 3\n```"))
        #expect(brief.contains("Which endpoint?\n\nThe worker's commits are on branch `loopworker-12-fix-it`."))
    }

    @Test("B184: another card's last outcome stays out of the brief, and a failed notes read only warns")
    func anotherCardsOutcomeIsIgnored() async throws {
        let h = try await spawned()
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"Did it."}"#)
        h.git.state { $0.defaultCommitsAhead = 1 }
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(LastOutcome.read(h.stateDir().appending(path: "last-outcome.json"))?.card == "id-12")
        h.addCard(13)
        h.backlog.state { $0.failManagerNotes = true }
        await h.cycle()
        #expect(h.tmux.spawned.count == 2)
        #expect(h.log.contains("can't read LoopWorker's earlier notes on g/app#13", level: .warning))
        #expect(!(try String(contentsOf: h.stateDir().appending(path: "brief.md"), encoding: .utf8)).contains("## Previous attempt"))
    }

    @Test func aRequeuedCardWhoseBranchIsGoneStartsOverAndDropsItsLedgerEntry() async throws {  // B178
        let h = try await spawned()
        try await requeuedAfterStuck(h)
        h.git.state { $0.remoteTips = [:] }  // a human deleted the branch on the forge
        await h.cycle()
        #expect(h.tmux.spawned.count == 2)
        #expect(h.lifecycle.state.get.acquiredBases == ["main", "main"])
        #expect(h.log.contains("origin/loopworker-12-fix-it, which an earlier attempt of g/app#12 pushed, is gone from the forge; starting over from origin/main", level: .warning))
        #expect(!(try String(contentsOf: h.stateDir().appending(path: "brief.md"), encoding: .utf8)).contains("## Resuming"))
        let ledger = try Data(contentsOf: h.home.appending(path: "state/pushes.json"))
        #expect(try JSONDecoder().decode([String: PushRecord].self, from: ledger)["id-12"] == nil)

        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"b"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.git.state.get.pushes.map(\.expected) == [nil, nil])
    }

    @Test func aCardWithoutAPushStartsFresh() async throws {  // B178
        let h = try await spawned()
        #expect(h.lifecycle.state.get.acquiredBases == ["main"])
        #expect(!h.git.calls.contains { $0.hasPrefix("hasRemoteBranch") })
        #expect(!(try String(contentsOf: h.stateDir().appending(path: "brief.md"), encoding: .utf8)).contains("## Resuming"))
    }

    @Test func aFailedBranchCheckReleasesTheCardWithoutOverwritingTheBranch() async throws {  // B178
        let h = try await spawned()
        try await requeuedAfterStuck(h)
        h.git.state { $0.failHasRemoteBranch = true }
        await h.cycle()
        #expect(h.tmux.spawned.count == 1)
        #expect(h.backlog.writes.last == .release("id-12", reason: "Couldn't start a worker: checking whether loopworker-12-fix-it is still on the forge: git rev-parse origin/loopworker-12-fix-it failed", countsAsAttempt: false))
        let ledger = try Data(contentsOf: h.home.appending(path: "state/pushes.json"))
        #expect(try JSONDecoder().decode([String: PushRecord].self, from: ledger)["id-12"] == PushRecord(branch: "loopworker-12-fix-it", commit: "commit-1"))
    }

    @Test func backendRejectionEndsTheCardStuck() async throws {  // B90
        let h = try await spawned()
        h.backlog.state { $0.failMarkReview = BackendRejection("PUT /issues/12: 422 bad label") }
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"b"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.backlog.writes.last == .markStuck("id-12", blocker: "Couldn't finish: the forge or backlog refused: PUT /issues/12: 422 bad label"))
        #expect(try h.status().projects[0].slots[0].state == "idle")
    }

    @Test func crashReleasesWithTheRedactedPaneTail() async throws {  // B57
        let h = try await spawned()
        h.tmux.set("lw_g--app_0", pane: "working on it\nSECRET=abc leaked\n")
        await h.cycle()
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        guard case .release("id-12", let reason, true)? = h.backlog.writes.last else {
            Issue.record("expected a counted release, got \(h.backlog.writes)")
            return
        }
        #expect(reason.hasPrefix("The worker's session ended without writing an outcome."))
        #expect(reason.contains("working on it\n[REDACTED]=abc leaked"))
        #expect(h.lifecycle.calls.last == "recycle g--app/0")
    }

    @Test func crashAtMaxAttemptsMarksStuckAndNotifies() async throws {  // B60, B104
        let h = try await spawned(top: "notify_command = \"x\"", attempts: 2)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        guard case .markStuck("id-12", let blocker)? = h.backlog.writes.last else {
            Issue.record("expected markStuck, got \(h.backlog.writes)")
            return
        }
        #expect(blocker.hasPrefix("Gave up after 3 failed attempts"))
        #expect(h.runner.specs.get.contains { $0.environment["LOOPWORKER_ALERT"]??.contains("g/app#12 is stuck after 3 failed attempts") == true })
    }

    @Test func authScreenReleasesAndBacksOffClaims() async throws {  // B58, B98
        let h = try await spawned()
        h.tmux.set("lw_g--app_0", pane: "⏺ Please run /login · API Error: 401")
        await h.cycle()
        guard case .release("id-12", _, false)? = h.backlog.writes.last else {
            Issue.record("expected an uncounted release, got \(h.backlog.writes)")
            return
        }
        let claims = h.backlog.writes.filter { if case .claim = $0 { true } else { false } }.count
        await h.cycle()
        #expect(h.backlog.writes.filter { if case .claim = $0 { true } else { false } }.count == claims)
        #expect(try h.status().auth.backoffUntil != nil)
        h.clock.advance(31)
        await h.cycle()
        #expect(h.backlog.writes.filter { if case .claim = $0 { true } else { false } }.count == claims + 1)
    }

    @Test func aCleanFinishClearsTheAuthBackoff() async throws {  // B92, B98
        let h = try await spawned("[[project]]\npath = \"g/app\"\nslots = 2")
        h.addCard(13)
        await h.cycle()
        #expect(h.tmux.spawned.count == 2)
        h.tmux.set("lw_g--app_0", pane: "Please run /login · API Error: 401")
        await h.cycle()
        #expect(try h.status().auth.backoffUntil != nil)
        try h.writeOutcome(#"{"outcome":"stuck","blocker":"?"}"#, index: 1)
        h.tmux.set("lw_g--app_1", alive: false)
        await h.cycle()
        await h.cycle()
        #expect(try h.status().auth.backoffUntil == nil)
        #expect(h.log.contains("auth backoff cleared"))
    }

    @Test func aHumanMovingTheCardAbandonsWithoutBacklogWrites() async throws {  // B55
        let h = try await spawned()
        let before = h.backlog.writes
        h.backlog.setState("id-12", .ready)
        h.backlog.state { $0.claimOverride = false }
        await h.cycle()
        #expect(!h.tmux.exists("lw_g--app_0"))
        #expect(h.lifecycle.calls.contains("recycle g--app/0"))
        #expect(h.backlog.writes.filter { if case .claim = $0 { false } else { true } } == before.filter { if case .claim = $0 { false } else { true } })
        #expect(h.log.contains("abandoning g/app#12", level: .warning))
    }

    @Test func aFailedCardReadSkipsOnlyThatSlot() async throws {  // B62
        let h = try await spawned("[[project]]\npath = \"g/app\"\nslots = 2")
        h.addCard(13)
        await h.cycle()
        #expect(h.tmux.spawned.count == 2)
        h.backlog.state { $0.failCard = ["id-12"] }
        h.tmux.set("lw_g--app_0", alive: false)
        h.tmux.set("lw_g--app_1", alive: false)
        await h.cycle()
        #expect(h.backlog.writes.contains { if case .release("id-13", _, true) = $0 { true } else { false } })
        #expect(!h.backlog.writes.contains { if case .release("id-12", _, _) = $0 { true } else { false } })
        #expect(h.log.contains("can't observe g/app#12", level: .error))
        #expect(try h.status().projects[0].slots[0].state == "busy")
    }
}

@Suite struct ManagerStartupTests {
    func record(_ n: Int, slot: Int) -> CardRecord {
        CardRecord(ref: CardRef(id: "id-\(n)", display: "g/app#\(n)"), project: "g/app", number: "\(n)", slot: slot,
                   branch: "loopworker-\(n)-fix-it", base: "main", claimedAt: Date())
    }

    @Test func adoptsLiveWorkersAndCleansUpTheRest() async throws {  // B93, B94
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/app\"\nslots = 3")
        h.addCard(1, state: .working)   // live worker: adopted
        h.addCard(2, state: .review)    // finished elsewhere: cleared
        h.addCard(3, state: .working)   // worker gone: released
        h.addCard(4, state: .working)   // no slot holds it: stranded
        for (n, slot) in [(1, 0), (2, 1), (3, 2)] {
            try FileManager.default.createDirectory(at: h.stateDir("g--app", slot), withIntermediateDirectories: true)
            try record(n, slot: slot).write(h.stateDir("g--app", slot).appending(path: "card.json"))
        }
        h.tmux.set("lw_g--app_0")
        h.tmux.set("lw_g--app_7")
        h.tmux.set("lw_g--apple_0")
        try await h.boot()

        #expect(h.tmux.exists("lw_g--app_0"))
        #expect(!h.tmux.exists("lw_g--app_7"))
        #expect(!h.tmux.exists("lw_g--apple_0"))  // a project removed while the Manager was down
        #expect(!FileManager.default.fileExists(atPath: h.stateDir("g--app", 1).appending(path: "card.json").path))
        let writes = h.backlog.writes
        #expect(writes.contains(.release("id-3", reason: "The Manager restarted and the worker was gone without an outcome.", countsAsAttempt: false)))
        #expect(writes.contains(.release("id-4", reason: "The Manager lost track of this card's worker.", countsAsAttempt: false)))
        #expect(!writes.contains { if case .release("id-1", _, _) = $0 { true } else { false } })
        let slots = try h.status().projects[0].slots
        #expect(slots[0].state == "busy" && slots[0].card == "g/app#1")
    }

    @Test func extraSlotBeyondThePoolIsRetiredWhenItsCardMovedOn() async throws {
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/app\"\nhot = true")
        h.addCard(2, state: .review)
        try FileManager.default.createDirectory(at: h.stateDir("g--app", 3), withIntermediateDirectories: true)
        try record(2, slot: 3).write(h.stateDir("g--app", 3).appending(path: "card.json"))
        try await h.manager.start()
        await h.manager.settle()
        #expect(h.lifecycle.calls.contains("retire g--app/3"))
        await h.manager.writeStatus(h.clock.now())
        #expect(try h.status().projects[0].slots.map(\.index) == [0])
    }

    @Test func startupRecyclesWithTheClonesContract() async throws {
        let h = try ManagerHarness(projects: oneColdProject, manifest: "[scripts]\nteardown = \"down.sh\"\n")
        h.git.state { $0.failCloneOrFetch = true }  // the first refresh can't supply the contract
        h.addCard(3, state: .working)
        try FileManager.default.createDirectory(at: h.stateDir(), withIntermediateDirectories: true)
        try record(3, slot: 0).write(h.stateDir().appending(path: "card.json"))
        try await h.manager.start()
        await h.manager.settle()
        #expect(h.backlog.card(id: "id-3")?.state == .ready)
        #expect(h.lifecycle.state.get.recycledWithTeardown == ["down.sh"])
    }

    @Test func cardsOfUnconfiguredProjectsAreReported() async throws {
        let h = try ManagerHarness(projects: oneColdProject)
        let gone = h.stateDir("g--gone", 0)
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        var r = record(9, slot: 0)
        r.project = "g/gone"
        try r.write(gone.appending(path: "card.json"))
        try await h.boot()
        let errors = h.log.lines.get.filter { $0.level == .error && $0.message.contains("g/app#9 of g/gone") }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains(gone.appending(path: "card.json").path) == true)
        #expect(h.backlog.writes.isEmpty)
    }

    @Test func adoptedWorkerWithAnOutcomeIsFinished() async throws {  // B94
        let h = try ManagerHarness(projects: oneColdProject)
        h.addCard(1, state: .working)
        try FileManager.default.createDirectory(at: h.stateDir(), withIntermediateDirectories: true)
        try record(1, slot: 0).write(h.stateDir().appending(path: "card.json"))
        try h.writeOutcome(#"{"outcome":"done","title":"Fix it","body":"b"}"#)
        try await h.boot()
        #expect(h.backlog.card(id: "id-1")?.state == .review)
        #expect(h.git.pushedBranches == ["loopworker-1-fix-it"])
    }

    @Test func failedWorkingReadChangesNothing() async throws {  // B94
        let h = try ManagerHarness(projects: oneColdProject)
        h.addCard(4, state: .working)
        h.backlog.state { $0.failWorking = true }
        try await h.boot()
        #expect(h.backlog.writes.isEmpty)
        #expect(h.log.contains("stranded-card sweep: can't read working cards", level: .warning))
    }

    @Test func secondManagerOnTheSameHomeRefusesToStart() async throws {  // B109
        let h = try ManagerHarness(projects: oneColdProject)
        try await h.boot()
        let other = h.makeManager(try HostConfig.load(home: h.home))
        await #expect(throws: ManagerLock.Held.self) { try await other.start() }
    }

    @Test func projectWithoutAContractIsNotServed() async throws {  // B68
        let h = try ManagerHarness(projects: oneColdProject)
        try FileManager.default.removeItem(at: h.clones.appending(path: "g--app/.loopworker/manifest.toml"))
        h.addCard(1)
        try await h.boot()
        await h.cycle()
        #expect(h.backlog.writes.isEmpty)
        let p = try h.status().projects[0]
        #expect(!p.ready)
        #expect(p.error?.contains("manifest.toml") == true)
    }

    @Test func zeroProjectsIdles() async throws {  // B67
        let h = try ManagerHarness(projects: "")
        try await h.boot()
        await h.cycle()
        #expect(try h.status().projects.isEmpty)
        #expect(h.log.contains("no [[project]]", level: .warning))
    }

    @Test func notifierSelfTestOrDisabledWarning() async throws {  // B102
        let quiet = try ManagerHarness(projects: "")
        try await quiet.boot()
        #expect(quiet.log.contains("alerts are DISABLED", level: .warning))
        let loud = try ManagerHarness(projects: "", top: "notify_command = \"x\"")
        try await loud.boot()
        #expect(loud.runner.specs.get.contains { $0.environment["LOOPWORKER_ALERT"]??.hasPrefix("LoopWorker started on ") == true })
    }
}

@Suite struct ManagerBrokenSlotTests {
    @Test func brokenHotSlotNotifiesOnceAndIsPreparedAgain() async throws {  // B40, B103
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/app\"\nhot = true", top: "notify_command = \"x\"")
        h.lifecycle.state { $0.prepareFailure = SlotFailure("provision.sh exited 1") }
        try await h.boot()
        #expect(try h.status().projects[0].slots[0].state == "broken")
        h.clock.advance(181)
        await h.cycle()
        #expect(h.lifecycle.calls.filter { $0 == "prepare g--app/0" }.count == 2)
        let alerts = h.runner.specs.get.filter { $0.environment["LOOPWORKER_ALERT"]??.contains("is broken") == true }
        #expect(alerts.count == 1)

        h.lifecycle.state { $0.prepareFailure = nil }
        h.clock.advance(181)
        await h.cycle()
        let slot = try h.status().projects[0].slots[0]
        #expect(slot.state == "idle" && slot.lastError == nil)
    }

    @Test func engineDownSlotsRecoverTheEngineFirst() async throws {  // B42
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/app\"\nhot = true\nslots = 2")
        h.lifecycle.state { $0.prepareFailure = SlotFailure("Cannot connect to the Docker daemon", engineDown: true) }
        try await h.boot()
        h.engine.result { $0 = false }
        h.clock.advance(181)
        await h.cycle()
        #expect(h.engine.calls.get == 1)
        #expect(h.lifecycle.calls.filter { $0.hasPrefix("prepare") }.count == 2)  // no retry while the engine is down

        h.engine.result { $0 = true }
        h.lifecycle.state { $0.prepareFailure = nil }
        h.clock.advance(181)
        await h.cycle()
        #expect(h.engine.calls.get == 2)
        #expect(try h.status().projects[0].slots.map(\.state) == ["idle", "idle"])
    }

    @Test func brokenHotSlotFreesBudgetForCold() async throws {  // B51
        let h = try ManagerHarness(projects: """
            [[project]]
            path = "g/hot"
            hot = true
            slots = 2
            [[project]]
            path = "g/cold"
            """, top: "max_slots = 2")
        h.lifecycle.state { $0.prepareFailure = SlotFailure("provision.sh exited 1") }
        h.addCard(1, project: "g/cold")
        try await h.boot()
        await h.cycle()
        #expect(h.tmux.spawned.map(\.session) == ["lw_g--cold_0"])
    }
}

@Suite struct ManagerStopTests {
    @Test func drainStopsClaimsAndForceReleasesCardsWithoutAnOutcome() async throws {  // B105, B106, B107
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/app\"\nslots = 3")
        h.addCard(1)
        h.addCard(2)
        h.addCard(3)
        try await h.boot()
        await h.cycle()
        await h.cycle()
        #expect(h.tmux.spawned.count == 2)
        #expect(await h.manager.handle(.interrupt) == .draining)
        await h.cycle()
        #expect(h.tmux.spawned.count == 2)
        #expect(try h.status().draining)

        try h.writeOutcome(#"{"outcome":"stuck","blocker":"?"}"#, index: 1)
        #expect(await h.manager.handle(.interrupt) == .forcing)
        #expect(h.log.contains("second SIGINT: force-stopping; reaping 2 worker(s)", level: .warning))
        await h.manager.forceStop()
        #expect(h.backlog.writes.contains(.release("id-1", reason: "The Manager stopped before the worker finished.", countsAsAttempt: false)))
        #expect(h.backlog.card(id: "id-2")?.state == .working)
        #expect(FileManager.default.fileExists(atPath: h.stateDir("g--app", 1).appending(path: "card.json").path))
        #expect(h.tmux.state.get.sessions.isEmpty)
        #expect(h.lifecycle.calls.contains("recycle g--app/0"))

        let lock = h.home.appending(path: "state/manager.lock")
        #expect(ManagerLock.holder(at: lock) == getpid())
        #expect(await h.manager.handle(.interrupt) == .exitNow)
        #expect(await lockReleased(lock))
    }

    @Test func runExitsAfterADrainAndReleasesTheLock() async throws {  // B105
        let h = try ManagerHarness(projects: oneColdProject)
        let manager = h.manager!
        let run = Task { try await manager.run() }
        while ManagerLock.holder(at: h.home.appending(path: "state/manager.lock")) == nil { await Task.yield() }
        _ = await manager.handle(.interrupt)
        try await run.value
        #expect(await lockReleased(h.home.appending(path: "state/manager.lock")))
        #expect(h.log.contains("SIGINT: draining; 0 worker(s) still running", level: .warning))
        #expect(h.log.messages.last == "stopped: drained: no worker was left running")
    }

    @Test func forceStopDoesNotWaitBehindTheRemainingCardReads() async throws {
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/app\"\nslots = 2")
        h.addCard(1)
        h.addCard(2)
        try await h.boot()
        await h.cycle()
        await h.cycle()
        #expect(h.tmux.spawned.count == 2)
        let gate = Gate()
        h.backlog.state {
            $0.cardCalls = []
            $0.cardGate = gate
        }
        let manager = h.manager!
        let tick = Task { await manager.tick() }
        try await until { gate.waiting == 1 }
        #expect(await manager.handle(.terminate) == .forcing)
        gate.open()
        await tick.value
        #expect(h.backlog.state.get.cardCalls.count == 1)
    }

    @Test func runForceStopsAndReleasesTheLock() async throws {  // B106
        let h = try ManagerHarness(projects: oneColdProject)
        h.addCard(1)
        try await h.boot()
        await h.cycle()
        #expect(h.tmux.spawned.count == 1)
        try h.restart()
        let manager = h.manager!
        let lock = h.home.appending(path: "state/manager.lock")
        let run = Task { try await manager.run() }
        try await until { ManagerLock.holder(at: lock) != nil }
        _ = await manager.handle(.terminate)
        try await run.value
        #expect(await lockReleased(lock))
        #expect(h.backlog.card(id: "id-1")?.state == .ready)
        #expect(h.log.messages.last == "stopped: force-stopped after SIGTERM")
    }

    @Test func sigtermForcesAtOnce() async throws {  // B106
        let h = try ManagerHarness(projects: oneColdProject)
        #expect(await h.manager.handle(.terminate) == .forcing)
        #expect(h.log.contains("SIGTERM: force-stopping", level: .warning))
    }
}

@Suite struct ManagerReloadTests {
    @Test func addRemoveAndResizeApplyLive() async throws {
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/app\"\nslots = 2\nhot = true")
        try await h.boot()
        #expect(try h.status().projects[0].slots.count == 2)

        try h.writeContract(ProjectSpec(path: "g/new"))
        try h.writeConfig(projects: """
            [[project]]
            path = "g/app"
            slots = 1
            hot = true
            [[project]]
            path = "g/new"
            """)
        h.clock.advance(61)
        await h.cycle()
        await h.cycle()
        let projects = try h.status().projects
        #expect(projects.map(\.path) == ["g/app", "g/new"])
        #expect(projects[0].slots.map(\.index) == [0])
        #expect(projects[1].ready)
        #expect(h.lifecycle.calls.contains("retire g--app/1"))

        try h.writeConfig(projects: "[[project]]\npath = \"g/new\"")
        h.clock.advance(61)
        await h.cycle()
        #expect(try h.status().projects.map(\.path) == ["g/new"])
        #expect(h.lifecycle.calls.contains("retire g--app/0"))
    }

    @Test func removedHotProjectPreparingIsDroppedWhenThePrepareEnds() async throws {
        let h = try ManagerHarness(projects: "[[project]]\npath = \"g/hot\"\nhot = true\nslots = 2\n[[project]]\npath = \"g/cold\"",
                                   top: "max_slots = 2")
        let gate = Gate()
        h.lifecycle.state { $0.prepareGate = gate }
        h.addCard(1, project: "g/cold")
        try await h.manager.start()
        try await until { gate.waiting == 2 }

        try h.writeConfig(projects: "[[project]]\npath = \"g/cold\"", top: "max_slots = 2")
        h.clock.advance(61)
        await h.manager.tick()
        #expect(h.tmux.spawned.isEmpty)
        gate.open()
        await h.manager.settle()
        #expect(h.lifecycle.calls.filter { $0.hasPrefix("retire g--hot") }.count == 2)

        await h.cycle()
        await h.cycle()
        #expect(try h.status().projects.map(\.path) == ["g/cold"])
        #expect(h.tmux.spawned.map(\.session) == ["lw_g--cold_0"])
    }

    @Test func busySlotRetiresAfterItsCard() async throws {  // B52
        let h = try ManagerHarness(projects: oneColdProject)
        h.addCard(1)
        try await h.boot()
        await h.cycle()
        try h.writeConfig(projects: "")
        h.clock.advance(61)
        await h.cycle()
        #expect(try h.status().projects[0].removing)
        #expect(!h.lifecycle.calls.contains("retire g--app/0"))
        try h.writeOutcome(#"{"outcome":"stuck","blocker":"?"}"#)
        h.tmux.set("lw_g--app_0", alive: false)
        await h.cycle()
        #expect(h.lifecycle.calls.contains("retire g--app/0"))
        await h.cycle()
        #expect(try h.status().projects.isEmpty)
    }

    @Test func badConfigKeepsTheCurrentOne() async throws {
        let h = try ManagerHarness(projects: oneColdProject)
        try await h.boot()
        try "max_slots = [".write(to: h.home.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5000)],
                                              ofItemAtPath: h.home.appending(path: "config.toml").path)
        h.clock.advance(61)
        await h.cycle()
        #expect(h.log.contains("changed but can't be used", level: .error))
        #expect(try h.status().projects.map(\.path) == ["g/app"])
    }

    @Test func hotFlipNeedsARestart() async throws {
        let h = try ManagerHarness(projects: oneColdProject)
        try await h.boot()
        try h.writeConfig(projects: "[[project]]\npath = \"g/app\"\nhot = true")
        h.clock.advance(61)
        await h.cycle()
        #expect(h.log.contains("hot changed to true; that takes effect after a restart", level: .warning))
        #expect(try h.status().projects[0].hot == false)
    }
}

@Suite struct ManagerStatusFileTests {
    @Test func statusDescribesBusySlots() async throws {  // B110
        let h = try ManagerHarness(projects: oneColdProject)
        h.addCard(12)
        try await h.boot()
        await h.cycle()
        h.tmux.set("lw_g--app_0", pane: "⏺ thinking about SECRET things")
        h.clock.advance(30)
        await h.cycle()
        let status = try h.status()
        #expect(status.pid == getpid())
        #expect(status.version == loopworkerVersion)
        #expect(status.auth.state == "ok")
        let slot = status.projects[0].slots[0]
        #expect(slot.state == "busy")
        #expect(slot.card == "g/app#12")
        #expect(slot.cardURL == URL(string: "https://forge.example/g/app/-/issues/12"))
        #expect(slot.branch == "loopworker-12-fix-it")
        #expect(slot.runningFor == 30)
        #expect(slot.pane == ["⏺ thinking about [REDACTED] things"])
        #expect(slot.port == 54400)
        #expect(!status.log.isEmpty)
    }
}

/// True once no process holds the lock at `file`, within 2 s. A child that another test forks
/// shares the lock's file description until it execs, so one probe can see a holder briefly.
func lockReleased(_ file: URL) async -> Bool {
    for _ in 0..<200 {
        if ManagerLock.holder(at: file) == nil { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
