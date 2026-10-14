import Foundation
import Testing
@testable import LoopWorkerCore

/// Records every spec and answers with `respond`.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ProcessSpec] = []
    private let respond: @Sendable (ProcessSpec) -> ProcessResult

    init(_ respond: @escaping @Sendable (ProcessSpec) -> ProcessResult = { _ in ProcessResult(status: 0, output: "") }) {
        self.respond = respond
    }

    var calls: [ProcessSpec] { lock.withLock { recorded } }

    func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        lock.withLock { recorded.append(spec) }
        return respond(spec)
    }
}

/// Runs real processes with `base` as the inherited environment beneath each spec's own.
struct BaseEnvironmentRunner: ProcessRunning {
    var base: [String: String]
    func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        var spec = spec
        spec.environment = base.mapValues { Optional($0) }.merging(spec.environment) { _, own in own }
        return try await ProcessRunner().run(spec)
    }
}

@Suite struct TmuxTests {
    let socket = FileManager.default.temporaryDirectory.appending(path: "lw-tmux-\(UUID().uuidString)/state/tmux")

    func tmux(_ respond: @escaping @Sendable (ProcessSpec) -> ProcessResult = { _ in ProcessResult(status: 0, output: "") }) -> (Tmux, FakeRunner) {
        let runner = FakeRunner(respond)
        return (Tmux(runner: runner, socket: socket, scrubbedVariables: ["GITLAB_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"]), runner)
    }

    static let failed = ProcessResult(status: 1, output: "server exited unexpectedly\n")
    static let timedOut = ProcessResult(status: -9, output: "", timedOut: true)

    @Test("B11, B12, B15: own socket, 10 s timeout, token variables removed")
    func everyCommand() async throws {
        let (tmux, runner) = tmux()
        try await tmux.sendKeys("lw_a_1", ["Enter"])
        let spec = try #require(runner.calls.first)
        #expect(spec.executable == "tmux")
        #expect(spec.arguments == ["-S", socket.path, "send-keys", "-t", "=lw_a_1:", "Enter"])
        #expect(spec.timeout == .seconds(10))
        #expect(spec.environment.count == 2)
        #expect(spec.environment["GITLAB_TOKEN"] == .some(nil))
        #expect(spec.environment["CLAUDE_CODE_OAUTH_TOKEN"] == .some(nil))
        #expect(FileManager.default.fileExists(atPath: socket.deletingLastPathComponent().path))
    }

    @Test("B13: sessions filters by prefix")
    func sessions() async throws {
        let (tmux, runner) = tmux { _ in ProcessResult(status: 0, output: "lw_a_1\nlw_ab_1\nmine\n") }
        #expect(try await tmux.sessions(prefix: "lw_a_") == ["lw_a_1"])
        #expect(runner.calls[0].arguments.dropFirst(2) == ["list-sessions", "-F", "#{session_name}"])
    }

    @Test("B13: no server is no sessions", arguments: [
        "error connecting to /x/state/tmux (No such file or directory)\n", "no server running on /x/state/tmux\n",
    ])
    func sessionsWithoutServer(output: String) async throws {
        let (tmux, _) = tmux { _ in ProcessResult(status: 1, output: output) }
        #expect(try await tmux.sessions(prefix: "lw_") == [])
    }

    @Test("B11, B13: any other failure throws", arguments: [failed, timedOut])
    func sessionsFailure(result: ProcessResult) async throws {
        let (tmux, _) = tmux { _ in result }
        await #expect(throws: TmuxError.self) { try await tmux.sessions(prefix: "lw_") }
    }

    @Test func spawn() async throws {
        let (tmux, runner) = tmux()
        try await tmux.spawn(session: "lw_a_1", directory: URL(filePath: "/w/1"), script: URL(filePath: "/s/1/launch.sh"))
        #expect(runner.calls[0].arguments.dropFirst(2) == ["new-session", "-d", "-s", "lw_a_1", "-c", "/w/1", "'/s/1/launch.sh'"])

        let (failing, _) = self.tmux { _ in Self.failed }
        await #expect(throws: TmuxError.self) {
            try await failing.spawn(session: "lw_a_1", directory: URL(filePath: "/w"), script: URL(filePath: "/s/launch.sh"))
        }
        await #expect(throws: TmuxError.self) {
            try await tmux.spawn(session: "lw_a_1", directory: URL(filePath: "/w"), script: URL(filePath: "/s/it's.sh"))
        }
    }

    @Test("B14: alive unless gone or back at a shell", arguments: [
        ("lw_a_1:claude\n", true), ("lw_a_1:node\n", true), ("lw_a_1:zsh\n", false), ("lw_a_1:-bash\n", false),
        ("lw_a_1:fish\n", false), ("lw_a_1:login\n", false), ("\n", false), ("lw_a_10:claude\n", false),
    ])
    func isAlive(output: String, alive: Bool) async throws {
        let (tmux, runner) = tmux { _ in ProcessResult(status: 0, output: output) }
        #expect(try await tmux.isAlive("lw_a_1") == alive)
        #expect(runner.calls[0].arguments.dropFirst(2)
            == ["display-message", "-p", "-t", "=lw_a_1:", "#{session_name}:#{pane_current_command}"])
    }

    @Test("B11, B14: a missing session is dead, a timeout or other failure throws")
    func isAliveFailures() async throws {
        let (missing, _) = tmux { _ in ProcessResult(status: 1, output: "can't find session: lw_a_1\n") }
        #expect(try await missing.isAlive("lw_a_1") == false)
        let (noServer, _) = tmux { _ in ProcessResult(status: 1, output: "no server running on /x\n") }
        #expect(try await noServer.isAlive("lw_a_1") == false)
        for result in [Self.failed, Self.timedOut] {
            let (tmux, _) = tmux { _ in result }
            await #expect(throws: TmuxError.self) { try await tmux.isAlive("lw_a_1") }
        }
    }

    @Test func capture() async throws {
        let (tmux, runner) = tmux { _ in ProcessResult(status: 0, output: "pane text\n") }
        #expect(try await tmux.capture("lw_a_1", lines: 40) == "pane text\n")
        #expect(runner.calls[0].arguments.dropFirst(2) == ["capture-pane", "-p", "-t", "=lw_a_1:", "-S", "-40"])
        let (failing, _) = self.tmux { _ in Self.failed }
        await #expect(throws: TmuxError.self) { try await failing.capture("lw_a_1", lines: 40) }
    }

    @Test("B19: killing a missing session is not an error")
    func kill() async throws {
        let (tmux, runner) = tmux { _ in ProcessResult(status: 1, output: "can't find session: lw_a_1\n") }
        try await tmux.kill("lw_a_1")
        #expect(runner.calls[0].arguments.dropFirst(2) == ["kill-session", "-t", "=lw_a_1"])
        let (noServer, _) = self.tmux { _ in ProcessResult(status: 1, output: "error connecting to /x (No such file or directory)\n") }
        try await noServer.kill("lw_a_1")
        for result in [Self.failed, Self.timedOut] {
            let (failing, _) = self.tmux { _ in result }
            await #expect(throws: TmuxError.self) { try await failing.kill("lw_a_1") }
        }
    }

    static let tmuxOnPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .contains { FileManager.default.isExecutableFile(atPath: "\($0)/tmux") }

    @Test("B12, B14, B15, B19: a real session on a private server", .enabled(if: tmuxOnPath, "tmux is not on PATH"))
    func realTmux() async throws {
        // Unix socket paths are limited to 104 bytes, too short for the per-user temporary directory.
        let directory = URL(filePath: "/tmp/lw-test-\(UUID().uuidString)")
        let socket = directory.appending(path: "tmux")
        let runner = BaseEnvironmentRunner(base: ["LW_TEST_SECRET": "fabricated-secret", "LW_TEST_PLAIN": "visible"])
        let tmux = Tmux(runner: runner, socket: socket, scrubbedVariables: ["LW_TEST_SECRET"])
        func raw(_ arguments: [String]) async throws -> ProcessResult {
            try await ProcessRunner().run(ProcessSpec("tmux", ["-S", socket.path] + arguments, timeout: .seconds(10)))
        }
        #expect(try await tmux.sessions(prefix: "lw_") == [])

        let script = directory.appending(path: "launch.sh")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "#!/bin/sh\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            try await tmux.spawn(session: "lw_t_1", directory: directory, script: script)
            #expect(try await tmux.sessions(prefix: "lw_t_") == ["lw_t_1"])
            var alive = false
            for _ in 0..<50 where !alive {
                alive = try await tmux.isAlive("lw_t_1")
                if !alive { try await Task.sleep(for: .milliseconds(50)) }
            }
            #expect(alive)
            #expect(try await tmux.isAlive("lw_t_") == false)

            let environment = try await raw(["show-environment", "-g"]).output
            #expect(environment.contains("LW_TEST_PLAIN=visible"))
            #expect(!environment.contains("LW_TEST_SECRET"))

            try await tmux.kill("lw_t_1")
            #expect(try await tmux.isAlive("lw_t_1") == false)
            try await tmux.kill("lw_t_1")
        } catch {
            _ = try? await raw(["kill-server"])
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        _ = try? await raw(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
    }
}
