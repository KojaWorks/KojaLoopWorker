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
    /// Set for a CI fix round: the commit that the round started from, the branch tip after
    /// the failed pipeline's commit; the round's own commits count from it.
    var ciCommit: String? = nil
    /// Set for a fix round that rebases the card branch.
    var rebaseRound: Bool? = nil
    /// Set for a fix round: the watch's rebase rounds, this one included.
    var rebases: Int? = nil
    /// Set for a rebase round once spawned: the commit that `origin/<base>` pointed at, which
    /// the worker rebases onto.
    var rebaseTarget: String? = nil
    /// When a review round read the review feedback; its note's marker carries it.
    var feedbackReadAt: Date? = nil
    /// What the card branch's next push expects on the forge. Nil in a `card.json` that an
    /// older version wrote, whose lease is in the legacy push ledger.
    var lease: Lease? = nil

    struct Lease: Codable, Equatable {
        /// The commit that the branch's next push expects: the tip that a resumed card or a
        /// fix round started from, then each push's own commit. Nil: the branch must not exist.
        var tip: String?
    }

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

/// A worker run's identity on the review request, from its `card.json`: `id` is
/// `ReviewMarker.roundID` of the claim time, `readAt` when it read the review feedback.
struct Round: Sendable, Equatable {
    var id: String
    var readAt: Date?
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
                  let card = cards.first(where: { $0.project.lowercased() == p.spec.path.lowercased() && !(claimBackoff[$0.ref.id].map { $0.until > now } ?? false) }),
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
            $0.rebaseRound = false
            $0.rebases = 0
            $0.rebaseTarget = nil
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
                           ciRound: fix.map { $0.record.round + 1 }, ciCommit: fix?.record.sha,
                           rebaseRound: fix.map(\.isRebase), rebases: fix.map { ($0.record.rebases ?? 0) + ($0.isRebase ? 1 : 0) },
                           lease: CardRecord.Lease(tip: nil)
            ).write(cardRecordFile(spec))
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
        do { claimed = try await deps.backlog.claim(card, holder: holder) }
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
        // Not every backlog's claim is compare-and-set: a rival's newer claim holds the card.
        do {
            let fresh = try await deps.backlog.card(card.ref)
            guard let fresh, fresh.state == .working else {
                log.warning("\(label(spec)): \(card.ref) is \(fresh?.state.rawValue ?? "gone") right after this Manager claimed it; not starting a worker")
                try? fm.removeItem(at: cardRecordFile(spec))
                free(ref)
                return
            }
            if let other = heldElsewhere(fresh) {
                log.warning("\(label(spec)): \(card.ref) was claimed by \(other) too, after this Manager; leaving it to that Manager")
                try? fm.removeItem(at: cardRecordFile(spec))
                free(ref)
                return
            }
        } catch {
            log.error("\(label(spec)): can't re-read \(card.ref) after claiming it: \(error); not starting a worker, and the stranded-card sweep releases the card unless another Manager holds it")
            try? fm.removeItem(at: cardRecordFile(spec))
            free(ref)
            return
        }

        let resumed: PushRecord?
        do { resumed = try await resumesPushedBranch(spec, card: card, base: base, branch: branch) }
        catch {
            await abortStart(ref, card: card, contract: contract, why: "\(error)", broken: nil)
            return
        }
        // Read before acquiring, so a read that keeps failing doesn't provision a slot every time.
        var snapshot: CardSnapshot?, reviewRound: WorkerBrief.ReviewRound?
        if resumed != nil {
            do {
                let read = try await self.snapshot(spec, card: card)
                reviewRound = try await self.reviewRound(spec, card: card, branch: branch, vouchedAt: read.vouchedAt)
                snapshot = read
            } catch {
                await releaseBeforeAcquire(ref, card: card, why: "\(error)")
                return
            }
        }
        await acquireAndSpawn(ref, spec: spec, card: card, contract: contract, base: base, branch: branch, fix: nil, resumed: resumed,
                              snapshot: snapshot, reviewRound: reviewRound)
    }

    /// The push that the card records (`Backlog.lastPush`, or the legacy push ledger for a card
    /// without one) when it names `branch` and the forge still has that branch, so the worker
    /// continues from it instead of overwriting it; nil for a fresh start.
    func resumesPushedBranch(_ spec: SlotSpec, card: Card, base: String, branch: String) async throws -> PushRecord? {
        let recorded = try await step("reading \(card.ref)'s last push") { try await self.deps.backlog.lastPush(card) }
        let legacy = recorded == nil ? readLegacyPushes()[card.ref.id] : nil
        guard let pushed = recorded ?? legacy, pushed.branch == branch else { return nil }
        let exists = try await step("checking whether \(branch) is still on the forge") {
            try await self.deps.git.cloneOrFetch(url: self.deps.forge.cloneURL(for: spec.project), into: spec.clone,
                                                 environment: self.deps.forge.gitEnvironment())
            return try await self.deps.git.hasRemoteBranch(spec.clone, branch: branch)
        }
        let source = legacy == nil ? "" : " (as \(legacyPushLedger.path) records)"
        guard exists else {
            log.warning("\(label(spec)): origin/\(branch), which an earlier attempt of \(card.ref) pushed\(source), is gone from the forge; starting over from origin/\(base)")
            return nil
        }
        log.info("\(label(spec)): resuming \(card.ref) from origin/\(branch), which an earlier attempt pushed at \(pushed.commit.prefix(12))\(source)")
        return pushed
    }

    /// A fix round or a resumed card resets the slot to the pushed card branch instead of the
    /// base branch. `resumed`: the push that a resumed card continues from.
    func acquireAndSpawn(_ ref: SlotRef, spec: SlotSpec, card: Card, contract: ProjectContract, base: String, branch: String,
                         fix: FixRound?, resumed: PushRecord? = nil, snapshot: CardSnapshot? = nil,
                         reviewRound: WorkerBrief.ReviewRound? = nil) async {
        let dir = spec.stateDir
        let resuming = resumed != nil
        let baseCommit: String
        do { baseCommit = try await deps.lifecycle.acquire(spec, contract: contract, base: fix == nil && !resuming ? base : branch, branch: branch) }
        catch {
            await abortStart(ref, card: card, contract: contract, why: "preparing the slot failed: \(error)", broken: error, fix: fix)
            return
        }
        if fix != nil || resuming {
            if let last = fix?.record.sha ?? resumed?.commit, last != baseCommit {
                log.info("\(label(spec)): continuing \(card.ref) from \(baseCommit.prefix(12)), which includes commits pushed after LoopWorker's last push \(last.prefix(12))")
            }
            do {
                // The finish leases on the tip, even when someone else pushed to the branch since the last push.
                let file = cardRecordFile(spec)
                guard var record = CardRecord.read(file) else { throw ConfigError("\(file.path) is missing or unreadable") }
                record.lease = CardRecord.Lease(tip: baseCommit)
                // The round's own commits count from here, not from the failed commit: someone may have pushed since.
                if fix != nil { record.ciCommit = baseCommit }
                try record.write(file)
                if fix != nil { update(ref) { $0.ciCommit = baseCommit } }
            } catch {
                await abortStart(ref, card: card, contract: contract, why: "recording \(branch) at \(baseCommit.prefix(12)) as the round's start failed: \(error)",
                                 broken: nil, fix: fix)
                return
            }
        }

        // The project refresh moves the shared origin/<base>, so the round rebases onto a pinned commit.
        var rebaseTarget: String?
        if fix?.isRebase == true {
            let file = cardRecordFile(spec)
            do {
                let target = try await deps.git.resolve(spec.worktree, ref: "origin/\(base)")
                guard var record = CardRecord.read(file) else { throw ConfigError("\(file.path) is missing or unreadable") }
                record.rebaseTarget = target
                try record.write(file)
                rebaseTarget = target
            } catch {
                await abortStart(ref, card: card, contract: contract, why: "pinning origin/\(base) for the rebase failed: \(error)", broken: nil, fix: fix)
                return
            }
            update(ref) { $0.rebaseTarget = rebaseTarget }
        }

        do {
            try await writeWorkerFiles(spec, card: card, contract: contract, base: base, branch: branch, fix: fix,
                                       rebaseTarget: rebaseTarget, resuming: resuming, snapshot: snapshot, reviewRound: reviewRound)
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
        claimBackoff[card.ref.id] = nil
        let round = fix.map { " for \($0.name)" } ?? (resuming ? " resuming its pushed branch" : "")
        log.info("\(label(spec)): spawned worker\(round) for \(card.ref) on \(branch) at \(baseCommit.prefix(12)), base \(base), model \(model ?? "default")")
        watchFolderTrust(spec.session)
    }

    func writeWorkerFiles(_ spec: SlotSpec, card: Card, contract: ProjectContract, base: String, branch: String,
                          fix: FixRound? = nil, rebaseTarget: String? = nil, resuming: Bool = false, snapshot read: CardSnapshot? = nil,
                          reviewRound: WorkerBrief.ReviewRound? = nil) async throws {
        let dir = spec.stateDir
        let snapshot: CardSnapshot
        if let read { snapshot = read } else { snapshot = try await self.snapshot(spec, card: card) }
        for line in snapshot.excluded { log.info("\(label(spec)): withheld from \(card.ref): \(line)") }
        var markdown = snapshot.markdown
        if !snapshot.excluded.isEmpty {
            markdown += "\n\n## Withheld\n\n" + snapshot.excluded.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        let snapshotFile = dir.appending(path: "card.md")
        let ciFile = dir.appending(path: "ci.md")
        var ciFix: WorkerBrief.CIFix?, rebase: WorkerBrief.Rebase?, report: String?
        switch fix?.kind {
        case .ci(let pipeline, let baselines)?:
            ciFix = WorkerBrief.CIFix(review: fix!.record.review, commit: fix!.record.sha, ciFile: ciFile,
                                      round: fix!.record.ciRounds + 1, rounds: contract.ci.fixAttempts)
            report = ciReport(fix!.record, pipeline, baselines: baselines, card: card)
        case .rebase(let reason)?:
            rebase = WorkerBrief.Rebase(review: fix!.record.review, commit: fix!.record.sha, target: rebaseTarget ?? "origin/\(base)",
                                        reason: Self.inlineMarkdown(reason))
        case nil:
            break
        }
        let brief = WorkerBrief(card: card, project: spec.project, slot: spec, baseBranch: base, branch: branch,
                                snapshotFile: snapshotFile, excluded: snapshot.excluded, contract: contract, ciFix: ciFix,
                                rebase: rebase, resuming: resuming, previousAttempt: await previousAttempt(spec, card: card),
                                reviewRound: reviewRound).render()

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
            if let report { try Data(report.utf8).write(to: ciFile) }
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

    func snapshot(_ spec: SlotSpec, card: Card) async throws -> CardSnapshot {
        do { return try await deps.backlog.snapshot(card) }
        catch { throw StepError(step: "reading the card's snapshot", error: error) }
    }

    /// A start failed before the slot was acquired: releases the card (not counted: the read
    /// failed, not the worker) and backs off claiming it, 30 s doubling to 10 min, so a read
    /// that fails every time doesn't loop claim and release every tick.
    func releaseBeforeAcquire(_ ref: SlotRef, card: Card, why: String) async {
        guard let spec = slot(ref)?.spec else { return }
        let failures = (claimBackoff[card.ref.id]?.failures ?? 0) + 1
        let delay = min(30 * pow(2, Double(failures - 1)), 600)
        claimBackoff[card.ref.id] = (clock.now().addingTimeInterval(delay), failures)
        log.error("\(label(spec)): couldn't start a worker for \(card.ref): \(why); releasing it and not claiming it again for \(Int(delay)) s (\(failures) failure(s) in a row)")
        do { try await deps.backlog.release(card, reason: "Couldn't start a worker: \(why)", countsAsAttempt: false) }
        catch { log.error("\(label(spec)): can't release \(card.ref): \(error); the stranded-card sweep retries") }
        try? FileManager.default.removeItem(at: cardRecordFile(spec))
        free(ref)
    }

    /// The open review request of `branch` and its capped, redacted feedback; nil when none is
    /// open or it has no feedback. Records the read time in `card.json` and logs what was
    /// withheld or cut.
    func reviewRound(_ spec: SlotSpec, card: Card, branch: String, vouchedAt: Date?) async throws -> WorkerBrief.ReviewRound? {
        let forge = deps.forge, project = spec.project
        guard let review = try await step("looking for an open review request of \(branch)", {
            try await forge.openReviewRequest(for: project, sourceBranch: branch)
        }) else { return nil }
        let readAt = clock.now()
        let feedback = try await step("reading the review feedback on \(review.display)") {
            try await forge.reviewFeedback(for: review, project: project, vouchedAt: vouchedAt)
        }.capped(redact: deps.redact)
        let file = cardRecordFile(spec)
        do {
            guard var record = CardRecord.read(file) else { throw ConfigError("\(file.path) is missing or unreadable") }
            record.feedbackReadAt = readAt
            try record.write(file)
        } catch { throw StepError(step: "recording when the review feedback was read", error: error) }
        for line in feedback.withheld { log.info("\(label(spec)): withheld from \(card.ref)'s review round: \(line)") }
        for line in feedback.cut { log.info("\(label(spec)): cut from \(card.ref)'s review round: \(line)") }
        guard !feedback.isEmpty else { return nil }
        log.info("\(label(spec)): \(card.ref) is a review round on \(review.display) with \(feedback.threads.count) threads")
        return WorkerBrief.ReviewRound(review: review, feedback: feedback)
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
            $0.rebaseRound = false
            $0.rebases = 0
            $0.rebaseTarget = nil
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
            outcomeAge: outcomeAge, runningFor: current.spawnedAt.map { now.timeIntervalSince($0) } ?? 0,
            heldBy: fresh.flatMap(heldElsewhere))
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
        let record = CardRecord.read(cardRecordFile(spec))
        if record == nil {
            log.error("\(label(spec)): can't read \(cardRecordFile(spec).path); finishing \(card.ref) with the round named by its spawn time")
        }
        let round = Round(id: ReviewMarker.roundID(claimedAt: record?.claimedAt ?? s.spawnedAt ?? clock.now()), readAt: record?.feedbackReadAt)
        do {
            do {
                switch Outcome.parse(data) {
                case .done(let title, let body, let guide, let replies):
                    do {
                        try await finishDone(spec, card: card, branch: branch, base: base, title: title, body: body, guide: guide,
                                             replies: replies, round: round, ciRound: s.ciRound, ciCommit: s.ciCommit,
                                             rebaseRound: s.rebaseRound, rebases: s.rebases, rebaseTarget: s.rebaseTarget,
                                             plan: Self.verifyingPlan(spec.project, contract: projects[ref.key]?.contract))
                    } catch let rejection as BackendRejection {
                        try await stuck(spec, card: card, blocker: "Couldn't finish: the forge or backlog refused: \(rejection)")
                    }
                case .stuck(let blocker):
                    try await finishStuck(spec, card: card, branch: branch, base: base, blocker: blocker)
                }
            } catch is PushRejected where (try? leaseTip(spec, card: card, branch: branch)) != nil {
                try await stuck(spec, card: card, blocker: "Someone pushed to `\(branch)` while the worker ran, so LoopWorker didn't overwrite those commits and didn't push the worker's. Move the card back to ready to redo this round on top of them.")
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
    ///   - ciRound: set for a fix round: the watch's round after it.
    ///   - ciCommit: set for a fix round: the commit that the round started from, which its new
    ///     commits count from. Not `origin/<branch>`, which any later fetch moves to the round's own push.
    ///   - rebaseRound: the fix round rebases the branch, so its target must be an ancestor of HEAD.
    ///   - rebaseTarget: the commit that the rebase round targets; nil checks `origin/<base>`.
    ///   - rebases: the watch's rebase rounds after this round.
    ///   - plan: what the card waits for in `verifying`; nil moves it straight to `review`.
    func finishDone(
        _ spec: SlotSpec, card: Card, branch: String, base: String, title: String, body: String, guide: String?,
        replies: [String: String] = [:], round: Round, ciRound: Int? = nil, ciCommit: String? = nil, rebaseRound: Bool = false,
        rebases: Int = 0, rebaseTarget: String? = nil, plan: VerifyingPlan? = nil
    ) async throws {
        let ahead = try await step("counting commits on \(branch)") {
            if let ciCommit { try await self.deps.git.commitsSince(spec.worktree, commit: ciCommit) }
            else { try await self.deps.git.commitsAhead(spec.worktree, base: base) }
        }
        guard ahead > 0 else {
            let blocker = rebaseRound
                ? "The worker reported done for rebase round \(rebases), but `\(branch)` has no commits after `\(ciCommit?.prefix(12) ?? "")`."
                : ciRound.map { "The worker reported done for CI fix round \($0 - rebases), but made no commits on `\(branch)` after the commit that the round started from." }
                    ?? "The worker reported done, but branch `\(branch)` has no commits ahead of `\(base)`."
            try await stuck(spec, card: card, blocker: blocker)
            return
        }
        if rebaseRound {
            let target = rebaseTarget ?? "origin/\(base)"
            let based = try await step("checking that \(branch) is based on \(target)") {
                try await self.deps.git.isAncestor(spec.worktree, ancestor: target)
            }
            guard based else {
                try await stuck(spec, card: card, blocker: "The worker reported done for rebase round \(rebases), but `\(branch)` isn't based on `\(base)` at `\(target.prefix(12))`, which the round rebased onto.")
                return
            }
        }
        let commit = try await pushBranch(spec, card: card, branch: branch)
        let pushed = PushRecord(branch: branch, commit: commit)
        // A refusal after the push still records it, or the next claim would call the branch foreign.
        do {
            let forge = deps.forge, project = spec.project
            let attach: @Sendable (URL) async throws -> URL? = { try await forge.attach($0, to: project) }
            var (text, refused) = try await step("attaching the files that the outcome references") {
                try await Attachments.resolve(body, in: spec.stateDir, attach: attach)
            }
            var guideLine = ""
            if let guide {
                switch try await step("attaching \(guide)", { try await Attachments.upload(guide, in: spec.stateDir, attach: attach) }) {
                case .success(let url): guideLine = "\nReview guide: [\(guide)](\(url.absoluteString))"
                case .failure(let refusal): refused.append(refusal)
                }
            }
            for r in refused {
                let resolved = r.resolved.map { " (\($0.path))" } ?? ""
                log.warning("\(label(spec)): didn't attach \(r.path)\(resolved) to \(card.ref)'s review request: \(r.reason)")
                text += "\n\nLoopWorker didn't attach \(r.path.replacingOccurrences(of: "\n", with: " ")): \(r.reason)"
            }
            let existing = try await step("looking for an open review request of \(branch)") {
                try await forge.openReviewRequest(for: project, sourceBranch: branch)
            }
            if existing == nil, !replies.isEmpty {
                let ids = replies.keys.sorted()
                log.warning("\(label(spec)): \(card.ref)'s worker replied to threads \(ids.map { String($0.prefix(12)) }.joined(separator: ", ")), but \(branch) has no open review request; adding them to the new one's description")
                text += "\n\nLoopWorker didn't post the worker's replies to threads " + ids.map(Self.inlineCode).joined(separator: ", ")
                    + ": the branch had no open review request.\n\n" + ids.map { "\(Self.inlineCode($0)):\n\n\(replies[$0]!)" }.joined(separator: "\n\n")
            }
            let cardLine = card.url.map { "Card: [\(card.ref.display)](\($0.absoluteString))" } ?? "Card: \(card.ref.display)"
            let draft = ReviewRequestDraft(
                project: spec.project, card: card, sourceBranch: branch, targetBranch: base, title: title,
                body: "\(text)\n\n---\n\(cardLine)\(guideLine)\n", draft: spec.project.finish.opensDraft, assignToOwner: true,
                marker: ReviewMarker.round(round.id, commit: commit, read: round.readAt))
            // On an open one this only assigns the owner when it has no assignee.
            let review = try await step("opening the review request") { try await forge.openReviewRequest(draft) }
            if existing != nil {
                try await postRound(spec, card: card, review: review, round: round, commit: commit,
                                    text: text + (guideLine.isEmpty ? "" : "\n" + guideLine), replies: replies)
            }
            guard let plan else {
                try await step("moving \(card.ref) to review") { try await self.deps.backlog.markReview(card, review: review, note: nil, pushed: pushed) }
                log.info("\(label(spec)): finished \(card.ref): \(review.display) \(review.url.absoluteString)")
                return
            }
            // Written before the move, so a verifying card always has its record.
            let record = CIWatchRecord(card: card.ref, project: spec.project.path, number: card.number, branch: branch, base: base,
                                       sha: commit, review: review, round: ciRound ?? 0, pushedAt: clock.now(),
                                       rebases: rebases == 0 ? nil : rebases)
            do { try record.write(stateDir: stateDir) }
            catch { throw StepError(step: "writing the CI watch record", error: error) }
            try await step("moving \(card.ref) to verifying") { try await self.deps.backlog.markVerifying(card, review: review, plan: plan, pushed: pushed) }
            var verifying = card
            verifying.state = .verifying
            watch(record, card: verifying, lastPoll: plan == .merge ? nil : clock.now())
            let waits = plan == .merge ? "merges" : "waits for CI on \(commit.prefix(12)) before it \(plan == .ciThenMerge ? "merges" : "moves to review")"
            log.info("\(label(spec)): \(card.ref) \(waits): \(review.display) \(review.url.absoluteString)")
        } catch let rejection as BackendRejection {
            try await stuck(spec, card: card, blocker: "Couldn't finish: the forge or backlog refused: \(rejection)", pushed: pushed)
        }
    }

    /// Posts a round's replies into their threads, then `text` as a note on `review` under a
    /// line naming `commit`. A reply that fails or names an unknown thread is logged and listed
    /// under the note; a failed note throws, and a retry finds what was already posted.
    func postRound(_ spec: SlotSpec, card: Card, review: ReviewRequest, round: Round, commit: String, text: String, replies: [String: String]) async throws {
        let forge = deps.forge, project = spec.project
        var problems: [String] = []
        for (thread, reply) in replies.sorted(by: { $0.key < $1.key }) {
            do {
                switch try await forge.replyToThread(thread, text: reply, marker: ReviewMarker.reply(round.id, thread: thread), on: review, project: project) {
                case .posted: log.info("\(label(spec)): replied in thread \(thread.prefix(12)) of \(review.display)")
                case .alreadyPosted: log.info("\(label(spec)): thread \(thread) of \(review.display) already has this round's reply")
                case .noSuchThread:
                    log.warning("\(label(spec)): \(card.ref)'s worker replied to thread \(thread.prefix(12)), which \(review.display) doesn't have; listing it under the round's note")
                    problems.append("LoopWorker didn't post the worker's reply to thread \(Self.inlineCode(thread)): \(review.display) has no such thread. The reply:\n\n\(reply)")
                }
            } catch {
                log.error("\(label(spec)): replying in thread \(thread.prefix(12)) of \(review.display) failed: \(error)")
                problems.append("LoopWorker couldn't post the worker's reply in thread \(Self.inlineCode(thread)); the Manager's log on \(hostName) has the error. The reply:\n\n\(reply)")
            }
        }
        let note = "LoopWorker pushed `\(commit.prefix(12))` to this branch.\n\n\(text)" + problems.map { "\n\n" + $0 }.joined()
        let posted = try await step("posting this round's note on \(review.display)") {
            try await forge.postReviewNote(note, marker: ReviewMarker.round(round.id, commit: commit, read: round.readAt), on: review, project: project)
        }
        if !posted { log.info("\(label(spec)): \(review.display) already has this round's note; not posting it again") }
    }

    /// `text` as inline code on one line.
    static func inlineCode(_ text: String) -> String { "`" + text.filter { $0 != "`" && !$0.isNewline } + "`" }

    /// Pushes the card branch with a lease on `card.json`'s lease tip (the slot's last push, or
    /// the tip that a resumed card or fix round started from; none: the branch must not exist
    /// yet), so a branch that someone else made, or a commit that someone pushed while the worker
    /// ran, is never overwritten, then records the new commit as the tip. Uploads the branch's
    /// LFS objects first.
    func pushBranch(_ spec: SlotSpec, card: Card, branch: String) async throws -> String {
        let last = try leaseTip(spec, card: card, branch: branch)
        let url = deps.forge.cloneURL(for: spec.project), env = deps.forge.gitEnvironment(), git = deps.git
        do {
            if try await git.usesLFS(spec.worktree) { try await git.lfsPush(spec.worktree, url: url, environment: env) }
        } catch { throw StepError(step: "pushing Git LFS objects for \(branch)", error: error) }
        let commit: String
        do { commit = try await git.push(spec.worktree, to: url, branch: branch, expected: last, environment: env) }
        catch let rejected as PushRejected { throw rejected }
        catch { throw StepError(step: "pushing \(branch)", error: error) }
        let file = cardRecordFile(spec)
        // Failing the finish here would retry the push against a stale lease.
        do {
            guard var record = CardRecord.read(file) else { throw ConfigError("\(file.path) is missing or unreadable") }
            record.lease = CardRecord.Lease(tip: commit)
            try record.write(file)
        } catch {
            log.error("\(label(spec)): pushed \(branch) at \(commit.prefix(12)) but can't record it in \(file.path): \(error); a retried finish will be refused as someone else's push")
        }
        return commit
    }

    /// The commit that the next push of `branch` expects on the forge, from `card.json`; for a
    /// `card.json` that an older version wrote, from the legacy push ledger. Nil: the branch
    /// must not exist yet.
    func leaseTip(_ spec: SlotSpec, card: Card, branch: String) throws -> String? {
        let file = cardRecordFile(spec)
        guard let record = CardRecord.read(file) else {
            throw StepError(step: "reading the push lease of \(branch)", error: ConfigError("\(file.path) is missing or unreadable"))
        }
        if let lease = record.lease { return lease.tip }
        return readLegacyPushes()[card.ref.id].flatMap { $0.branch == branch ? $0.commit : nil }
    }

    /// Where versions before the push record on the card kept each card's last push. Read only
    /// for cards and slots that those versions left behind; see DESIGN.md "State on disk".
    var legacyPushLedger: URL { stateDir.appending(path: "pushes.json") }

    /// The legacy push ledger, keyed by card id; empty when the file is missing or unreadable.
    func readLegacyPushes() -> [String: PushRecord] {
        (try? JSONDecoder().decode([String: PushRecord].self, from: Data(contentsOf: legacyPushLedger))) ?? [:]
    }

    func finishStuck(_ spec: SlotSpec, card: Card, branch: String, base: String, blocker: String) async throws {
        let ahead = try await step("counting commits on \(branch)") { try await self.deps.git.commitsAhead(spec.worktree, base: base) }
        var text = blocker
        var pushed: PushRecord?
        if ahead > 0 {
            pushed = PushRecord(branch: branch, commit: try await pushBranch(spec, card: card, branch: branch))
            text += "\n\nThe worker's commits are on branch `\(branch)`."
        }
        try await stuck(spec, card: card, blocker: text, pushed: pushed)
    }

    /// `pushed`: the push that this finish made, which the card records.
    func stuck(_ spec: SlotSpec, card: Card, blocker: String, pushed: PushRecord? = nil) async throws {
        try await step("marking \(card.ref) stuck") { try await self.deps.backlog.markStuck(card, blocker: blocker, pushed: pushed) }
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
