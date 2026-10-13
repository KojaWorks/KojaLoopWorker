import Foundation

/// The real `SlotLifecycle`: git through `GitDriving`, lifecycle scripts through `ProcessRunning`.
///
/// Each script runs as `bash <contract dir>/<script>` from the slot's worktree (from the clone
/// when the worktree is gone), with `LOOPWORKER_SLOT_DIR`, `LOOPWORKER_PORT` and
/// `LOOPWORKER_PROJECT` set, under the contract's timeout for that script. Every output line is
/// logged as `[<project key>/<slot index> <script>] <line>`, and while the script runs a
/// "still running" line is logged every min(300 s, timeout / 2).
public struct ScriptedSlotLifecycle: SlotLifecycle {
    let runner: ProcessRunning
    let git: GitDriving
    let log: LogSink
    let gitRemote: @Sendable (ProjectSpec) -> (url: String, environment: [String: String])

    /// - Parameters:
    ///   - runner: Runs the lifecycle scripts.
    ///   - git: Creates, resets, detaches and removes slot worktrees.
    ///   - log: Receives script output, progress and best-effort failures.
    ///   - gitRemote: A project's forge clone URL and git environment (askpass credentials),
    ///     passed to the fetch in `acquire`.
    public init(
        runner: ProcessRunning, git: GitDriving, log: LogSink,
        gitRemote: @escaping @Sendable (ProjectSpec) -> (url: String, environment: [String: String])
    ) {
        self.runner = runner
        self.git = git
        self.log = log
        self.gitRemote = gitRemote
    }

    public func prepare(_ slot: SlotSpec, contract: ProjectContract) async throws(SlotFailure) {
        guard slot.project.hot else { return }
        try await ensureWorktree(slot)
        try await runScript(.provision, slot, contract)
    }

    public func acquire(_ slot: SlotSpec, contract: ProjectContract, base: String, branch: String) async throws(SlotFailure) -> String {
        try await ensureWorktree(slot)
        let commit: String
        do {
            let remote = gitRemote(slot.project)
            commit = try await git.resetWorktree(slot.worktree, url: remote.url, base: base, branch: branch, environment: remote.environment)
        } catch {
            throw SlotFailure("\(Self.name(slot)): resetting \(slot.worktree.path) to origin/\(base) on branch \(branch) failed: \(error)")
        }
        log.info("\(Self.name(slot)): worktree at origin/\(base) @ \(commit.prefix(12)), branch \(branch)")  // a full SHA trips the redactor's hex rule
        try await runScript(slot.project.hot ? .reset : .provision, slot, contract)
        return commit
    }

    public func recycle(_ slot: SlotSpec, contract: ProjectContract) async {
        guard slot.project.hot else { return await teardown(slot, contract) }
        do { try await git.detach(slot.worktree) }
        catch { log.warning("\(Self.name(slot)): detaching HEAD in \(slot.worktree.path) failed: \(error)") }
    }

    public func retire(_ slot: SlotSpec, contract: ProjectContract) async {
        await teardown(slot, contract)
        await git.removeWorktree(clone: slot.clone, worktree: slot.worktree)
    }

    enum Script: String {
        case provision, reset, teardown

        func file(_ scripts: ProjectContract.Scripts) -> String {
            switch self {
            case .provision: scripts.provision
            case .reset: scripts.reset
            case .teardown: scripts.teardown
            }
        }

        func timeout(_ scripts: ProjectContract.Scripts) -> Duration {
            switch self {
            case .provision: scripts.provisionTimeout
            case .reset: scripts.resetTimeout
            case .teardown: scripts.teardownTimeout
            }
        }
    }

    static let tailLines = 20

    static func name(_ slot: SlotSpec) -> String { "\(slot.project.key)/\(slot.index)" }

    private func ensureWorktree(_ slot: SlotSpec) async throws(SlotFailure) {
        do { try await git.ensureWorktree(clone: slot.clone, worktree: slot.worktree, slot: slot.index) }
        catch { throw SlotFailure("\(Self.name(slot)): creating worktree \(slot.worktree.path) from \(slot.clone.path) failed: \(error)") }
    }

    private func teardown(_ slot: SlotSpec, _ contract: ProjectContract) async {
        let path = contract.directory.appending(path: Script.teardown.file(contract.scripts))
        guard FileManager.default.fileExists(atPath: path.path) else {
            return log.info("\(Self.name(slot)): no teardown script at \(path.path); skipping teardown")
        }
        do { try await runScript(.teardown, slot, contract) }
        catch { log.warning("\(Self.name(slot)): teardown incomplete: \(error)") }
    }

    private func runScript(_ script: Script, _ slot: SlotSpec, _ contract: ProjectContract) async throws(SlotFailure) {
        let file = script.file(contract.scripts)
        let path = contract.directory.appending(path: file)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw SlotFailure("\(Self.name(slot)): \(script.rawValue) script missing at \(path.path)")
        }
        let timeout = script.timeout(contract.scripts)
        let tag = "[\(Self.name(slot)) \(script.rawValue)]"
        let cwd = FileManager.default.fileExists(atPath: slot.worktree.path) ? slot.worktree : slot.clone
        let tail = LineTail(limit: Self.tailLines)
        let spec = ProcessSpec(
            "bash", [path.path],
            environment: [
                "LOOPWORKER_SLOT_DIR": slot.worktree.path,
                "LOOPWORKER_PORT": String(slot.port),
                "LOOPWORKER_PROJECT": slot.project.path,
            ],
            workingDirectory: cwd, timeout: timeout,
            onLine: { [log] line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                tail.append(line)
                log.info("\(tag) \(line)")
            })

        log.info("\(tag) running \(path.path) (timeout \(Self.describe(timeout)))")
        let watchdog = Task { [log] in
            let interval = min(Duration.seconds(300), timeout / 2)
            var elapsed = Duration.zero
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                elapsed += interval
                log.info("\(tag) still running after \(Self.describe(elapsed)) (killed at \(Self.describe(timeout)))")
            }
        }
        defer { watchdog.cancel() }

        let result: ProcessResult
        do { result = try await runner.run(spec) }
        catch is CancellationError { throw SlotFailure("\(Self.name(slot)): \(file) was cancelled") }
        catch { throw SlotFailure("\(Self.name(slot)): couldn't start \(path.path): \(error)") }
        guard !result.succeeded else { return }

        let why = result.timedOut ? "timed out after \(Self.describe(timeout))"
            : result.status < 0 ? "was killed by signal \(-result.status)"
            : "exited \(result.status)"
        let lines = tail.lines
        let output = lines.isEmpty ? "(no output)" : lines.joined(separator: "\n")
        throw SlotFailure(
            "\(Self.name(slot)): \(file) \(why); last \(lines.count) lines of output:\n\(output)",
            engineDown: EngineRecovery.looksLikeEngineDown(result.output))
    }

    /// `90 s`, `2.5 min`.
    static func describe(_ duration: Duration) -> String {
        let (seconds, atto) = duration.components
        let s = Double(seconds) + Double(atto) / 1e18
        func num(_ x: Double) -> String { x.rounded() == x ? String(Int(x)) : String(format: "%.1f", x) }
        return s >= 60 ? "\(num(s / 60)) min" : "\(num(s)) s"
    }
}

/// The last `limit` lines of a script's output; `onLine` may call in from any thread.
private final class LineTail: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ line: String) {
        lock.withLock {
            buffer.append(line)
            if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        }
    }

    var lines: [String] { lock.withLock { buffer } }
}
