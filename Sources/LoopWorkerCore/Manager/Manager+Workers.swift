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
            $0.spawnedAt = nil
            $0.pane = []
            $0.finishFailures = 0
            $0.finishRetryAt = nil
            $0.finishError = nil
        }
        fillSoon = true
        track { await self.startTask(ref, card: card, contract: contract, base: base, branch: branch) }
    }

    func startTask(_ ref: SlotRef, card: Card, contract: ProjectContract, base: String, branch: String) async {
        guard let spec = slot(ref)?.spec else { return }
        let fm = FileManager.default
        let dir = spec.stateDir
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["outcome.json", "card.md", "brief.md", "launch.sh", "mcp.json", "worker.env", "guide.html"] {
                try? fm.removeItem(at: dir.appending(path: name))
            }
            try CardRecord(ref: card.ref, project: spec.project.path, number: card.number, slot: spec.index,
                           branch: branch, base: base, claimedAt: clock.now()).write(cardRecordFile(spec))
        } catch {
            log.error("\(label(spec)): can't write \(dir.path): \(error); not claiming \(card.ref)")
            free(ref)
            return
        }

        let claimed: Bool
        do { claimed = try await deps.backlog.claim(card) }
        catch {
            log.error("\(label(spec)): claiming \(card.ref) failed: \(error); the stranded-card sweep releases it if the claim landed")
            try? fm.removeItem(at: cardRecordFile(spec))
            free(ref)
            return
        }
        guard claimed else {
            log.info("\(label(spec)): \(card.ref) was no longer ready; skipping it")
            try? fm.removeItem(at: cardRecordFile(spec))
            free(ref)
            return
        }

        let baseCommit: String
        do { baseCommit = try await deps.lifecycle.acquire(spec, contract: contract, base: base, branch: branch) }
        catch {
            await abortStart(ref, card: card, contract: contract, why: "preparing the slot failed: \(error)", broken: error)
            return
        }

        do {
            try await writeWorkerFiles(spec, card: card, contract: contract, base: base, branch: branch)
        } catch {
            await abortStart(ref, card: card, contract: contract, why: "\(error)", broken: nil)
            return
        }
        do { try await deps.tmux.spawn(session: spec.session, directory: spec.worktree, script: dir.appending(path: "launch.sh")) }
        catch {
            await abortStart(ref, card: card, contract: contract, why: "starting the tmux session failed: \(error)",
                             broken: SlotFailure("tmux spawn failed: \(error)"))
            return
        }

        let model = card.model ?? spec.project.model
        update(ref) {
            $0.task = nil
            $0.spawnedAt = clock.now()
        }
        log.info("\(label(spec)): spawned worker for \(card.ref) on \(branch) at \(baseCommit.prefix(12)), base \(base), model \(model ?? "default")")
        watchFolderTrust(spec.session)
    }

    func writeWorkerFiles(_ spec: SlotSpec, card: Card, contract: ProjectContract, base: String, branch: String) async throws {
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
        let brief = WorkerBrief(card: card, project: spec.project, slot: spec, baseBranch: base, branch: branch,
                                snapshotFile: snapshotFile, excluded: snapshot.excluded, contract: contract).render()

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

    /// A start failed after the claim: release the card (not counted against it: the host
    /// failed), mark the slot broken when `broken` is set, and recycle it.
    func abortStart(_ ref: SlotRef, card: Card, contract: ProjectContract, why: String, broken: (any Error)?) async {
        guard let spec = slot(ref)?.spec else { return }
        log.error("\(label(spec)): couldn't start a worker for \(card.ref): \(why)")
        do {
            try await deps.backlog.release(card, reason: "LoopWorker couldn't start a worker for this card: \(why)", countsAsAttempt: false)
        } catch {
            log.error("\(label(spec)): can't release \(card.ref): \(error); the stranded-card sweep retries")
        }
        if broken != nil || !spec.project.hot { await deps.lifecycle.recycle(spec, contract: contract) }
        try? FileManager.default.removeItem(at: cardRecordFile(spec))
        if let broken {
            let failure = broken as? SlotFailure ?? SlotFailure("\(broken)")
            free(ref)
            markBroken(ref, failure)
        } else {
            free(ref)
        }
    }

    /// Accepts claude's folder-trust dialog, which a fresh worktree shows once and which
    /// would otherwise hang the unattended worker.
    func watchFolderTrust(_ session: String) {
        let tmux = deps.tmux, clock = self.clock, log = self.log, showsTrustPrompt = deps.pane.showsTrustPrompt
        track {
            for _ in 0..<15 {
                try? await clock.sleep(seconds: 2)
                if Task.isCancelled { return }
                guard let pane = try? await tmux.capture(session, lines: 40) else { return }
                if showsTrustPrompt(pane) {
                    try? await tmux.sendEnter(session)
                    log.info("\(session): accepted claude's folder-trust dialog")
                    return
                }
            }
        }
    }

    /// Returns a slot to idle and lets fill use it again.
    func free(_ ref: SlotRef) {
        update(ref) {
            $0.phase = $0.phase == .broken ? .broken : .idle
            $0.task = nil
            $0.card = nil
            $0.branch = nil
            $0.base = nil
            $0.spawnedAt = nil
            $0.finishFailures = 0
            $0.finishRetryAt = nil
            $0.finishError = nil
        }
        fillSoon = true
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
        for ref in refs { await reconcile(ref, now) }
    }

    func reconcile(_ ref: SlotRef, _ now: Date) async {
        guard let s = slot(ref), let card = s.card else { return }
        let spec = s.spec
        let alive: Bool
        let fresh: Card?
        var pane = ""
        do {
            alive = try await deps.tmux.isAlive(spec.session)
            if alive { pane = (try? await deps.tmux.capture(spec.session, lines: 40)) ?? "" }
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
            if alive { $0.pane = lines }
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
            let tail = lines.isEmpty ? s.pane : lines  // a dead session has no pane; use the last capture
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
                try await deps.backlog.markStuck(card, blocker: "LoopWorker gave up after \(attempt) failed attempts (max_attempts is \(config.maxAttempts)). The last one: \(why). The earlier attempts' reasons are in the release notes on this card.\(terminal)")
                log.warning("\(label(spec)): marked \(card.ref) stuck after \(attempt) failed attempts; last: \(why)")
                notify(key: "stuck-\(card.ref.id)", "LoopWorker: \(card.ref) is stuck after \(attempt) failed attempts; last: \(why)")
            } else {
                try await deps.backlog.release(card, reason: "LoopWorker released this card: \(why).\(terminal)", countsAsAttempt: reason.countsAsAttempt)
                log.warning("\(label(spec)): released \(card.ref): \(why)")
            }
        } catch {
            log.error("\(label(spec)): can't release \(card.ref): \(error); the stranded-card sweep retries")
        }
        await recycle(ref, keepOutcome: false)
    }

    /// Recycles the slot's stack, clears its card files and frees it (or retires it).
    func recycle(_ ref: SlotRef, keepOutcome: Bool) async {
        guard let s = slot(ref), let p = projects[ref.key] else { return }
        let contract = p.contract ?? ProjectContract(directory: ProjectContract.directory(for: p.spec, clone: p.clone))
        await deps.lifecycle.recycle(s.spec, contract: contract)
        let fm = FileManager.default
        let outcome = s.spec.outcomeFile
        if keepOutcome {
            let last = s.spec.stateDir.appending(path: "last-outcome.json")
            try? fm.removeItem(at: last)
            try? fm.moveItem(at: outcome, to: last)
        } else {
            try? fm.removeItem(at: outcome)
        }
        try? fm.removeItem(at: cardRecordFile(s.spec))
        free(ref)
        if slot(ref)?.retiring == true || projects[ref.key]?.removing == true { retire(ref) }
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
            switch Outcome.parse(data) {
            case .done(let title, let body, let guide):
                do {
                    try await finishDone(spec, card: card, branch: branch, base: base, title: title, body: body, guide: guide)
                } catch let rejection as BackendRejection {
                    try await stuck(spec, card: card, blocker: "LoopWorker couldn't finish this card; the forge or backlog refused: \(rejection)")
                }
            case .stuck(let blocker):
                try await finishStuck(spec, card: card, branch: branch, base: base, blocker: blocker)
            }
        } catch {
            finishFailed(ref, card: card, error: error)
            return
        }
        cleanFinishPending = true
        await recycle(ref, keepOutcome: true)
    }

    func finishDone(_ spec: SlotSpec, card: Card, branch: String, base: String, title: String, body: String, guide: String?) async throws {
        let ahead = try await step("counting commits on \(branch)") { try await self.deps.git.commitsAhead(spec.worktree, base: base) }
        guard ahead > 0 else {
            try await stuck(spec, card: card, blocker: "The worker reported done, but branch `\(branch)` has no commits ahead of `\(base)`.")
            return
        }
        try await step("pushing \(branch)") { try await self.deps.git.push(spec.worktree, branch: branch, environment: self.deps.forge.gitEnvironment()) }
        var guideLink: URL?
        if let guide, let file = resolveGuide(guide, in: spec) {
            do { guideLink = try await step("attaching \(guide)") { try await self.deps.forge.attach(file, to: spec.project) } }
            catch let rejection as BackendRejection {
                log.warning("\(label(spec)): the forge refused the review guide \(file.path): \(rejection); opening the review request without it")
            }
        }
        let cardLine = card.url.map { "Card: [\(card.ref.display)](\($0.absoluteString))" } ?? "Card: \(card.ref.display)"
        let guideLine = guideLink.map { "\nReview guide: [\(guide ?? "guide")](\($0.absoluteString))" } ?? ""
        let draft = ReviewRequestDraft(
            project: spec.project, card: card, sourceBranch: branch, targetBranch: base, title: title,
            body: "\(body)\n\n---\n\(cardLine)\(guideLine)\n", draft: spec.project.draftReviewRequests)
        let review = try await step("opening the review request") { try await self.deps.forge.openReviewRequest(draft) }
        try await step("moving \(card.ref) to review") { try await self.deps.backlog.markReview(card, review: review) }
        log.info("\(label(spec)): finished \(card.ref): \(review.display) \(review.url.absoluteString)")
    }

    func finishStuck(_ spec: SlotSpec, card: Card, branch: String, base: String, blocker: String) async throws {
        let ahead = try await step("counting commits on \(branch)") { try await self.deps.git.commitsAhead(spec.worktree, base: base) }
        var text = blocker
        if ahead > 0 {
            try await step("pushing \(branch)") { try await self.deps.git.push(spec.worktree, branch: branch, environment: self.deps.forge.gitEnvironment()) }
            text += "\n\nThe worker's commits are on branch `\(branch)`."
        }
        try await stuck(spec, card: card, blocker: text)
    }

    func stuck(_ spec: SlotSpec, card: Card, blocker: String) async throws {
        try await step("marking \(card.ref) stuck") { try await self.deps.backlog.markStuck(card, blocker: blocker) }
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

    /// The guide file inside the slot's state directory, or nil (logged) when it resolves
    /// outside it or doesn't exist.
    func resolveGuide(_ guide: String, in spec: SlotSpec) -> URL? {
        let root = spec.stateDir.standardizedFileURL.resolvingSymlinksInPath().path
        let raw = guide.hasPrefix("/") ? URL(filePath: guide) : spec.stateDir.appending(path: guide)
        let file = raw.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard file.path.hasPrefix(root + "/") else {
            log.warning("\(label(spec)): not attaching guide \(guide): it resolves to \(file.path), outside \(root)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else {
            log.warning("\(label(spec)): not attaching guide \(guide): \(file.path) doesn't exist")
            return nil
        }
        return file
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
