import Foundation
import Testing
@testable import LoopWorkerCore

private final class DiagnosableForge: Forge, Diagnosable, @unchecked Sendable {
    let check: DoctorCheck
    init(_ check: DoctorCheck) { self.check = check }
    func cloneURL(for project: ProjectSpec) -> String { "" }
    func gitEnvironment() -> [String: String] { [:] }
    func defaultBranch(for project: ProjectSpec) async throws -> String { "main" }
    func openReviewRequest(_ draft: ReviewRequestDraft) async throws -> ReviewRequest { fatalError("unused") }
    func attach(_ file: URL, to project: ProjectSpec) async throws -> URL? { nil }
    func pipeline(for project: ProjectSpec, commit: String) async throws -> PipelineStatus? { nil }
    func diagnose() async -> [DoctorCheck] { [check] }
}

@Suite struct DoctorTests {
    static let token = "fabricated-backlog-token-0123456789"
    let home: URL
    let bin: URL

    init() throws {
        home = try temporaryDirectory()
        bin = home.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["tmux", "git", "claude", "bash", "git-lfs", "storygrafter"] { try makeTool(tool) }
        try config("""
            [backlog]
            kind = "gitlab"

            [[project]]
            path = "g/app"
            """)
        try secrets("GL_TOKEN=\(Self.token)\nCLAUDE_CODE_OAUTH_TOKEN=fabricated-claude-token-0123456789\n")
    }

    func makeTool(_ name: String) throws {
        let file = bin.appending(path: name)
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    func config(_ text: String) throws { try Data(text.utf8).write(to: home.appending(path: "config.toml")) }

    func secrets(_ text: String, mode: Int = 0o600) throws {
        let file = home.appending(path: "secrets.env")
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }

    func doctor(
        environment: [String: String] = [:],
        runner: ScriptedRunner = ScriptedRunner(),
        git: FakeGit = FakeGit(),
        forgeCheck: DoctorCheck = DoctorCheck("forge fake", .ok, "token belongs to @me"),
        backends: Error? = nil
    ) -> Doctor {
        Doctor(
            home: home, environment: ["PATH": bin.path].merging(environment) { _, new in new }, runner: runner, git: git,
            servicePath: [bin.path],
            credentialVariables: { _ in ["GL_TOKEN"] },
            makeBackends: { _, env in
                if let backends { throw backends }
                #expect(env["GL_TOKEN"] == Self.token)
                return (FakeBacklog(), DiagnosableForge(forgeCheck))
            })
    }

    func check(_ checks: [DoctorCheck], _ name: String) -> DoctorCheck? { checks.first { $0.name == name } }

    @Test func aHealthyHostPasses() async {  // B150, B151
        let checks = await doctor().run()
        #expect(Doctor.passed(checks), "\(Doctor.render(checks))")
        #expect(check(checks, "config")?.detail == "projects: g/app")
        #expect(check(checks, "forge fake")?.level == .ok)
        #expect(check(checks, "backlog gitlab")?.level == .warn)
        #expect(check(checks, "manager")?.detail == "not running")
        #expect(check(checks, "tool claude")?.detail == bin.appending(path: "claude").path)
    }

    @Test func aMalformedConfigFailsAsMalformedAndSkipsTheBackends() async throws {  // B123
        try config("[backlog\n")
        let checks = await doctor().run()
        #expect(!Doctor.passed(checks))
        #expect(check(checks, "config")?.detail.contains("config.toml:") == true)
        #expect(check(checks, "engine") == nil)
        #expect(check(checks, "forge fake") == nil)
    }

    @Test func zeroProjectsIsAWarning() async throws {
        try config("[backlog]\nkind = \"gitlab\"\n")
        let checks = await doctor().run()
        #expect(check(checks, "config")?.level == .warn)
        #expect(Doctor.passed(checks))
    }

    @Test func aReadableSecretsFileFailsWithChmod() async throws {
        try secrets("GL_TOKEN=\(Self.token)\n", mode: 0o644)
        let checks = await doctor(backends: ConfigError("GL_TOKEN is not set")).run()
        let c = check(checks, "secrets")
        #expect(c?.level == .fail)
        #expect(c?.remedy == "chmod 600 \(home.appending(path: "secrets.env").path)")
    }

    @Test func aTokenOnlyInTheShellWarnsAndAMissingOneFails() async throws {
        try secrets("")
        let shell = await doctor(environment: ["GL_TOKEN": Self.token]).run()
        #expect(check(shell, "token GL_TOKEN")?.level == .warn)
        #expect(check(shell, "token CLAUDE_CODE_OAUTH_TOKEN")?.level == .warn)
        let missing = await doctor(backends: ConfigError("GL_TOKEN is not set")).run()
        #expect(check(missing, "token GL_TOKEN")?.level == .fail)
        #expect(check(missing, "backends")?.level == .fail)
    }

    @Test func missingToolsFailOrWarnByWhatNeedsThem() async throws {
        for name in ["tmux", "git-lfs"] { try FileManager.default.removeItem(at: bin.appending(path: name)) }
        let checks = await doctor().run()
        #expect(check(checks, "tool tmux")?.level == .fail)
        let lfs = check(checks, "tool git-lfs")
        #expect(lfs?.level == .warn)
        #expect(lfs?.detail.contains("Git LFS") == true)
    }

    @Test("B162: a missing git-lfs fails once a cloned project uses Git LFS")
    func missingGitLFSFailsWhenAClonedProjectUsesIt() async throws {
        try FileManager.default.removeItem(at: bin.appending(path: "git-lfs"))
        let git = FakeGit()
        git.state { $0.usesLFS = true }
        let uncloned = await doctor(git: git).run()
        #expect(check(uncloned, "tool git-lfs")?.level == .warn)

        try FileManager.default.createDirectory(at: home.appending(path: "clones/g--app"), withIntermediateDirectories: true)
        let checks = await doctor(git: git).run()
        let lfs = check(checks, "tool git-lfs")
        #expect(lfs?.level == .fail)
        #expect(lfs?.detail == "not on PATH; projects whose clones use Git LFS: g/app")
        #expect(lfs?.remedy?.contains("brew install git-lfs") == true)
        #expect(!Doctor.passed(checks))
    }

    @Test func aToolOutsideTheServicePathWarns() async throws {
        let d = Doctor(
            home: home, environment: ["PATH": bin.path], runner: ScriptedRunner(), git: FakeGit(), servicePath: ["/usr/bin"],
            credentialVariables: { _ in [] }, makeBackends: { _, _ in (FakeBacklog(), FakeForge()) })
        let checks = await d.run()
        #expect(check(checks, "tool tmux")?.level == .warn)
        #expect(Doctor.passed(checks))
    }

    @Test func claudesLoginPromptFailsWithTheSetupTokenRemedy() async throws {  // B152
        let runner = ScriptedRunner { spec in
            spec.executable == "claude" ? ProcessResult(status: 0, output: "Not logged in \u{00B7} Please run /login\n") : ProcessResult(status: 0, output: "")
        }
        let checks = await doctor(runner: runner).run()
        let c = check(checks, "claude login")
        #expect(c?.level == .fail)
        #expect(c?.detail.contains("Not logged in") == true)
        #expect(c?.remedy?.contains("claude setup-token") == true)
        #expect(c?.remedy?.contains("CLAUDE_CODE_OAUTH_TOKEN") == true)
        let spec = runner.specs.get.first { $0.executable == "claude" }
        #expect(spec?.environment["USER"] == .some(nil))
        #expect(spec?.environment["CLAUDE_CODE_OAUTH_TOKEN"] == "fabricated-claude-token-0123456789")
    }

    @Test func aDownEngineWarnsWithTheConfiguredStartCommand() async throws {  // B151, B153
        try config("[backlog]\nkind = \"gitlab\"\n[engine]\nstart_command = \"colima start\"\n[[project]]\npath = \"g/app\"\n")
        let runner = ScriptedRunner { spec in
            spec.executable == "bash" ? ProcessResult(status: 1, output: "Cannot connect to the Docker daemon\n") : ProcessResult(status: 0, output: "")
        }
        let checks = await doctor(runner: runner).run()
        let c = check(checks, "engine")
        #expect(c?.level == .warn)
        #expect(c?.remedy?.contains("colima start") == true)
        #expect(Doctor.passed(checks))
    }

    @Test func detailsAreRedacted() async {  // B154
        let checks = await doctor(forgeCheck: DoctorCheck("forge fake", .fail, "rejected \(Self.token)", remedy: "glpat-abcdefghijklmnop")).run()
        let c = check(checks, "forge fake")
        #expect(c?.detail == "rejected \(Redactor.placeholder)")
        #expect(c?.remedy == Redactor.placeholder)
    }

    @Test func renderShowsTheRemedyOnlyForProblems() {
        let text = Doctor.render([DoctorCheck("a", .ok, "fine", remedy: "x"), DoctorCheck("bb", .fail, "broken", remedy: "fix it")])
        #expect(text == "ok   a   fine\nFAIL bb  broken\n     -> fix it\n")
    }

    @Test func aMissingHomeFails() async throws {
        let d = Doctor(
            home: home.appending(path: "nope"), environment: ["PATH": bin.path], runner: ScriptedRunner(), git: FakeGit(), servicePath: [bin.path],
            credentialVariables: { _ in [] }, makeBackends: { _, _ in (FakeBacklog(), FakeForge()) })
        let checks = await d.run()
        #expect(check(checks, "home")?.level == .fail)
    }
}
