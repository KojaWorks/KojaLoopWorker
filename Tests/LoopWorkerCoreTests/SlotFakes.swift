import Foundation
@testable import LoopWorkerCore

/// Runs nothing. Each executable gets a scripted handler (default: exit 0, no output); every
/// call is recorded. Output lines reach `onLine` with `SECRET` redacted, like the real runner.
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    typealias Handler = @Sendable (ProcessSpec) async throws -> ProcessResult
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var recorded: [ProcessSpec] = []

    func on(_ executable: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[executable] = handler }
    }

    var calls: [ProcessSpec] { lock.withLock { recorded } }

    func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        let handler = lock.withLock {
            recorded.append(spec)
            return handlers[spec.executable]
        }
        let result = try await handler?(spec) ?? ProcessResult(status: 0, output: "")
        for line in result.output.split(separator: "\n", omittingEmptySubsequences: false) {
            spec.onLine?(line.replacingOccurrences(of: "SECRET", with: "[REDACTED]"))
        }
        return result
    }
}

final class SlotTestLog: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(LogLevel, String)] = []

    func log(_ level: LogLevel, _ message: String) { lock.withLock { entries.append((level, message)) } }

    var lines: [String] { lock.withLock { entries.map(\.1) } }
    func lines(_ level: LogLevel) -> [String] { lock.withLock { entries.filter { $0.0 == level }.map(\.1) } }
}
