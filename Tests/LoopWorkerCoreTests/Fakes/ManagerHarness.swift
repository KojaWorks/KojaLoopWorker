import Foundation
@testable import LoopWorkerCore

/// A clock that only moves when the test advances it. `sleep` returns at once.
final class TestClock: ManagerClock, @unchecked Sendable {
    let time = Guarded(Date())
    func now() -> Date { time.get }
    func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
    func advance(_ seconds: TimeInterval) { time { $0 += seconds } }
}

/// A Manager wired to fakes in a fresh `LOOPWORKER_HOME`, with each project's contract
/// already in place where the clone will be.
final class ManagerHarness: @unchecked Sendable {
    let home: URL
    let backlog: FakeBacklog
    let forge: FakeForge
    let tmux = FakeTmux()
    let git: FakeGit
    let lifecycle = FakeLifecycle()
    let engine = FakeEngine()
    let runner = ScriptedRunner()
    let log = CollectingLog()
    let clock = TestClock()
    let environment: [String: String]
    private(set) var manager: Manager!

    static let defaultEnvironment = ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-fabricated", "FORWARD_ME": "yes"]

    /// - Parameters:
    ///   - projects: `[[project]]` tables.
    ///   - top: top-level keys, before any table.
    ///   - sharing: another install whose backlog, forge and remote this one uses, as a second host would.
    init(projects: String, top: String = "", manifest: String = "", environment: [String: String] = defaultEnvironment,
         sharing other: ManagerHarness? = nil) throws {
        home = try temporaryDirectory()
        backlog = other?.backlog ?? FakeBacklog()
        forge = other?.forge ?? FakeForge()
        git = other?.git ?? FakeGit()
        self.environment = environment
        lifecycle.state { [git] in $0.tip = { git.state.get.remoteTips[$0] } }
        try writeConfig(projects: projects, top: top)
        let config = try HostConfig.load(home: home)
        for p in config.projects { try writeContract(p, manifest: manifest) }
        manager = makeManager(config)
    }

    var clones: URL { home.appending(path: "clones") }

    func writeConfig(projects: String, top: String = "") throws {
        let text = """
            clones_dir = "\(clones.path)"
            \(top)

            [backlog]
            kind = "fake"

            \(projects)
            """
        let file = home.appending(path: "config.toml")
        try text.write(to: file, atomically: true, encoding: .utf8)
        // A rewrite within the same second must still look changed.
        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date()
        try FileManager.default.setAttributes([.modificationDate: mtime.addingTimeInterval(Double.random(in: 1...1000))], ofItemAtPath: file.path)
    }

    func writeContract(_ p: ProjectSpec, manifest: String = "") throws {
        let dir = clones.appending(path: "\(p.key)/.loopworker")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appending(path: "manifest.toml"), atomically: true, encoding: .utf8)
    }

    func makeManager(_ config: HostConfig) -> Manager {
        let deps = ManagerDependencies(
            backlog: backlog, forge: forge, runner: runner, tmux: tmux, git: git, lifecycle: lifecycle,
            engine: engine, log: log, recentLines: { [log] in log.recentLines() },
            redact: { $0.replacingOccurrences(of: "SECRET", with: "[REDACTED]") },
            pane: PaneReading(showsAuthFailure: { $0.contains("Please run /login · API Error") },
                              trustPromptKeys: { $0.contains("trust this folder") ? ["Enter"] : nil }),
            environment: environment)
        return Manager(config: config, dependencies: deps, clock: clock)
    }

    /// A second Manager on the same home and fakes, as after a restart. The old one's lock is
    /// released first.
    func restart() throws {
        manager.heldLock.release()
        manager = makeManager(try HostConfig.load(home: home))
    }

    /// Starts the Manager and runs the first tick, after which the clone is refreshed and the
    /// auth preflight has passed, so the next tick fills.
    func boot() async throws {
        try await manager.start()
        await manager.settle()
        await cycle()
    }

    /// One tick, its tasks run to completion, and a status file that reflects them.
    func cycle() async {
        await manager.tick()
        await manager.settle()
        await manager.writeStatus(clock.now())
    }

    func stateDir(_ key: String = "g--app", _ index: Int = 0) -> URL {
        home.appending(path: "slots/\(key)/\(index)")
    }

    func session(_ key: String = "g--app", _ index: Int = 0) -> String { "lw_\(key)_\(index)" }

    @discardableResult
    func addCard(_ n: Int, project: String = "g/app", title: String = "Fix it", attempts: Int = 0,
                 state: CardState = .ready, priority: Double = 0) -> Card {
        backlog.add(Card(ref: CardRef(id: "id-\(n)", display: "\(project)#\(n)"), project: project, number: "\(n)",
                         title: title, state: state, priority: priority, attempts: attempts,
                         url: URL(string: "https://forge.example/\(project)/-/issues/\(n)")))
    }

    func writeOutcome(_ json: String, key: String = "g--app", index: Int = 0) throws {
        try json.write(to: stateDir(key, index).appending(path: "outcome.json"), atomically: true, encoding: .utf8)
    }

    func status() throws -> ManagerStatus {
        try ManagerStatus.read(from: ManagerStatus.file(stateDir: home.appending(path: "state")))
    }
}
