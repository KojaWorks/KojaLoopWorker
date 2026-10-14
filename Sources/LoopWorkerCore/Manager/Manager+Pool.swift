import Foundation

extension Manager {
    // MARK: Projects and slot pools

    func addProject(_ spec: ProjectSpec) {
        let band = Budget.freeBand(used: Set(projects.values.map(\.band)))
        projects[spec.key] = Project(spec: spec, band: band, clone: config.clonesDir.appending(path: spec.key))
        order.append(spec.key)
    }

    func makeSlotSpec(_ p: Project, index: Int) -> SlotSpec {
        SlotSpec(
            project: p.spec, index: index, clone: p.clone,
            worktree: config.clonesDir.appending(path: "\(p.spec.key).slots/\(index)"),
            port: Budget.port(basePort: config.basePort, portStep: config.portStep, bandSize: bandSize,
                              band: p.band, index: index),
            stateDir: config.slotsStateDir.appending(path: "\(p.spec.key)/\(index)"))
    }

    func newSlot(_ p: Project, index: Int) -> Slot {
        Slot(spec: makeSlotSpec(p, index: index), prepared: !p.spec.hot)
    }

    func resizeAll() {
        let active = order.compactMap { projects[$0] }.filter { !$0.removing }
        let targets = Budget.slotTargets(for: active.map(\.spec), maxSlots: config.maxSlots, band: bandSize)
        for (p, target) in zip(active, targets) { resize(p.spec.key, to: target) }
    }

    /// Grows by un-retiring slots first, then adding new ones; shrinks by retiring the
    /// highest idle slots first and flagging busy ones to retire after their card.
    func resize(_ key: String, to target: Int) {
        guard var p = projects[key] else { return }
        var active = p.slots.filter { !$0.retiring }.count
        if active < target {
            for i in p.slots.indices.sorted(by: { p.slots[$0].spec.index < p.slots[$1].spec.index })
            where p.slots[i].retiring && p.slots[i].task != .retiring && active < target {
                p.slots[i].retiring = false
                active += 1
            }
            while active < target {
                let used = Set(p.slots.map(\.spec.index))
                p.slots.append(newSlot(p, index: Budget.freeBand(used: used)))
                active += 1
            }
            p.slots.sort { $0.spec.index < $1.spec.index }
            projects[key] = p
            prepareUnprepared(key)
        } else if active > target {
            let excess = p.slots.filter { !$0.retiring }.sorted {
                let ai = $0.task == nil && $0.phase != .busy, bi = $1.task == nil && $1.phase != .busy
                return ai != bi ? ai : $0.spec.index > $1.spec.index
            }.prefix(active - target)
            for s in excess {
                let ref = SlotRef(key: key, id: s.id)
                if s.task == nil && s.phase != .busy {
                    retire(ref)
                } else {
                    update(ref) { $0.retiring = true }
                    log.info("\(label(s.spec)) retires after its current work")
                }
            }
        }
    }

    /// Removes a slot for good. Runs `retire` as a task, then drops the slot, and the project
    /// once it is being removed and has no slot left.
    func retire(_ ref: SlotRef) {
        guard let s = slot(ref), let p = projects[ref.key] else { return }
        update(ref) {
            $0.task = .retiring
            $0.retiring = true
        }
        let contract = p.contract ?? ProjectContract(directory: ProjectContract.directory(for: p.spec, clone: p.clone))
        let lifecycle = deps.lifecycle
        log.info("retiring \(label(s.spec))")
        track {
            await lifecycle.retire(s.spec, contract: contract)
            await self.removeSlot(ref)
        }
    }

    func removeSlot(_ ref: SlotRef) {
        guard var p = projects[ref.key] else { return }
        p.slots.removeAll { $0.id == ref.id }
        projects[ref.key] = p
        removeProjectIfDone(ref.key)
    }

    func removeProjectIfDone(_ key: String) {
        guard let p = projects[key], p.removing, p.slots.isEmpty else { return }
        projects[key] = nil
        order.removeAll { $0 == key }
        log.info("stopped serving \(p.spec.path)")
    }

    // MARK: Startup adoption

    /// Adopts each slot whose `card.json` names a card that is still `working` and clears the
    /// others. Returns the sessions of the adopted workers.
    func adoptPreviousWorkers(_ key: String) async -> Set<String> {
        guard var p = projects[key] else { return [] }
        // Recycling below must run the manifest's own scripts, before the first refresh lands.
        if p.contract == nil, let contract = try? ProjectContract.load(from: ProjectContract.directory(for: p.spec, clone: p.clone)) {
            p.contract = contract
            projects[key]!.contract = contract
        }
        let fm = FileManager.default
        let dir = config.slotsStateDir.appending(path: key)
        let onDisk = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap(Int.init)
        var adopted: Set<String> = []
        for index in Set(onDisk + p.slots.map(\.spec.index)).sorted() {
            guard let record = CardRecord.read(dir.appending(path: "\(index)/card.json")) else { continue }
            if projects[key]?.slots.contains(where: { $0.spec.index == index }) != true, let current = projects[key] {
                var extra = newSlot(current, index: index)
                extra.retiring = true
                projects[key]!.slots.append(extra)
                projects[key]!.slots.sort { $0.spec.index < $1.spec.index }
            }
            guard let s = projects[key]?.slots.first(where: { $0.spec.index == index }) else { continue }
            let ref = SlotRef(key: key, id: s.id)

            let fresh: Card?
            do { fresh = try await deps.backlog.card(record.ref) }
            catch {
                log.warning("\(label(s.spec)): can't read \(record.ref) at startup: \(error); adopting it, and a later tick decides")
                adopt(ref, record: record, card: Card(ref: record.ref, project: record.project, number: record.number,
                                                     title: "", state: .working))
                adopted.insert(s.spec.session)
                continue
            }
            guard let fresh, fresh.state == .working else {
                log.info("\(label(s.spec)): \(record.ref) is \(fresh?.state.rawValue ?? "gone") now; clearing the slot")
                try? fm.removeItem(at: cardRecordFile(s.spec))
                try? fm.removeItem(at: s.spec.outcomeFile)
                if !p.spec.hot {
                    update(ref) { $0.task = .recycling }
                    track { await self.recycle(ref, keepOutcome: false) }
                } else {
                    retireIfDue(ref)  // an extra slot beyond the pool
                }
                continue
            }
            adopt(ref, record: record, card: fresh)
            adopted.insert(s.spec.session)
            let alive = (try? await deps.tmux.isAlive(s.spec.session)) ?? false
            if !alive && !fm.fileExists(atPath: s.spec.outcomeFile.path) {
                log.warning("\(label(s.spec)): \(fresh.ref)'s worker is gone and left no outcome; releasing it")
                update(ref) { $0.task = .releasing }
                track { await self.releaseAfterRestart(ref, card: fresh) }
            } else {
                log.info("\(label(s.spec)): adopted the worker for \(fresh.ref) on \(record.branch)")
            }
        }
        return adopted
    }

    /// Reaps every worker session on this home's tmux server that no slot adopted. The socket
    /// is private to this home, so this also catches workers of projects that left the config
    /// while the Manager was down.
    func reapUnadoptedSessions(_ adopted: Set<String>) async {
        do {
            for session in try await deps.tmux.sessions(prefix: "lw_") where !adopted.contains(session) {
                log.warning("reaping worker session \(session): no slot holds a working card for it")
                try? await deps.tmux.kill(session)
            }
        } catch {
            log.error("can't list tmux sessions: \(error); unadopted workers may still run")
        }
    }

    /// Logs each `card.json` left by a project that is no longer configured. The backlog can't
    /// be asked about such a project, so a human must check the card.
    func reportUnconfiguredCards() {
        let fm = FileManager.default
        let root = config.slotsStateDir
        for key in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted() where projects[key] == nil {
            let dir = root.appending(path: key)
            for index in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
                let file = dir.appending(path: "\(index)/card.json")
                guard let record = CardRecord.read(file) else { continue }
                log.error("\(file.path) says \(record.ref) of \(record.project) was being worked on, but that project is no longer in config.toml: check the card in the backlog (it may still be marked working), then delete \(file.path)")
            }
        }
    }

    func adopt(_ ref: SlotRef, record: CardRecord, card: Card) {
        update(ref) {
            $0.phase = .busy
            $0.card = card
            $0.branch = record.branch
            $0.base = record.base
            $0.ciRound = record.ciRound
            $0.ciCommit = record.ciCommit
            $0.spawnedAt = record.claimedAt
            $0.prepared = true
        }
    }

    func releaseAfterRestart(_ ref: SlotRef, card: Card) async {
        do {
            try await deps.backlog.release(card, reason: "The Manager restarted and the worker was gone without an outcome.", countsAsAttempt: false)
        } catch {
            log.error("can't release \(card.ref): \(error); the stranded-card sweep retries")
        }
        await recycle(ref, keepOutcome: false)
    }

    // MARK: Refresh and prepare

    /// Clones or fetches the project, resets its working tree to the base branch and reloads
    /// its contract, as a task. Runs at startup and every 5 minutes.
    func startRefresh(_ key: String) {
        guard let p = projects[key], !p.refreshing else { return }
        projects[key]!.refreshing = true
        let spec = p.spec, clone = p.clone, git = deps.git, forge = deps.forge
        track {
            var failure: String?
            var base: String?
            var contract: ProjectContract?
            var contractError: String?
            do {
                try await git.cloneOrFetch(url: forge.cloneURL(for: spec), into: clone, environment: forge.gitEnvironment())
                let b: String
                if let configured = spec.baseBranch { b = configured } else { b = try await forge.defaultBranch(for: spec) }
                base = b
                try await git.syncCheckout(clone, base: b)
            } catch {
                failure = "refreshing \(spec.path) in \(clone.path) failed: \(error)"
            }
            if failure == nil {
                do { contract = try ProjectContract.load(from: ProjectContract.directory(for: spec, clone: clone)) }
                catch { contractError = "\(error)" }
            }
            await self.refreshDone(key, base: base, contract: contract, failure: failure, contractError: contractError)
        }
    }

    func refreshDone(_ key: String, base: String?, contract: ProjectContract?, failure: String?, contractError: String?) {
        guard var p = projects[key] else { return }
        let wasReady = p.ready
        p.refreshing = false
        p.lastRefresh = clock.now()
        if let failure {
            p.error = failure
            log.error("\(failure); \(p.contract == nil ? "not serving it" : "keeping the cached clone"), retrying in \(Int(Self.refreshInterval / 60)) min")
        } else if let contract {
            p.base = base
            p.contract = contract
            p.contractLoaded = true
            p.error = nil
        } else {
            p.base = base
            p.contractLoaded = false
            p.error = "not served: \(contractError ?? "no project contract")"
            log.error("\(p.spec.path) is \(p.error!); add the contract and it is picked up at the next refresh")
        }
        projects[key] = p
        if p.ready && !wasReady {
            log.info("serving \(p.spec.path) on base \(p.base ?? "?") with \(p.slots.count) \(p.spec.hot ? "hot" : "cold") slot(s)")
            fillSoon = true
        }
        prepareUnprepared(key)
    }

    func prepareUnprepared(_ key: String) {
        guard let p = projects[key], p.ready, p.spec.hot, !p.removing, let contract = p.contract else { return }
        for s in p.slots where !s.prepared && s.phase == .idle && s.task == nil && !s.retiring {
            let ref = SlotRef(key: key, id: s.id)
            update(ref) { $0.task = .preparing }
            track { await self.prepareTask(ref, contract: contract) }
        }
    }

    func prepareTask(_ ref: SlotRef, contract: ProjectContract) async {
        guard let spec = slot(ref)?.spec else { return }
        do {
            try await deps.lifecycle.prepare(spec, contract: contract)
            update(ref) {
                $0.phase = .idle
                $0.prepared = true
                $0.task = nil
                $0.lastError = nil
                $0.engineDown = false
            }
            log.info("\(label(spec)) is ready")
            fillSoon = true
        } catch {
            markBroken(ref, error)
        }
        retireIfDue(ref)
    }

    /// Retires the slot when a shrink or a project removal waits for it and nothing runs on it.
    /// Called wherever a slot's task ends, and for every slot each tick as a backstop.
    func retireIfDue(_ ref: SlotRef) {
        guard let s = slot(ref), s.task == nil, s.phase != .busy,
              s.retiring || projects[ref.key]?.removing == true else { return }
        retire(ref)
    }

    func retireAllDue() {
        for key in order {
            for s in projects[key]?.slots ?? [] { retireIfDue(SlotRef(key: key, id: s.id)) }
        }
    }

    /// Returns broken slots to service 180 s after their last attempt: cold slots go back to
    /// the pool, hot slots are prepared again. Engine-down slots first get one shared engine
    /// recovery; if it fails they all wait another round.
    func reviveBrokenSlots(_ now: Date) {
        var due: [SlotRef] = []
        for key in order {
            guard let p = projects[key], !p.removing else { continue }
            for s in p.slots where s.phase == .broken && s.task == nil && !s.retiring {
                if let last = s.lastAttemptFinished, now.timeIntervalSince(last) < Self.reviveAfter { continue }
                due.append(SlotRef(key: key, id: s.id))
            }
        }
        guard !due.isEmpty else { return }
        for ref in due { update(ref) { $0.task = .preparing } }
        let engineNeeded = due.contains { slot($0)?.engineDown == true }
        let engine = deps.engine
        if engineNeeded { log.warning("recovering the container engine before retrying broken slots") }
        let refs = due
        track {
            let engineOK = engineNeeded ? await engine.recover() : true
            await self.revive(refs, engineOK: engineOK)
        }
    }

    func revive(_ due: [SlotRef], engineOK: Bool) async {
        for ref in due {
            defer { retireIfDue(ref) }
            guard let s = slot(ref), let p = projects[ref.key] else { continue }
            if s.engineDown && !engineOK {
                update(ref) {
                    $0.task = nil
                    $0.lastAttemptFinished = clock.now()
                }
                log.warning("\(label(s.spec)) stays broken: the container engine is still down")
                continue
            }
            if !p.spec.hot {
                update(ref) {
                    $0.phase = .idle
                    $0.task = nil
                    $0.engineDown = false
                }
                log.info("\(label(s.spec)) is back in the pool; its next card provisions it")
                fillSoon = true
                continue
            }
            guard let contract = p.contract else {
                update(ref) {
                    $0.task = nil
                    $0.lastAttemptFinished = clock.now()
                }
                continue
            }
            await prepareTask(ref, contract: contract)
        }
    }

    // MARK: Stranded cards

    func holds(_ ref: CardRef) -> Bool {
        projects.values.contains { $0.slots.contains { $0.card?.ref == ref } }
    }

    /// Releases `working` cards that no slot holds. A failed read changes nothing; each card
    /// is re-read before its release so a finish that just moved it is not undone.
    func sweepStranded() {
        let specs = order.compactMap { projects[$0]?.spec }
        guard !specs.isEmpty else { return }
        let backlog = deps.backlog, log = self.log
        track {
            let cards: [Card]
            do { cards = try await backlog.working(in: specs) }
            catch {
                log.warning("stranded-card sweep: can't read working cards: \(error); changing nothing")
                return
            }
            for card in cards {
                guard await !self.holds(card.ref),
                      let fresh = try? await backlog.card(card.ref), fresh.state == .working,
                      await !self.holds(card.ref) else { continue }
                do {
                    try await backlog.release(fresh, reason: "The Manager lost track of this card's worker.", countsAsAttempt: false)
                    log.warning("released \(card.ref): no slot of this Manager held it")
                } catch {
                    log.error("can't release stranded \(card.ref): \(error); retrying at the next sweep")
                }
            }
        }
    }

    // MARK: Auth gate

    func startAuthPreflight() {
        authGate.checking = true
        let runner = deps.runner, env = deps.environment
        track {
            let r = await AuthGate.preflight(runner: runner, environment: env)
            if Task.isCancelled { return }
            await self.authChecked(ok: r.ok, detail: r.detail)
        }
    }

    func authChecked(ok: Bool, detail: String) {
        let wasOK = authGate.health == .ok
        switch authGate.record(ok: ok, detail: detail, at: clock.now()) {
        case .failed(let why)?:
            log.error("claude login check failing: \(why); claiming nothing until it passes")
            notify(key: "auth-failure", "LoopWorker on \(hostName): claude login check failing (\(why)); claims paused")
        case .recovered?:
            log.info("claude login check recovered; claiming again")
            notify(key: "auth-recovered", "LoopWorker on \(hostName): claude login recovered; claims resumed")
        case nil:
            break
        }
        if ok && !wasOK { fillSoon = true }
    }

    // MARK: Live config reload

    func reloadConfigIfChanged(_ now: Date) {
        if let last = lastReloadCheck, now.timeIntervalSince(last) < Self.reloadInterval { return }
        lastReloadCheck = now
        let modified = modificationDate(configFile)
        guard modified != configModified else { return }
        configModified = modified
        let next: HostConfig
        do { next = try HostConfig.load(home: config.home) }
        catch {
            log.error("\(configFile.path) changed but can't be used: \(error); keeping the current config")
            return
        }
        apply(next)
    }

    func apply(_ new: HostConfig) {
        var next = new
        if Budget.bandSize(maxSlots: new.maxSlots) > bandSize {
            log.warning("config.toml: max_slots \(new.maxSlots) needs wider port bands; every project stays capped at \(bandSize) slots until a restart")
        }
        if new.backlogKind != config.backlogKind || new.forgeKind != config.forgeKind || new.clonesDir != config.clonesDir
            || new.notifyCommand != config.notifyCommand || new.engine != config.engine {
            log.warning("config.toml: backlog, forge, clones_dir, notify_command and [engine] changes take effect after a restart")
            next.backlogKind = config.backlogKind
            next.forgeKind = config.forgeKind
            next.clonesDir = config.clonesDir
            next.notifyCommand = config.notifyCommand
            next.engine = config.engine
        }
        let newKeys = new.projects.map(\.key)
        var added: [String] = []
        for key in order where !newKeys.contains(key) && projects[key]?.removing == false {
            projects[key]!.removing = true
            log.info("\(projects[key]!.spec.path) was removed from the config; it claims nothing and retires its slots as they go idle")
            for i in projects[key]!.slots.indices { projects[key]!.slots[i].retiring = true }
            for s in projects[key]!.slots { retireIfDue(SlotRef(key: key, id: s.id)) }
            removeProjectIfDone(key)
        }
        for var spec in new.projects {
            guard var p = projects[spec.key] else {
                addProject(spec)
                added.append(spec.key)
                log.info("config.toml added \(spec.path)")
                continue
            }
            if p.removing {
                p.removing = false
                log.info("\(spec.path) is back in the config")
            }
            if spec.hot != p.spec.hot {
                log.warning("\(spec.path): hot changed to \(spec.hot); that takes effect after a restart")
                spec.hot = p.spec.hot
            }
            if spec.contract != p.spec.contract || spec.baseBranch != p.spec.baseBranch { p.lastRefresh = nil }
            if spec != p.spec { log.info("config.toml changed \(spec.path)") }
            p.spec = spec
            for i in p.slots.indices { p.slots[i].spec.project = spec }
            projects[spec.key] = p
        }
        next.projects = new.projects.map { projects[$0.key]?.spec ?? $0 }
        config = next
        order = newKeys + order.filter { !newKeys.contains($0) && projects[$0] != nil }
        resizeAll()
        for key in added { startRefresh(key) }
    }
}
