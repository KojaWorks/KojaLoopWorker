import Foundation

/// Supervises the `loopworker` Manager subprocess. The app is a supervisor + status client;
/// this is the supervisor half. It maps the app's lifecycle onto the Manager's existing
/// signal contract (see README.md "Stopping"):
///   • Stop (drain)  → SIGINT  — current workers finish, no new ones start, then it exits.
///   • Force stop     → SIGTERM — reap workers, release their cards back to Backlog.
/// and relaunches the Manager if it dies unexpectedly (crash), never when we asked it to stop.
@MainActor
final class ManagerController: ObservableObject {
    enum RunState: Equatable {
        case stopped(reason: String?)
        case starting     // launched, but its dashboard isn't serving yet
        case running
        case draining
    }

    @Published private(set) var state: RunState = .stopped(reason: nil)
    /// True while a drain was started by App-quit (vs a plain Stop) — so the UI can say "Quit now"
    /// instead of "Stop now" and mean it: force-stopping now completes the quit.
    @Published private(set) var isQuitting = false
    @Published var loopworkerPath: String?

    private var process: Process?
    private var intentionalStop = false
    private var consecutiveCrashes = 0
    private let maxConsecutiveCrashes = 3
    private var stabilityTask: Task<Void, Never>?
    private var quitReply: (() -> Void)?
    private var logHandle: FileHandle?

    /// Raw Manager stdout+stderr (incl. Python tracebacks the structured filelog never sees).
    private var outURL: URL { ConfigStore.dir.appendingPathComponent("state/manager.out") }

    init(loopworkerPath: String?) {
        self.loopworkerPath = loopworkerPath
    }

    var isRunning: Bool {
        switch state { case .running, .draining, .starting: return true; case .stopped: return false }
    }

    func start() {
        guard case .stopped = state else { return }
        guard let path = loopworkerPath else {
            state = .stopped(reason: "loopworker binary not found — install it (pipx) or set its path")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = []                 // bare host mode; the Manager reads ~/.loopworker/config.toml
        // Run from ~/.loopworker so the Manager loads its .env (PATCH_PAT) + writes state/ there,
        // exactly like the systemd unit's WorkingDirectory.
        try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        p.currentDirectoryURL = ConfigStore.dir
        // Give the Manager the user's real login PATH so it can find tmux/git/claude to run
        // workers (a Finder-launched app's PATH is minimal — see LoginEnvironment).
        p.environment = LoginEnvironment.childEnvironment()
        // Capture stdout+stderr to a file so a crash reason (a Python traceback goes to stderr,
        // NOT the structured filelog) is never silently swallowed — the app must surface it.
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: outURL)
        if let logHandle {
            p.standardOutput = logHandle
            p.standardError = logHandle
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.handleExit(status: status) }
        }
        intentionalStop = false
        do {
            try p.run()
            process = p
            state = .starting            // promoted to .running by markRunning() on first /health
            scheduleStabilityChecks()
        } catch {
            state = .stopped(reason: "failed to launch: \(error.localizedDescription)")
        }
    }

    /// A manual start clears the crash counter — the operator has intervened.
    func startFresh() {
        consecutiveCrashes = 0
        start()
    }

    /// AppState calls this the first time /health responds: the Manager is really up.
    func markRunning() {
        if case .starting = state { state = .running }
    }

    /// Graceful: let current workers finish, spawn none, then exit. (SIGINT)
    func drain() {
        guard isRunning, let pid = process?.processIdentifier else { return }
        intentionalStop = true
        state = .draining
        kill(pid, SIGINT)
    }

    /// Immediate: reap workers and release their claimed cards back to Backlog. (SIGTERM)
    func forceStop() {
        guard isRunning, let pid = process?.processIdentifier else { return }
        intentionalStop = true
        kill(pid, SIGTERM)
    }

    /// App-quit path: drain, and call `reply` only once the Manager has ACTUALLY exited — so the
    /// app can hold termination (.terminateLater) until then instead of orphaning a headless
    /// Manager. A generous safety timeout escalates SIGINT → SIGTERM → SIGKILL so a wedged
    /// Manager can't block Quit forever. Replies immediately if nothing is running.
    func beginQuitDrain(reply: @escaping () -> Void) {
        guard isRunning, let pid = process?.processIdentifier else { reply(); return }
        quitReply = reply
        intentionalStop = true
        isQuitting = true
        state = .draining
        kill(pid, SIGINT)
        Task { @MainActor in
            // A real drain waits for in-flight workers (minutes), so this is deliberately long —
            // escalation is a last resort, not the normal path (Force stop is the fast path).
            try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            guard self.quitReply != nil, let p1 = self.process?.processIdentifier else { return }
            kill(p1, SIGTERM)
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            guard self.quitReply != nil, let p2 = self.process?.processIdentifier else { return }
            kill(p2, SIGKILL)
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            self.finishQuit()   // give up waiting; let the app terminate regardless
        }
    }

    /// Best-effort on normal app termination: never orphan a running Manager. A hard Force-Quit
    /// (SIGKILL of the app) can't be intercepted — use Force stop for that.
    func terminateChildIfRunning() {
        if let pid = process?.processIdentifier { kill(pid, SIGTERM) }
    }

    private func finishQuit() {
        isQuitting = false
        let reply = quitReply
        quitReply = nil
        reply?()
    }

    /// The last few lines of the Manager's captured output — the exit reason to show a human.
    private func lastOutput() -> String {
        guard let data = try? Data(contentsOf: outURL),
              let text = String(data: data, encoding: .utf8) else { return "See state/manager.out for details." }
        let tail = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .joined(separator: " · ")
        return tail.isEmpty ? "No output captured." : String(tail.prefix(300))
    }

    /// After a launch, promote a dashboard-less run to .running at 10s, and clear the crash
    /// counter once the process has stayed up ~60s — so an isolated crash that self-heals doesn't
    /// count toward the give-up cap (only a genuine crash LOOP does). Cancelled if it exits first.
    private func scheduleStabilityChecks() {
        stabilityTask?.cancel()
        stabilityTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            if case .starting = self.state { self.state = .running }
            try? await Task.sleep(nanoseconds: 50 * 1_000_000_000)
            if self.isRunning { self.consecutiveCrashes = 0 }
        }
    }

    private func handleExit(status: Int32) {
        process = nil
        stabilityTask?.cancel()
        try? logHandle?.close()
        logHandle = nil
        if quitReply != nil {          // we were quitting; the drain finished — release the app
            consecutiveCrashes = 0
            state = .stopped(reason: nil)
            finishQuit()
            return
        }
        if intentionalStop {
            consecutiveCrashes = 0
            state = .stopped(reason: nil)
            return
        }
        // Unexpected exit = crash. Relaunch with a bounded CONSECUTIVE-crash cap so a Manager that
        // dies on startup surfaces instead of hot-looping, while a one-off crash still self-heals.
        let why = lastOutput()   // the real reason — surface it, don't swallow it
        consecutiveCrashes += 1
        guard consecutiveCrashes <= maxConsecutiveCrashes else {
            state = .stopped(reason: "Manager crashed \(consecutiveCrashes)× in a row. \(why)")
            return
        }
        state = .stopped(reason: "Manager exited (status \(status); relaunch \(consecutiveCrashes)/\(maxConsecutiveCrashes)). \(why)")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if case .stopped = self.state { self.start() }
        }
    }
}
