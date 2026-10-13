import Foundation
@testable import LoopWorkerCore

/// Records every `ProcessSpec` and answers from `handler`, so no test runs a real `claude`.
final class ScriptedRunner: ProcessRunning, @unchecked Sendable {
    let specs = Guarded<[ProcessSpec]>([])
    let handler: Guarded<@Sendable (ProcessSpec) -> ProcessResult>

    init(_ handler: @escaping @Sendable (ProcessSpec) -> ProcessResult = { _ in ProcessResult(status: 0, output: "") }) {
        self.handler = Guarded(handler)
    }

    func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        specs { $0.append(spec) }
        return handler.get(spec)
    }
}

/// Runs real processes with Foundation's `Process`, for tests that need a real shell. It has
/// none of the production runner's guarantees beyond stdin and the timeout.
struct ShellRunner: ProcessRunning {
    func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/env")
        p.arguments = [spec.executable] + spec.arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in spec.environment { env[k] = v }
        p.environment = env
        p.currentDirectoryURL = spec.workingDirectory
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ProcessResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// Collects log lines in memory.
final class CollectingLog: LogSink, @unchecked Sendable {
    let lines = Guarded<[(level: LogLevel, message: String)]>([])

    func log(_ level: LogLevel, _ message: String) {
        lines { $0.append((level, message)) }
    }

    var messages: [String] { lines.get.map(\.message) }
    func contains(_ fragment: String, level: LogLevel? = nil) -> Bool {
        lines.get.contains { (level == nil || $0.level == level) && $0.message.contains(fragment) }
    }
    func recentLines() -> [String] { lines.get.map { "\($0.level.rawValue.uppercased()) \($0.message)" } }
}
