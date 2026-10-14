import Foundation
import LoopWorkerCore
import Testing
@testable import loopworker

/// Answers `launchctl print` with `loaded` and records every call; never runs launchctl.
private final class FakeLaunchctl: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    let loaded: Bool
    init(loaded: Bool) { self.loaded = loaded }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        #expect(spec.executable == "launchctl")
        lock.withLock { recorded.append(spec.arguments) }
        return ProcessResult(status: spec.arguments.first == "print" && !loaded ? 113 : 0, output: "")
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}

@Suite struct ServiceTests {
    let root: URL
    let lines = Lines()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "lw-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func service(_ runner: any ProcessRunning) -> LaunchdService {
        let lines = self.lines
        return LaunchdService(
            binary: "/opt/homebrew/bin/loopworker", home: root.appending(path: "lwhome"), userHome: root.appending(path: "user"),
            userName: "builder", uid: 501, runner: runner, output: { lines.add($0) })
    }

    func parse(_ url: URL) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    @Test func B155_agentPlistRunsTheBinaryWithHomePathAndStopBudget() async throws {
        let launchctl = FakeLaunchctl(loaded: false)
        let s = service(launchctl)
        try await s.install(daemon: false, dryRun: false)
        let job = try parse(s.agentPlist)
        #expect(job["Label"] as? String == "dev.nevyn.loopworker")
        #expect(job["ProgramArguments"] as? [String] == ["/opt/homebrew/bin/loopworker", "run"])
        let env = try #require(job["EnvironmentVariables"] as? [String: String])
        #expect(env["LOOPWORKER_HOME"] == root.appending(path: "lwhome").path)
        let path = try #require(env["PATH"]).split(separator: ":")
        #expect(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].allSatisfy { path.contains(Substring($0)) })
        #expect(job["RunAtLoad"] as? Bool == true)
        #expect(job["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
        #expect(job["ThrottleInterval"] as? Int == 30)
        #expect(job["ExitTimeOut"] as? Int == 180)
        #expect(job["StandardOutPath"] as? String == root.appending(path: "lwhome/state/manager.out").path)
        #expect(job["StandardErrorPath"] as? String == job["StandardOutPath"] as? String)
        #expect(job["ProcessType"] as? String == "Background")
        #expect(job["UserName"] == nil)
        #expect(launchctl.calls == [["print", "gui/501/dev.nevyn.loopworker"], ["bootstrap", "gui/501", s.agentPlist.path]])
    }

    @Test func reinstallingBootsOutTheLoadedJobFirst() async throws {
        let launchctl = FakeLaunchctl(loaded: true)
        try await service(launchctl).install(daemon: false, dryRun: false)
        #expect(launchctl.calls.map(\.first) == ["print", "bootout", "bootstrap"])
    }

    @Test func B155_daemonPlistNamesTheUserAndIsOnlyStaged() async throws {
        let launchctl = FakeLaunchctl(loaded: false)
        let s = service(launchctl)
        try await s.install(daemon: true, dryRun: false)
        let job = try parse(s.stagedDaemonPlist)
        #expect(job["UserName"] as? String == "builder")
        #expect((job["EnvironmentVariables"] as? [String: String])?["HOME"] == root.appending(path: "user").path)
        #expect(launchctl.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.agentPlist.path))
        #expect(lines.text.contains("sudo launchctl bootstrap system /Library/LaunchDaemons/dev.nevyn.loopworker.plist"))
        #expect(lines.text.contains("sudo chown root:wheel"))
    }

    @Test func dryRunWritesNothingAndRunsNothing() async throws {
        let launchctl = FakeLaunchctl(loaded: false)
        let s = service(launchctl)
        try await s.install(daemon: false, dryRun: true)
        try await s.install(daemon: true, dryRun: true)
        #expect(launchctl.calls.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(lines.text.contains("<key>ProgramArguments</key>"))
    }

    @Test func uninstallBootsOutAndRemovesTheAgent() async throws {
        let s = service(FakeLaunchctl(loaded: false))
        try await s.install(daemon: false, dryRun: false)
        let launchctl = FakeLaunchctl(loaded: true)
        try await service(launchctl).uninstall()
        #expect(launchctl.calls.map(\.first) == ["print", "bootout"])
        #expect(!FileManager.default.fileExists(atPath: s.agentPlist.path))
    }

    @Test func aFailedBootstrapNamesTheCommand() async throws {
        struct Failing: ProcessRunning {
            func run(_ spec: ProcessSpec) async throws -> ProcessResult {
                ProcessResult(status: spec.arguments.first == "print" ? 113 : 5, output: "Bootstrap failed: 5: Input/output error\n")
            }
        }
        let error = await #expect(throws: CompositionError.self) { try await service(Failing()).install(daemon: false, dryRun: false) }
        #expect(error?.description.contains("launchctl bootstrap gui/501") == true)
        #expect(error?.description.contains("Input/output error") == true)
    }

    @Test func invokedPathKeepsSymlinksAndSearchesPath() throws {
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let exe = bin.appending(path: "loopworker")
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        #expect(invokedBinaryPath("loopworker", environment: ["PATH": "/nonexistent:\(bin.path)"]) == exe.path)
        #expect(invokedBinaryPath("/a/b/../c/loopworker") == "/a/c/loopworker")
    }
}
