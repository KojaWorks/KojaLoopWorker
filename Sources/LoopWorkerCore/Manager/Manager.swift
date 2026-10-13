import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Time for the Manager loop, injectable so tests run ticks instantly.
public protocol ManagerClock: Sendable {
    func now() -> Date
    /// Suspends for `seconds`. Throws when the task is cancelled.
    func sleep(seconds: Double) async throws
}

public struct SystemClock: ManagerClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

/// Everything the Manager talks to. The CLI builds the real ones; tests pass fakes.
public struct ManagerDependencies: Sendable {
    public var backlog: any Backlog
    public var forge: any Forge
    public var runner: any ProcessRunning
    public var tmux: any TmuxDriving
    public var git: any GitDriving
    public var lifecycle: any SlotLifecycle
    public var engine: any EngineRecovering
    public var log: any LogSink
    /// The most recent redacted log lines, for the status file.
    public var recentLines: @Sendable () -> [String]
    /// Redacts secret-shaped substrings. Applied to pane text before it reaches the backlog,
    /// the status file or a notification, which don't pass through the `LogSink`.
    public var redact: @Sendable (String) -> String
    public var pane: PaneReading
    /// The process environment with `secrets.env` overlaid. `CLAUDE_CODE_OAUTH_TOKEN` and each
    /// project's `worker_env` names are looked up here for the worker and the auth preflight.
    public var environment: [String: String]

    public init(
        backlog: any Backlog, forge: any Forge, runner: any ProcessRunning, tmux: any TmuxDriving,
        git: any GitDriving, lifecycle: any SlotLifecycle, engine: any EngineRecovering, log: any LogSink,
        recentLines: @escaping @Sendable () -> [String], redact: @escaping @Sendable (String) -> String,
        pane: PaneReading, environment: [String: String]
    ) {
        self.backlog = backlog
        self.forge = forge
        self.runner = runner
        self.tmux = tmux
        self.git = git
        self.lifecycle = lifecycle
        self.engine = engine
        self.log = log
        self.recentLines = recentLines
        self.redact = redact
        self.pane = pane
        self.environment = environment
    }
}

/// How the Manager reacts to a stop signal.
public enum StopRequest: Sendable, Equatable {
    /// SIGINT.
    case interrupt
    /// SIGTERM.
    case terminate
}

public enum StopResponse: Sendable, Equatable {
    case draining, forcing
    /// The third SIGINT: the caller exits with status 130 at once. The lock is already released.
    case exitNow
}

/// The deterministic daemon: reconciles busy slots, fills free ones and keeps project clones
/// and slot pools in line with the host config. See DESIGN.md.
///
/// `run()` is the production loop. Tests call `start()`, then `tick()` and `settle()`.
public actor Manager {
    enum Phase: String { case idle, busy, broken }
    enum SlotTask: String { case preparing, starting, finishing, releasing, recycling, retiring }

    struct Slot {
        let id = UUID()
        var spec: SlotSpec
        var phase: Phase = .idle
        var task: SlotTask?
        /// Hot slots: provisioned by `prepare`. Cold slots are always true.
        var prepared: Bool
        var card: Card?
        var branch: String?
        var base: String?
        var spawnedAt: Date?
        var lastError: String?
        var lastAttemptFinished: Date?
        var engineDown = false
        var retiring = false
        var finishFailures = 0
        var finishRetryAt: Date?
        var finishError: String?
        /// The last redacted pane lines, newest last.
        var pane: [String] = []
    }

    struct Project {
        var spec: ProjectSpec
        var band: Int
        var clone: URL
        /// The last contract that loaded; busy slots keep using it when a reload fails.
        var contract: ProjectContract?
        var contractLoaded = false
        var base: String?
        var error: String?
        var refreshing = false
        var lastRefresh: Date?
        var removing = false
        var slots: [Slot] = []
        var ready: Bool { contractLoaded && contract != nil && base != nil }
    }

    struct SlotRef: Hashable, Sendable {
        var key: String
        var id: UUID
    }

    static let tickInterval: Double = 15
    static let fillInterval: TimeInterval = 60
    static let refreshInterval: TimeInterval = 300
    static let sweepInterval: TimeInterval = 300
    static let reloadInterval: TimeInterval = 60
    static let reviveAfter: TimeInterval = 180

    var config: HostConfig
    let deps: ManagerDependencies
    let clock: any ManagerClock
    let notifier: Notifier
    let hostName: String
    /// Slots per port band, fixed at startup so a live `max_slots` change never moves a band.
    let bandSize: Int
    /// The Manager's lock, for a signal handler that must release it without awaiting the actor.
    public nonisolated let heldLock = LockBox()

    var projects: [String: Project] = [:]
    var order: [String] = []
    var tasks: [UUID: Task<Void, Never>] = [:]
    var authGate = AuthGate()
    var authReleasedThisTick = false
    var cleanFinishPending = false
    var started: Date
    var draining = false
    var forceRequested = false
    var interrupts = 0
    /// The signal that asked for a force stop, for the final log line.
    var stopSignal: String?
    var lastFill: Date?
    var fillSoon = false
    var lastSweep: Date?
    var lastReloadCheck: Date?
    var configModified: Date?
    var lastStatusError: String?

    public init(config: HostConfig, dependencies: ManagerDependencies, clock: any ManagerClock = SystemClock()) {
        self.config = config
        self.deps = dependencies
        self.clock = clock
        self.notifier = Notifier(command: config.notifyCommand, runner: dependencies.runner, log: dependencies.log,
                                 now: { clock.now() })
        self.hostName = Self.currentHostName()
        self.bandSize = Budget.bandSize(maxSlots: config.maxSlots)
        self.started = clock.now()
    }

    var log: any LogSink { deps.log }
    var stateDir: URL { config.stateDir }
    var configFile: URL { config.home.appending(path: "config.toml") }

    // MARK: Lifecycle

    /// Takes the lock, adopts or cleans up the previous Manager's workers, and starts the
    /// project refreshes, the stranded-card sweep and the notifier self-test.
    /// - Throws: `ManagerLock.Held` when another Manager runs for this home.
    public func start() async throws {
        heldLock.set(try ManagerLock.acquire(at: ManagerLock.file(stateDir: stateDir), log: log))
        started = clock.now()
        configModified = modificationDate(configFile)
        let token = deps.environment["CLAUDE_CODE_OAUTH_TOKEN"].map { $0.isEmpty ? "empty" : "set" } ?? "not set"
        log.info("LoopWorker \(LoopWorkerVersion) starting on \(hostName), pid \(getpid()), home \(config.home.path)")
        log.info("budget \(config.maxSlots) slot units, at most \(config.maxConcurrentWorkers) workers, max \(config.maxAttempts) attempts; backlog \(config.backlogKind), forge \(config.forgeKind); CLAUDE_CODE_OAUTH_TOKEN \(token)")
        if config.projects.isEmpty { log.warning("no [[project]] in \(configFile.path); idling until one is added") }

        for spec in config.projects { addProject(spec) }
        resizeAll()
        var adopted: Set<String> = []
        for key in order { adopted.formUnion(await adoptPreviousWorkers(key)) }
        await reapUnadoptedSessions(adopted)
        reportUnconfiguredCards()
        for key in order { startRefresh(key) }
        lastSweep = clock.now()
        sweepStranded()
        if await notifier.enabled {
            notify(key: "started", "LoopWorker started on \(hostName)")
        } else {
            log.warning("notify_command is not set: alerts are DISABLED (slot broken, auth failing, card stuck)")
        }
    }

    /// Runs until a drain or force stop completes. Releases the lock on return.
    public func run() async throws {
        try await start()
        defer { heldLock.release() }
        let reason: String
        while true {
            if forceRequested {
                await forceStop()
                reason = "force-stopped after \(stopSignal ?? "a stop request")"
                break
            }
            await tick()
            if draining && !hasBusySlot {
                await cancelTasks()
                reason = "drained: no worker was left running"
                break
            }
            // One-second steps so a SIGTERM doesn't wait out the whole interval.
            for _ in 0..<Int(Self.tickInterval) where !forceRequested {
                try? await clock.sleep(seconds: 1)
            }
        }
        writeStatus(clock.now())
        log.info("stopped: \(reason)")
    }

    /// Escalates on each SIGINT: drain, then force, then exit. SIGTERM forces at once.
    public func handle(_ request: StopRequest) -> StopResponse {
        if request == .terminate {
            log.warning("SIGTERM: force-stopping; reaping \(busyCount) worker(s) and releasing cards that have no outcome")
            stopSignal = "SIGTERM"
            forceRequested = true
            return .forcing
        }
        interrupts += 1
        switch interrupts {
        case 1:
            draining = true
            log.warning("SIGINT: draining; \(busyCount) worker(s) still running, no new claims (send SIGINT again to force)")
            return .draining
        case 2:
            forceRequested = true
            stopSignal = "a second SIGINT"
            log.warning("second SIGINT: force-stopping; reaping \(busyCount) worker(s) and releasing cards that have no outcome (send SIGINT again to exit at once)")
            return .forcing
        default:
            log.error("third SIGINT: stopped at once; workers and stacks may be left running")
            dumpState()
            heldLock.release()
            return .exitNow
        }
    }

    /// Waits until every task the Manager started has finished. For tests.
    public func settle() async {
        while let next = tasks.values.first {
            await next.value
        }
    }

    /// One pass of the loop. Only fast work runs here; everything slow is started as a task.
    public func tick() async {
        let now = clock.now()
        reloadConfigIfChanged(now)
        for key in order where !(projects[key]?.refreshing ?? true) {
            if let last = projects[key]?.lastRefresh, now.timeIntervalSince(last) < Self.refreshInterval { continue }
            startRefresh(key)
        }
        await reconcileBusySlots(now)
        if forceRequested { return }  // run() force-stops next; don't start new work first
        retireAllDue()
        reviveBrokenSlots(now)
        if let last = lastSweep, now.timeIntervalSince(last) >= Self.sweepInterval {
            lastSweep = now
            sweepStranded()
        }
        if authGate.needsCheck(at: now) { startAuthPreflight() }
        if fillSoon || lastFill.map({ now.timeIntervalSince($0) >= Self.fillInterval }) ?? true {
            await fill(now)
        }
        if !authReleasedThisTick && cleanFinishPending && authGate.noteCleanFinish() {
            log.info("auth backoff cleared: a worker finished cleanly")
        }
        authReleasedThisTick = false
        cleanFinishPending = false
        writeStatus(now)
    }

    /// Force stop: cancels running tasks, reaps every worker, releases each card that has no
    /// outcome (cards with an outcome stay `working` for the next start to finish), and
    /// recycles cold slots. Hot stacks stay up.
    func forceStop() async {
        await cancelTasks()
        for key in order {
            guard let p = projects[key] else { continue }
            for slot in p.slots where slot.phase == .busy {
                guard let card = slot.card else { continue }
                try? await deps.tmux.kill(slot.spec.session)
                if FileManager.default.fileExists(atPath: slot.spec.outcomeFile.path) {
                    log.info("\(label(slot.spec)): left \(card.ref) working; its outcome is finished on the next start")
                    continue
                }
                do {
                    try await deps.backlog.release(card, reason: "LoopWorker released this card: the Manager stopped before the worker finished.", countsAsAttempt: false)
                    log.info("\(label(slot.spec)): released \(card.ref) (Manager stopped)")
                } catch {
                    log.error("\(label(slot.spec)): can't release \(card.ref): \(error); the next start's stranded-card sweep releases it")
                }
                try? FileManager.default.removeItem(at: cardRecordFile(slot.spec))
                if !p.spec.hot, let contract = p.contract { await deps.lifecycle.recycle(slot.spec, contract: contract) }
            }
        }
        log.info("force-stopped")
    }

    func cancelTasks() async {
        for t in tasks.values { t.cancel() }
        await settle()
    }

    // MARK: Tasks and helpers

    /// Starts `body` as a tracked task; `settle()` and stopping wait for it.
    func track(_ body: @escaping @Sendable () async -> Void) {
        let id = UUID()
        tasks[id] = Task {
            await body()
            self.taskDone(id)
        }
    }

    private func taskDone(_ id: UUID) { tasks[id] = nil }

    func notify(key: String, _ message: String) {
        let text = deps.redact(message)
        let notifier = self.notifier
        track { await notifier.send(key: key, text) }
    }

    var busyCount: Int { projects.values.reduce(0) { $0 + $1.slots.filter { $0.phase == .busy }.count } }
    var hasBusySlot: Bool { busyCount > 0 }

    func label(_ spec: SlotSpec) -> String { "\(spec.project.path) slot \(spec.index)" }

    func slot(_ ref: SlotRef) -> Slot? { projects[ref.key]?.slots.first { $0.id == ref.id } }

    /// Mutates the slot if it still exists; returns false when it was retired meanwhile.
    @discardableResult
    func update(_ ref: SlotRef, _ body: (inout Slot) -> Void) -> Bool {
        guard let i = projects[ref.key]?.slots.firstIndex(where: { $0.id == ref.id }) else { return false }
        body(&projects[ref.key]!.slots[i])
        return true
    }

    func cardRecordFile(_ spec: SlotSpec) -> URL { spec.stateDir.appending(path: "card.json") }

    var hostPaused: Bool { FileManager.default.fileExists(atPath: KillSwitch.file(stateDir: stateDir).path) }
    func projectPaused(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: KillSwitch.file(stateDir: stateDir, projectKey: key).path)
    }

    func modificationDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private func dumpState() {
        for key in order {
            for s in projects[key]?.slots ?? [] {
                log.info("state: \(label(s.spec)) \(s.phase.rawValue) task=\(s.task?.rawValue ?? "-") card=\(s.card?.ref.display ?? "-") session=\(s.spec.session)")
            }
        }
    }

    private static func currentHostName() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "unknown-host" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Status file

    func writeStatus(_ now: Date) {
        let status = ManagerStatus(
            pid: getpid(), host: hostName, started: started, updated: now, paused: hostPaused, draining: draining,
            auth: .init(state: authGate.health.rawValue, detail: authGate.detail.map(deps.redact),
                        backoffUntil: authGate.backoffUntil.flatMap { $0 > now ? $0 : nil }),
            projects: order.compactMap { key in
                guard let p = projects[key] else { return nil }
                return .init(
                    path: p.spec.path, key: key, hot: p.spec.hot, ready: p.ready, error: p.error.map(deps.redact),
                    paused: projectPaused(key), removing: p.removing,
                    slots: p.slots.map { s in
                        .init(index: s.spec.index, state: s.phase.rawValue, task: s.task?.rawValue,
                              card: s.card?.ref.display, cardURL: s.card?.url, branch: s.branch,
                              runningFor: s.spawnedAt.map { now.timeIntervalSince($0).rounded() },
                              lastError: (s.finishError ?? s.lastError).map(deps.redact), port: s.spec.port, pane: Array(s.pane.suffix(5)),
                              finishFailing: s.finishFailures >= 3, retiring: s.retiring)
                    })
            },
            log: Array(deps.recentLines().suffix(50)))
        do {
            try status.write(to: ManagerStatus.file(stateDir: stateDir))
            lastStatusError = nil
        } catch {
            let message = "can't write \(ManagerStatus.file(stateDir: stateDir).path): \(error)"
            if message != lastStatusError { log.error(message) }
            lastStatusError = message
        }
    }
}

/// Holds the Manager's lock so a signal handler can release it without awaiting the actor.
public final class LockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var held: ManagerLock?

    func set(_ l: ManagerLock) {
        lock.lock()
        held = l
        lock.unlock()
    }

    /// Releases the lock if held. Safe from any thread, more than once.
    public func release() {
        lock.lock()
        let l = held
        held = nil
        lock.unlock()
        l?.release()
    }
}
