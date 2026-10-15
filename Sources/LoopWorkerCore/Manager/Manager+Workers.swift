import Foundation

/// What `card.json` in a slot's state directory records: the card a slot holds, so a
/// restarted Manager can adopt the worker.
struct CardRecord: Codable, Equatable {
    var ref: CardRef
    var project: String
    var number: String?
    var slot: Int
    var branch: String
    var base: String
    var claimedAt: Date
    /// Set for a CI fix round: its number, from 1.
    var ciRound: Int? = nil
    /// Set for a CI fix round: the pushed commit whose pipeline failed.
    var ciCommit: String? = nil

    static func read(_ file: URL) -> CardRecord? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(CardRecord.self, from: data)
    }

    func write(_ file: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: file, options: .atomic)
    }
}

/// `last-outcome.json` in a slot's state directory: the outcome of the slot's last finished
/// card, which the card's next attempt gets as background.
struct LastOutcome: Codable, Equatable {
    static let fileName = "last-outcome.json"
    /// `CardRef.id`.
    var card: String
    var finishedAt: Date
    /// The outcome file as the worker wrote it.
    var outcome: String

    static func read(_ file: URL) -> LastOutcome? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(LastOutcome.self, from: data)
    }

    func write(_ file: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: file, options: .atomic)
    }
}

/// The last commit the Manager pushed for a card, in `state/pushes.json` keyed by card id. It
/// outlives the slot's `card.json`, so a card claimed again leases against its own last push.
struct PushRecord: Codable, Equatable {
    var branch: String
    var commit: String
}

/// A start or finish step failed; `step` says which, for the log.
struct StepError: Error, CustomStringConvertible {
    var step: String
    var error: any Error
    var description: String { "\(step): \(error)" }
}

extension Manager {
    // MARK: Fill

    func fill(_ now: Date) async {
        guard !draining, !forceRequested, !hostPaused, authGate.allowsDispatch(at: now),
              busyCount < config.maxConcurrentWorkers else { return }

        var remaining = config.maxSlots
        for p in projects.values {
            for s in p.slots where p.spec.hot ? s.phase != .broken : s.phase == .busy {
                remaining -= p.spec.weight
            }
        }
        var candidates: [(key: String, slot: UUID)] = []
        for key in order.filter({ projects[$0]?.spec.hot == true }) + order.filter({ projects[$0]?.spec.hot == false }) {
            guard let p = projects[key], p.ready, !p.removing, !projectPaused(key) else { continue }
            if !p.spec.hot && Budget.affordable(remaining: remaining, weight: p.spec.weight) < 1 { continue }
            if let free = p.slots.first(where: isFree) { candidates.append((key, free.id)) }
        }
        guard !candidates.isEmpty else { return }

        // A queued fix round finishes a card already in flight, so it goes before new claims.
        for c in candidates {
            guard let id = queuedFix(for: c.key, at: now), let slot = projects[c.key]?.slots.first(where: { $0.id == c.slot }), isFree(slot) else { continue }
            startFixRound(id, on: SlotRef(key: c.key, id: c.slot))
            return
        }

        lastFill = now
        fillSoon = false
        let cards: [Card]
        do { cards = try await deps.backlog.workable(in: candidates.compactMap { projects[$0.key]?.spec }) }
        catch {
            log.error("can't read workable cards: \(error); claiming nothing this tick")
            return
        }
        let keys = Set(candidates.compactMap { projects[$0.key]?.spec.path.lowercased() })
        for card in cards where !keys.contains(card.project.lowercased()) {
            log.error("the backlog returned \(card.ref) for project \(card.project), which wasn't asked for; not claiming it")
        }
        for c in candidates {
            guard let p = projects[c.key], !draining, !forceRequested,
                  let card = cards.first(where: { $0.project.lowercased() == p.spec.path.lowercased() }),
                  let slot = p.slots.first(where: { $0.id == c.slot }), isFree(slot) else { continue }
            startWorker(card, on: SlotRef(key: c.key, id: c.slot))
            return
        }
    }

    func isFree(_ s: Slot) -> Bool { s.phase == .idle && s.task == nil && !s.retiring && s.prepared }

    // MARK: Claim, acquire, spawn

    func startWorker(_ card: Card, on ref: SlotRef) {
        guard let p = projects[ref.key], let contract = p.contract, let base = p.base else { return }
        let branch = BranchName.make(template: contract.branchTemplate, card: card)
        update(ref) {
            $0.phase = .busy
            $0.task = .starting
            $0.card = card
            $0.branch = branch
            $0.base = base
            $0.ciRound = nil
            $0.ciCommit = nil
            $0.spawnedAt = nil
            $0.pane = []
            $0.finishFailures = 0
            $0.finishRetryAt = nil
            $0.finishError = nil
        }
        fillSoon = true
        track { await self.startTask(ref, card: card, contract: contract, base: base, branch: branch) }
    }

    /// Claims the card (or, for a fix round, moves it back to working), acquires the slot and
    /// spawns the worker.
    func startTask(_ ref: SlotRef, card: Card, contract: ProjectContract, base: String, branch: String, fix queued: FixRound? = nil) async {
        guard let spec = slot(ref)?.spec else { return }
        var fix = queued
        if let queued {
            guard let current = await recheckPipeline(queued, card: card) else {
                free(ref)
                return
            }
            fix = current
        }
        let fm = FileManager.default
        let dir = spec.stateDir
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["outcome.json", "card.md", "brief.md", "launch.sh", "mcp.json", "worker.env", "guide.html", "ci.md"] {
                try? fm.removeItem(at: dir.appending(path: name))
            }
            try CardRecord(ref: card.ref, project: spec.project.path, number: card.number, slot: spec.index,
                           branch: branch, base: base, claimedAt: clock.now(),
                           ciRound: fix.map { $0.record.round + 1 }, ciCommit: fix?.record.sha).write(cardRecordFile(spec))
        } catch {
            if fix != nil { fixStartFailed(card.ref.id, "can't write \(dir.path): \(error)") }
            else { log.error("\(label(spec)): can't write \(dir.path): \(error); not claiming \(card.ref)") }
            free(ref)
            return
        }

        if let fix {
            guard await resumeForFix(spec, card: card, fix: fix) else {
                try? fm.removeItem(at: cardRecordFile(spec))
                free(ref)
                return
            }
            await acquireAndSpawn(ref, spec: spec, card: card, contract: contract, base: base, branch: branch, fix: fix)
            return
        }

        var claimed: Bool
        do { claimed = try await deps.backlog.claim(card) }
        catch {
            // A lost response may hide a claim that landed; the card then reads as working.
            if let current = try? await deps.backlog.card(card.ref), current.state == .working {
                log.warning("\(label(spec)): claiming \(card.ref) reported \(error), but the card is working now; keeping it")
                claimed = true
            } else {
                log.error("\(label(spec)): claiming \(card.ref) failed: \(error); the stranded-card sweep releases it if the claim landed")
                try? fm.removeItem(at: cardRecordFile(spec))
                free(ref)
                return
            }
        }
        guard claimed else {
            log.info("\(label(spec)): \(card.ref) was no longer ready; skipping it")
            try? fm.removeItem(at: cardRecordFile(spec))
            free(ref)
            return
        }

        let resuming: Bool
        do { resuming = try await resumesPushedBranch(spec, card: card, base: base, branch: branch) }
        catch {
            await abortStart(ref, card: card, contract: contract, why: "\(error)", broken: nil)
            return
        }
        await acquireAndSpawn(ref, spec: spec, card: card, contract: contract, base: base, branch: branch, fix: nil, resuming: resuming)
    }

    /// True when an earlier attempt of this card pushed `branch` and it is still on the forge,
    /// so the worker continues from it instead of overwriting it. When the push ledger names
    /// the branch but the forge no longer has it, drops the ledger entry so the fresh start's
    /// push expects no branch.
    func resumesPushedBranch(_ spec: SlotSpec, card: Card, base: String, branch: String) async throws -> Bool {
        var pushes = readPushes()
        guard let pushed = pushes[card.ref.id], pushed.branch == branch else { return false }
        let exists = try await step("checking whether \(branch) is still on the forge") {
            try await self.deps.git.cloneOrFetch(url: self.deps.forge.cloneURL(for: spec.project), into: spec.clone,
                                                 environment: self.deps.forge.gitEnvironment())
            return try await self.deps.git.hasRemoteBranch(spec.clone, branch: branch)
        }
        if exists {
            log.info("\(label(spec)): resuming \(card.ref) from origin/\(branch), which an earlier attempt pushed at \(pushed.commit.prefix(12))")
            return true
        }
        pushes[card.ref.id] = nil
        do { try writePushes(pushes) }
        catch { throw StepError(step: "dropping \(card.ref)'s entry from \(pushLedger.path)", error: error) }
        log.warning("\(label(spec)): origin/\(branch), which an earlier attempt of \(card.ref) pushed, is gone from the forge; starting over from origin/\(base)")
        return false
    }

    /// A fix round or a resumed card resets the slot to the pushed card branch instead of the
    /// base branch.
    func acquireAndSpawn(_ ref: SlotRef, spec: SlotSpec, card: Card, contract: ProjectContract, base: String, branch: String,
                         fix: FixRound?, resuming: Bool = false) async {
        let dir = spec.stateDir
        let baseCommit: String
        do { baseCommit = try await deps.lifecycle.acquire(spec, contract: contract, base: fix == nil && !resuming ? base : branch, branch: branch) }
        catch {
            await abortStart(ref, card: card, contract: contract, why: "preparing the slot failed: \(error)", broken: error, fix: fix)
            return
        }

        do {
            try await writeWorkerFiles(spec, card: card, contract: contract, base: base, branch: branch, fix: fix, resuming: resuming)
        } catch {
            await abortStart(ref, card: card, contract: contract, why: "\(error)", broken: nil, fix: fix)
            return
        }
        do { try await deps.tmux.spawn(session: spec.session, directory: spec.worktree, script: dir.appending(path: "launch.sh")) }
        catch {
            await abortStart(ref, card: card, contract: contract, why: "starting the tmux session failed: \(error)",
                             broken: SlotFailure("tmux spawn failed: \(error)"), fix: fix)
            return
        }

        let model = card.model ?? spec.project.model
        update(ref) {
            $0.task = nil
            $0.spawnedAt = clock.now()
        }
        if fix != nil { unwatch(card.ref.id) }
        let round = fix.map { " for CI fix round \($0.record.round + 1)" } ?? (resuming ? " resuming its pushed branch" : "")
        log.info("\(label(spec)): spawned worker\(round) for \(card.ref) on \(branch) at \(baseCommit.prefix(12)), base \(base), model \(model ?? "default")")
        watchFolderTrust(spec.session)
    }

    func writeWorkerFiles(_ spec: SlotSpec, card: Card, contract: ProjectContract, base: String, branch: String,
                          fix: FixRound? = nil, resuming: Bool = false) async throws {
        let dir = spec.stateDir
        let snapshot: CardSnapshot
        do { snapshot = try await deps.backlog.snapshot(card) }
        catch { throw StepError(step: "reading the card's snapshot", error: error) }
        for line in snapshot.excluded { log.info("\(label(spec)): withheld from \(card.ref): \(line)") }
        var markdown = snapshot.markdown
        if !snapshot.excluded.isEmpty {
            markdown += "\n\n## Withheld\n\n" + snapshot.excluded.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        let snapshotFile = dir.appending(path: "card.md")
        let ciFile = dir.appending(path: "ci.md")
        let ciFix = fix.map {
            WorkerBrief.CIFix(review: $0.record.review, commit: $0.record.sha, ciFile: ciFile,
                              round: $0.record.round + 1, rounds: contract.ci.fixAttempts)
        }
        let brief = WorkerBrief(card: card, project: spec.project, slot: spec, baseBranch: base, branch: branch,
                                snapshotFile: snapshotFile, excluded: snapshot.excluded, contract: contract, ciFix: ciFix,
                                resuming: resuming, previousAttempt: await previousAttempt(spec, card: card)).render()

        var env: [(name: String, value: String)] = []
        for name in ["CLAUDE_CODE_OAUTH_TOKEN"] + spec.project.workerEnv where !env.contains(where: { $0.name == name }) {
            if let value = deps.environment[name] { env.append((name, value)) }
            else if name != "CLAUDE_CODE_OAUTH_TOKEN" {
                log.warning("\(label(spec)): worker_env names \(name), which is set neither in the environment nor in secrets.env")
            }
        }

        let mcp: Data
        if let file = contract.mcpConfig {
            let source = contract.directory.appending(path: file)
            do { mcp = try Data(contentsOf: source) }
            catch { throw StepError(step: "reading the contract's MCP config \(source.path)", error: error) }
        } else {
            mcp = Data(WorkerLaunch.emptyMCPConfig.utf8)
        }

        let fm = FileManager.default
        do {
            try Data(markdown.utf8).write(to: snapshotFile)
            if let fix { try Data(ciReport(fix, card: card).utf8).write(to: ciFile) }
            try Data(brief.utf8).write(to: dir.appending(path: "brief.md"))
            try mcp.write(to: dir.appending(path: "mcp.json"))
            let envFile = dir.appending(path: "worker.env")
            guard fm.createFile(atPath: envFile.path, contents: Data(WorkerLaunch.environmentFile(env).utf8),
                                attributes: [.posixPermissions: 0o600]) else {
                throw ConfigError("can't create \(envFile.path)")
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
            let launch = dir.appending(path: "launch.sh")
            let script = WorkerLaunch.script(worktree: spec.worktree, stateDir: dir, port: spec.port,
                                             model: card.model ?? spec.project.model)
            try Data(script.utf8).write(to: launch)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launch.path)
        } catch {
            throw StepError(step: "writing the worker's files in \(dir.path)", error: error)
        }
    }

    /// The newest outcome that any of the project's slots kept for this card, and the
    /// Manager's notes on it; nil when there is neither. A failed notes read is logged and
    /// leaves the notes out: they are background, not worth failing the start for.
    func previousAttempt(_ spec: SlotSpec, card: Card) async -> WorkerBrief.PreviousAttempt? {
        var notes: [String] = []
        do { notes = try await deps.backlog.managerNotes(card) }
        catch { log.warning("\(label(spec)): can't read LoopWorker's earlier notes on \(card.ref): \(error); the worker starts without them") }
        let slotDirs = (try? FileManager.default.contentsOfDirectory(at: spec.stateDir.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        let last = slotDirs.compactMap { LastOutcome.read($0.appending(path: LastOutcome.fileName)) }
            .filter { $0.card == card.ref.id }
            .max { $0.finishedAt < $1.finishedAt }
        let previous = WorkerBrief.PreviousAttempt(outcome: last.map { Outcome.parse(Data($0.outcome.utf8)) }, notes: notes, redact: deps.redact)
        return previous.outcome == nil && previous.notes.isEmpty ? nil : previous
    }

    /// A start failed after the claim: release the card (not counted against it: the host
    /// failed), or for a fix round return it to `verifying`, mark the slot broken when
    /// `broken` is set, and recycle it.
    func abortStart(_ ref: SlotRef, card: Card, contract: ProjectContract, why: String, broken: (any Error)?, fix: FixRound? = nil) async {
        guard let spec = slot(ref)?.spec else { return }
        log.error("\(label(spec)): couldn't start a worker for \(card.ref): \(why)")
        if let fix {
            await returnToVerifying(card, fix, why: why)
        } else {
            do {
                try await deps.backlog.release(card, reason: "Couldn't start a worker: \(why)", countsAsAttempt: false)
            } catch {
                log.error("\(label(spec)): can't release \(card.ref): \(error); the stranded-card sweep retries")
            }
        }
        if broken != nil || !spec.project.hot { await deps.lifecycle.recycle(spec, contract: contract) }
        try? FileManager.default.removeItem(at: cardRecordFile(spec))
        if let broken { markBroken(ref, broken as? SlotFailure ?? SlotFailure("\(broken)")) }
        free(ref)
    }

    /// Accepts claude's folder-trust dialog, which a fresh worktree shows once and which
    /// would otherwise hang the unattended worker.
    func watchFolderTrust(_ session: String) {
        let tmux = deps.tmux, clock = self.clock, log = self.log, trustPromptKeys = deps.pane.trustPromptKeys
        track {
            for _ in 0..<15 {
                try? await clock.sleep(seconds: 2)
                if Task.isCancelled { return }
                guard let pane = try? await tmux.capture(session, lines: 40) else { return }
                guard let keys = trustPromptKeys(pane) else { continue }
                guard !keys.isEmpty else {
                    log.warning("\(session): claude shows a folder-trust dialog without a recognizable Yes option; leaving it for a human (tmux -S <home>/state/tmux attach -t \(session))")
                    return
                }
                do {
                    try await tmux.sendKeys(session, keys)
                    log.info("\(session): accepted claude's folder-trust dialog (\(keys.joined(separator: " ")))")
                } catch {
                    log.warning("\(session): couldn't answer claude's folder-trust dialog: \(error)")
                }
                return
            }
        }
    }

    /// Returns a slot to idle and lets fill use it again, or retires it when a shrink or a
    /// project removal is waiting for it.
    func free(_ ref: SlotRef) {
        update(ref) {
            $0.phase = $0.phase == .broken ? .broken : .idle
            $0.task = nil
            $0.card = nil
            $0.branch = nil
            $0.base = nil
            $0.ciRound = nil
            $0.ciCommit = nil
            $0.spawnedAt = nil
            $0.finishFailures = 0
            $0.finishRetryAt = nil
            $0.finishError = nil
        }
        fillSoon = true
        retireIfDue(ref)
    }

    func markBroken(_ ref: SlotRef, _ failure: SlotFailure) {
        let now = clock.now()
        var wasBroken = false
        var spec: SlotSpec?
        update(ref) {
            wasBroken = $0.phase == .broken
            $0.phase = .broken
            $0.task = nil
            $0.prepared = !$0.spec.project.hot
            $0.lastError = failure.description
            $0.lastAttemptFinished = now
            $0.engineDown = failure.engineDown
            spec = $0.spec
        }
        guard let spec else { return }
        log.error("\(label(spec)) is broken: \(failure.description); retrying in \(Int(Self.reviveAfter)) s")
        if !wasBroken {
            notify(key: "slot-broken-\(ref.id)", "LoopWorker: \(label(spec)) on \(hostName) is broken: \(failure.description.prefix(300))")
        }
        if let p = projects[ref.key], !p.slots.contains(where: { $0.phase != .broken && !$0.retiring }) {
            log.warning("\(p.spec.path) has no healthy slot; it claims nothing until one recovers")
        }
    }

    // MARK: Reconcile

    func reconcileBusySlots(_ now: Date) async {
        let refs = order.flatMap { key in
            (projects[key]?.slots ?? []).filter { $0.phase == .busy && $0.task == nil && $0.card != nil }
                .map { SlotRef(key: key, id: $0.id) }
        }
        // A force stop must not wait behind one slow backlog read per remaining slot.
        for ref in refs where !forceRequested { await reconcile(ref, now) }
    }

    func reconcile(_ ref: SlotRef, _ now: Date) async {
        guard let s = slot(ref), let card = s.card else { return }
        let spec = s.spec
        let alive: Bool
        let fresh: Card?
        var pane = ""
        do {
            alive = try await deps.tmux.isAlive(spec.session)
            // A dead pane is kept (remain-on-exit), so its last screen explains a crash.
            pane = (try? await deps.tmux.capture(spec.session, lines: 40)) ?? ""
            fresh = try await deps.backlog.card(card.ref)
        } catch {
            log.error("\(label(spec)): can't observe \(card.ref): \(error); trying again next tick")
            return
        }
        guard let current = slot(ref), current.phase == .busy, current.task == nil, current.card?.ref == card.ref else { return }
        let outcomeAge = modificationDate(spec.outcomeFile).map { now.timeIntervalSince($0) }
        let lines = PaneReading.tail(pane, 15).map(deps.redact)
        update(ref) {
            if let fresh { $0.card = fresh }
            if !lines.isEmpty { $0.pane = lines }
        }
        let cap = (projects[ref.key]?.contract?.wallclockCapMinutes ?? 90) * 60
        let observation = SlotObservation(
            cardState: fresh?.state, sessionAlive: alive, authFailed: deps.pane.showsAuthFailure(pane),
            outcomeAge: outcomeAge, runningFor: current.spawnedAt.map { now.timeIntervalSince($0) } ?? 0)
        let decision = Reconciler.decide(observation, policy: ReconcilePolicy(wallclockCap: cap))
        let target = fresh ?? card

        switch decision {
        case .keep:
            return
        case .finish:
            if let retry = current.finishRetryAt, retry > now { return }
            await reap(spec)
            update(ref) { $0.task = .finishing }
            track { await self.finishTask(ref, card: target) }
        case .abandon(let why):
            log.warning("\(label(spec)): abandoning \(card.ref): \(why); reaping the worker without writing to the backlog")
            await reap(spec)
            update(ref) { $0.task = .recycling }
            track { await self.recycle(ref, keepOutcome: false) }
        case .release(let reason):
            await reap(spec)
            if reason == .auth {
                authReleasedThisTick = true
                let delay = authGate.noteAuthRelease(at: now)
                log.error("\(label(spec)): the worker hit claude's login screen; pausing new claims for \(Int(delay)) s")
                notify(key: "auth-release", "LoopWorker: a worker on \(hostName) hit claude's login screen; new claims paused \(Int(delay)) s")
            }
            let tail = lines.isEmpty ? s.pane : lines  // the session may be gone entirely; use the last capture
            if reason == .crashed, !tail.isEmpty {
                log.warning("\(label(spec)): last lines of \(spec.session) before it ended:\n\(tail.joined(separator: "\n"))")
            }
            update(ref) { $0.task = .releasing }
            track { await self.releaseTask(ref, card: target, reason: reason, pane: tail, cap: cap) }
        }
    }

    func reap(_ spec: SlotSpec) async {
        do { try await deps.tmux.kill(spec.session) }
        catch { log.error("\(label(spec)): can't reap \(spec.session): \(error)") }
    }

    func releaseTask(_ ref: SlotRef, card: Card, reason: ReleaseReason, pane: [String], cap: TimeInterval) async {
        guard let spec = slot(ref)?.spec else { return }
        let why: String
        switch reason {
        case .crashed: why = "the worker's session ended without writing an outcome"
        case .hung: why = "the worker ran longer than the \(Int(cap / 60))-minute cap"
        case .auth: why = "the worker hit claude's login screen on \(hostName)"
        }
        let terminal = pane.isEmpty ? "" : "\n\nLast lines of the worker's terminal:\n\n```\n\(pane.joined(separator: "\n"))\n```"
        let attempt = card.attempts + 1
        do {
            if reason.countsAsAttempt && attempt >= config.maxAttempts {
                try await deps.backlog.markStuck(card, blocker: "Gave up after \(attempt) failed attempts (max_attempts is \(config.maxAttempts)). The last one: \(why). The earlier attempts' reasons are in the release notes on this card.\(terminal)")
                log.warning("\(label(spec)): marked \(card.ref) stuck after \(attempt) failed attempts; last: \(why)")
                notify(key: "stuck-\(card.ref.id)", "LoopWorker: \(card.ref) is stuck after \(attempt) failed attempts; last: \(why)")
            } else {
                try await deps.backlog.release(card, reason: "\(why.prefix(1).uppercased() + why.dropFirst()).\(terminal)", countsAsAttempt: reason.countsAsAttempt)
                log.warning("\(label(spec)): released \(card.ref): \(why)")
            }
        } catch {
            log.error("\(label(spec)): can't release \(card.ref): \(error); the stranded-card sweep retries")
        }
        await recycle(ref, keepOutcome: false)
    }

    /// Recycles the slot's stack, clears its card files and frees it (or retires it).
    /// `keepOutcome` saves the outcome as `last-outcome.json`, tagged with the card.
    func recycle(_ ref: SlotRef, keepOutcome: Bool) async {
        guard let s = slot(ref), let p = projects[ref.key] else { return }
        let contract = p.contract ?? ProjectContract(directory: ProjectContract.directory(for: p.spec, clone: p.clone))
        await deps.lifecycle.recycle(s.spec, contract: contract)
        let fm = FileManager.default
        let outcome = s.spec.outcomeFile
        if keepOutcome, let card = s.card, let data = try? Data(contentsOf: outcome) {
            let last = s.spec.stateDir.appending(path: LastOutcome.fileName)
            do { try LastOutcome(card: card.ref.id, finishedAt: clock.now(), outcome: String(decoding: data, as: UTF8.self)).write(last) }
            catch { log.warning("\(label(s.spec)): can't write \(last.path): \(error); \(card.ref)'s next attempt won't see this outcome") }
        }
        try? fm.removeItem(at: outcome)
        try? fm.removeItem(at: cardRecordFile(s.spec))
        free(ref)
    }

    // MARK: Finish

    func finishTask(_ ref: SlotRef, card: Card) async {
        guard let s = slot(ref), let branch = s.branch, let base = s.base else { return }
        let spec = s.spec
        guard let data = try? Data(contentsOf: spec.outcomeFile) else {
            log.error("\(label(spec)): the outcome file \(spec.outcomeFile.path) disappeared before finishing \(card.ref)")
            update(ref) { $0.task = nil }
            return
        }
        do {
            do {
                switch Outcome.parse(data) {
                case .done(let title, let body, let guide):
                    do {
                        try await finishDone(spec, card: card, branch: branch, base: base, title: title, body: body, guide: guide,
                                             ciRound: s.ciRound, ciCommit: s.ciCommit,
                                             waitForCI: projects[ref.key]?.contract?.ci.waitForCI ?? false)
                    } catch let rejection as BackendRejection {
                        try await stuck(spec, card: card, blocker: "Couldn't finish: the forge or backlog refused: \(rejection)")
                    }
                case .stuck(let blocker):
                    try await finishStuck(spec, card: card, branch: branch, base: base, blocker: blocker)
                }
            } catch is PushRejected {
                try await stuck(spec, card: card, blocker: "Branch `\(branch)` already exists on the forge and wasn't created by LoopWorker for this card, so LoopWorker didn't overwrite it. Rename or delete that branch (or change the project's branch template), then move the card back to ready.")
            }
        } catch {
            finishFailed(ref, card: card, error: error)
            return
        }
        cleanFinishPending = true
        await recycle(ref, keepOutcome: true)
    }

    /// - Parameters:
    ///   - ciRound: set for a CI fix round.
    ///   - ciCommit: set for a CI fix round: the failed commit, which the round's new commits
    ///     count from. Not `origin/<branch>`, which any later fetch moves to the round's own push.
    func finishDone(
        _ spec: SlotSpec, card: Card, branch: String, base: String, title: String, body: String, guide: String?,
        ciRound: Int? = nil, ciCommit: String? = nil, waitForCI: Bool = false
    ) async throws {
        let ahead = try await step("counting commits on \(branch)") {
            if let ciCommit { try await self.deps.git.commitsSince(spec.worktree, commit: ciCommit) }
            else { try await self.deps.git.commitsAhead(spec.worktree, base: base) }
        }
        guard ahead > 0 else {
            let blocker = ciRound.map { "The worker reported done for CI fix round \($0), but made no commits on `\(branch)` after the failed pipeline." }
                ?? "The worker reported done, but branch `\(branch)` has no commits ahead of `\(base)`."
            try await stuck(spec, card: card, blocker: blocker)
            return
        }
        let commit = try await pushBranch(spec, card: card, branch: branch)
        let forge = deps.forge, project = spec.project
        let attach: @Sendable (URL) async throws -> URL? = { try await forge.attach($0, to: project) }
        var (text, refused) = try await step("attaching the files that the outcome references") {
            try await Attachments.resolve(body, in: spec.stateDir, attach: attach)
        }
        var guideLine = ""
        if let guide {
            switch try await step("attaching \(guide)") { try await Attachments.upload(guide, in: spec.stateDir, attach: attach) } {
            case .success(let url): guideLine = "\nReview guide: [\(guide)](\(url.absoluteString))"
            case .failure(let refusal): refused.append(refusal)
            }
        }
        for r in refused {
            let resolved = r.resolved.map { " (\($0.path))" } ?? ""
            log.warning("\(label(spec)): didn't attach \(r.path)\(resolved) to \(card.ref)'s review request: \(r.reason)")
            text += "\n\nLoopWorker didn't attach \(r.path.replacingOccurrences(of: "\n", with: " ")): \(r.reason)"
        }
        let cardLine = card.url.map { "Card: [\(card.ref.display)](\($0.absoluteString))" } ?? "Card: \(card.ref.display)"
        let draft = ReviewRequestDraft(
            project: spec.project, card: card, sourceBranch: branch, targetBranch: base, title: title,
            body: "\(text)\n\n---\n\(cardLine)\(guideLine)\n", draft: spec.project.finish.opensDraft, assignToOwner: true)
        let review = try await step("opening the review request") { try await self.deps.forge.openReviewRequest(draft) }
        guard waitForCI else {
            try await step("moving \(card.ref) to review") { try await self.deps.backlog.markReview(card, review: review) }
            log.info("\(label(spec)): finished \(card.ref): \(review.display) \(review.url.absoluteString)")
            return
        }
        // Written before the move, so a verifying card always has its record.
        let record = CIWatchRecord(card: card.ref, project: spec.project.path, number: card.number, branch: branch, base: base,
                                   sha: commit, review: review, round: ciRound ?? 0, pushedAt: clock.now())
        do { try record.write(stateDir: stateDir) }
        catch { throw StepError(step: "writing the CI watch record", error: error) }
        try await step("moving \(card.ref) to verifying") { try await self.deps.backlog.markVerifying(card, review: review, plan: .ciThenReview) }
        var verifying = card
        verifying.state = .verifying
        watch(record, card: verifying, lastPoll: clock.now())
        log.info("\(label(spec)): \(card.ref) waits for CI on \(commit.prefix(12)): \(review.display) \(review.url.absoluteString)")
    }

    /// Pushes the card branch with a lease on the commit the Manager last pushed for this
    /// card (none: the branch must not exist yet), so a branch that someone else made is never
    /// overwritten, then records the new commit. Uploads the branch's LFS objects first.
    @discardableResult
    func pushBranch(_ spec: SlotSpec, card: Card, branch: String) async throws -> String {
        let last = readPushes()[card.ref.id].flatMap { $0.branch == branch ? $0.commit : nil }
        let url = deps.forge.cloneURL(for: spec.project), env = deps.forge.gitEnvironment(), git = deps.git
        do {
            if try await git.usesLFS(spec.worktree) { try await git.lfsPush(spec.worktree, url: url, environment: env) }
        } catch { throw StepError(step: "pushing Git LFS objects for \(branch)", error: error) }
        let commit: String
        do { commit = try await git.push(spec.worktree, to: url, branch: branch, expected: last, environment: env) }
        catch let rejected as PushRejected { throw rejected }
        catch { throw StepError(step: "pushing \(branch)", error: error) }
        var pushes = readPushes()  // re-read: other cards' finishes may have written it during the push
        pushes[card.ref.id] = PushRecord(branch: branch, commit: commit)
        // Failing the finish here would retry the push against a stale lease.
        do { try writePushes(pushes) }
        catch { log.error("\(label(spec)): pushed \(branch) at \(commit.prefix(12)) but can't record it in \(pushLedger.path): \(error); the card's next push will be refused as someone else's branch") }
        return commit
    }

    var pushLedger: URL { stateDir.appending(path: "pushes.json") }

    /// The push ledger, keyed by card id; empty when the file is missing or unreadable.
    func readPushes() -> [String: PushRecord] {
        (try? JSONDecoder().decode([String: PushRecord].self, from: Data(contentsOf: pushLedger))) ?? [:]
    }

    func writePushes(_ pushes: [String: PushRecord]) throws {
        try JSONEncoder().encode(pushes).write(to: pushLedger, options: .atomic)
    }

    func finishStuck(_ spec: SlotSpec, card: Card, branch: String, base: String, blocker: String) async throws {
        let ahead = try await step("counting commits on \(branch)") { try await self.deps.git.commitsAhead(spec.worktree, base: base) }
        var text = blocker
        if ahead > 0 {
            try await pushBranch(spec, card: card, branch: branch)
            text += "\n\nThe worker's commits are on branch `\(branch)`."
        }
        try await stuck(spec, card: card, blocker: text)
    }

    func stuck(_ spec: SlotSpec, card: Card, blocker: String) async throws {
        try await step("marking \(card.ref) stuck") { try await self.deps.backlog.markStuck(card, blocker: blocker) }
        unwatch(card.ref.id)  // a finish that wrote a CI watch record and then failed
        log.warning("\(label(spec)): marked \(card.ref) stuck: \(blocker.prefix(200))")
        notify(key: "stuck-\(card.ref.id)", "LoopWorker: \(card.ref) is stuck: \(blocker.prefix(300))")
    }

    /// Runs one finish step, wrapping its error with the step's name. A `BackendRejection`
    /// passes through unwrapped so the caller can turn it into a stuck card.
    func step<T: Sendable>(_ name: String, _ body: @Sendable () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let rejection as BackendRejection { throw rejection }
        catch { throw StepError(step: name, error: error) }
    }

    func finishFailed(_ ref: SlotRef, card: Card, error: any Error) {
        let now = clock.now()
        var failures = 0
        var spec: SlotSpec?
        update(ref) {
            $0.finishFailures += 1
            failures = $0.finishFailures
            $0.finishRetryAt = now.addingTimeInterval(min(30 * pow(2, Double($0.finishFailures - 1)), 600))
            $0.task = nil
            $0.finishError = "finish failed: \(error)"
            spec = $0.spec
        }
        guard let spec else { return }
        let delay = Int(min(30 * pow(2, Double(failures - 1)), 600))
        log.error("\(label(spec)): finishing \(card.ref) failed at \(error); retrying in \(delay) s")
        if failures == 3 {
            notify(key: "finish-failing-\(ref.id)", "LoopWorker: finishing \(card.ref) on \(hostName) failed 3 times: \(error)")
        }
    }
}
