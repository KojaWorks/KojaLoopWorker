import Foundation
import Testing
@testable import LoopWorkerCore

/// Thread-safe collector for values that callbacks deliver on other threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
    var current: Value { withLock { $0 } }
}

/// Waits up to `limit` for `condition`, polling every 20 ms.
func eventually(within limit: Duration = .seconds(2), _ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

func processIsGone(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

@Suite struct ProcessRunnerTests {
    let runner = ProcessRunner()

    @Test("B08: output and a non-zero exit are a result")
    func outputAndStatus() async throws {
        let result = try await runner.run(ProcessSpec("sh", ["-c", "echo hello; echo oops >&2; exit 3"], timeout: .seconds(5)))
        #expect(result.status == 3)
        #expect(result.output == "hello\noops\n")
        #expect(!result.timedOut)
        #expect(!result.succeeded)
    }

    @Test("B08: a missing executable throws, naming it")
    func missingExecutable() async throws {
        let error = try await #require(throws: ProcessStartError.self) {
            try await runner.run(ProcessSpec("lw-no-such-binary", timeout: .seconds(5)))
        }
        #expect(error.code == ENOENT)
        #expect(error.description.contains("lw-no-such-binary"))
    }

    @Test func workingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lw-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await runner.run(ProcessSpec("pwd", workingDirectory: directory, timeout: .seconds(5)))
        #expect(URL(filePath: result.output.trimmingCharacters(in: .newlines)).resolvingSymlinksInPath().path
            == directory.resolvingSymlinksInPath().path)
        await #expect(throws: ProcessStartError.self) {
            try await runner.run(ProcessSpec("pwd", workingDirectory: directory.appending(path: "missing"), timeout: .seconds(5)))
        }
    }

    @Test("B01: a timeout kills the whole process group")
    func timeoutKillsGroup() async throws {
        let start = ContinuousClock.now
        let result = try await runner.run(ProcessSpec("sh", ["-c", "sleep 60 & echo $!; wait"], timeout: .seconds(1)))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(result.timedOut)
        #expect(result.status == -SIGKILL)
        #expect(!result.succeeded)
        let background = try #require(pid_t(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(try await eventually { processIsGone(background) })
    }

    @Test("B05: a grandchild holding the pipe doesn't block the return")
    func grandchildHoldsPipe() async throws {
        let start = ContinuousClock.now
        let result = try await runner.run(ProcessSpec("sh", ["-c", "echo $$; (sleep 30 &); echo hi"], timeout: .seconds(20)))
        #expect(ContinuousClock.now - start < .seconds(8))
        let lines = result.output.split(separator: "\n")
        #expect(lines.last == "hi")
        if let group = lines.first.flatMap({ pid_t($0) }) { killpg(group, SIGKILL) }
    }

    @Test("B05: lines after the drain are dropped")
    func lateLinesDropped() async throws {
        let lines = Locked<[String]>([])
        let script = "echo $$; (sleep 1; echo late) & echo early"
        let runner = ProcessRunner(drainLimit: .milliseconds(200))
        let result = try await runner.run(ProcessSpec("sh", ["-c", script], timeout: .seconds(20)) { line in
            lines.withLock { $0.append(line) }
        })
        try await Task.sleep(for: .seconds(1.5))
        #expect(lines.current.last == "early")
        #expect(!result.output.contains("late"))
        if let group = lines.current.first.flatMap({ pid_t($0) }) { killpg(group, SIGKILL) }
    }

    @Test("B03: stdin is /dev/null")
    func stdinIsDevNull() async throws {
        let result = try await runner.run(ProcessSpec("cat", timeout: .seconds(5)))
        #expect(result.succeeded)
        #expect(result.output == "")
    }

    @Test("B04: GIT_TERMINAL_PROMPT=0 always, and nil removes a variable")
    func environment() async throws {
        let script = #"echo "$GIT_TERMINAL_PROMPT ${HOME-unset} $LW_ADDED""#
        let result = try await runner.run(ProcessSpec(
            "sh", ["-c", script], environment: ["HOME": nil, "LW_ADDED": "yes", "GIT_TERMINAL_PROMPT": "1"],
            timeout: .seconds(5)))
        #expect(result.output == "0 unset yes\n")
    }

    @Test("B09: onLine gets redacted lines, including a final partial line")
    func onLineRedacts() async throws {
        let lines = Locked<[String]>([])
        let result = try await ProcessRunner(secrets: ["hunter2"]).run(ProcessSpec(
            "sh", ["-c", "echo token glpat-AbC123; echo pw hunter2; printf partial"], timeout: .seconds(5)
        ) { line in lines.withLock { $0.append(line) } })
        #expect(lines.current == ["token [REDACTED]", "pw [REDACTED]", "partial"])
        #expect(result.output.contains("glpat-AbC123"))
    }

    @Test("B06: output larger than the pipe buffer doesn't deadlock")
    func largeOutput() async throws {
        let result = try await runner.run(ProcessSpec("sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' x"], timeout: .seconds(5)))
        #expect(result.succeeded)
        #expect(result.output.count == 300_000)
    }

    @Test("B07: cancelling the task kills the process group")
    func cancellationKillsGroup() async throws {
        let background = Locked<pid_t?>(nil)
        let task = Task {
            try await runner.run(ProcessSpec("sh", ["-c", "sleep 60 & echo $!; wait"], timeout: .seconds(30)) { line in
                background.withLock { $0 = pid_t(line) }
            })
        }
        #expect(try await eventually { background.current != nil })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let pid = try #require(background.current)
        #expect(try await eventually { processIsGone(pid) })
    }
}
