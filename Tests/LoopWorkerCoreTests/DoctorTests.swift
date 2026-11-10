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
    func openReviewRequest(for project: ProjectSpec, sourceBranch: String) async throws -> ReviewRequest? { nil }
    func reviewFeedback(for review: ReviewRequest, project: ProjectSpec, vouchedAt: Date?) async throws -> ReviewFeedback { ReviewFeedback() }
    func postReviewNote(_ text: String, marker: String, on review: ReviewRequest, project: ProjectSpec) async throws -> Bool { false }
    func replyToThread(_ thread: String, text: String, marker: String, on review: ReviewRequest, project: ProjectSpec) async throws -> ThreadReply { .noSuchThread }
    func attach(_ file: URL, to project: ProjectSpec) async throws -> URL? { nil }
    func merge(_ review: ReviewRequest, project: ProjectSpec, head: String) async throws -> MergeResult { .merged(commit: nil) }
    func pipeline(for project: ProjectSpec, commit: String) async throws -> PipelineStatus? { nil }
    func baselineJobs(for project: ProjectSpec, ref: String, names: [String]) async throws -> [String: CIJobBaseline] { [:] }
    func retryJobs(project: ProjectSpec, jobs: [CIJob]) async throws -> Bool { false }
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
        backends: Error? = nil,
        backlog: FakeBacklog = FakeBacklog(),
        quarantined: Set<String> = []
    ) -> Doctor {
        Doctor(
            home: home, environment: ["PATH": bin.path].merging(environment) { _, new in new }, runner: runner, git: git,
            servicePath: [bin.path],
            credentialVariables: { _ in ["GL_TOKEN"] },
            makeBackends: { _, env in
                if let backends { throw backends }
                #expect(env["GL_TOKEN"] == Self.token)
                return (backlog, DiagnosableForge(forgeCheck))
            },
            executable: bin.appending(path: "loopworker"),
            isQuarantined: { quarantined.contains($0.lastPathComponent) })
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

    @Test("B251: doctor runs the card query per project and fails with its error")
    func cardQueryRunsPerProject() async throws {
        let backlog = FakeBacklog()
        backlog.add(Card(ref: CardRef(id: "1", display: "g/app#1"), project: "g/app", number: "1", title: "t", state: .ready))
        #expect(check(await doctor(backlog: backlog).run(), "backlog gitlab cards g/app")?.detail == "the card query answered: 1 ready")
        #expect(backlog.state.get.workableCalls == [["g/app"]])

        backlog.state {
            $0.failWorkable = true
            $0.workableError = "GET /issues: 400 scope is invalid"
        }
        let checks = await doctor(backlog: backlog).run()
        let c = try #require(check(checks, "backlog gitlab cards g/app"))
        #expect(c.level == .fail && c.detail == "the card query failed: GET /issues: 400 scope is invalid")
        #expect(!Doctor.passed(checks))
        #expect(backlog.writes.isEmpty)
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

    @Test("B213: a deprecated config key is a warning")
    func deprecatedKeyWarns() async throws {
        try config("[backlog]\nkind = \"gitlab\"\n[[project]]\npath = \"g/app\"\ndraft = false\n")
        let checks = await doctor().run()
        let warnings = checks.filter { $0.name == "config" && $0.level == .warn }
        #expect(warnings.map(\.detail) == ["config.toml: g/app: draft is deprecated; replace it with finish = \"ready\""])
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

    @Test("B183: a quarantined tool or loopworker binary fails with the xattr remedy, and claude isn't run")
    func quarantinedBinariesFail() async throws {
        let real = home.appending(path: "Caskroom/claude")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: bin.appending(path: "claude"), to: real)
        try FileManager.default.createSymbolicLink(at: bin.appending(path: "claude"), withDestinationURL: real)
        let runner = ScriptedRunner()
        let checks = await doctor(runner: runner, quarantined: ["claude", "loopworker"]).run()
        let claude = check(checks, "tool claude")
        #expect(claude?.level == .fail)
        #expect(claude?.detail.contains("\(real.resolvingSymlinksInPath().path) carries com.apple.quarantine") == true)
        #expect(claude?.detail.contains("GUI session") == true)
        #expect(claude?.remedy == "xattr -d com.apple.quarantine \(real.resolvingSymlinksInPath().path)")
        #expect(check(checks, "tool loopworker")?.remedy == "xattr -d com.apple.quarantine \(bin.appending(path: "loopworker").path)")
        #expect(check(checks, "tool git")?.level == .ok)
        #expect(check(checks, "claude login") == nil)
        #expect(!runner.specs.get.contains { $0.executable == "claude" })
        #expect(!Doctor.passed(checks))
    }

    @Test func quarantineReadsTheRealAttribute() throws {
        let file = home.appending(path: "flagged")
        try Data().write(to: file)
        #expect(!Quarantine.isFlagged(file))
        #if canImport(Darwin)
        let value = "0081;00000000;Test;"
        #expect(setxattr(file.path, Quarantine.attribute, value, value.utf8.count, 0, 0) == 0)
        #expect(Quarantine.isFlagged(file))
        #endif
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

    @Test func renderIndentsEveryLineOfARemedy() {
        let text = Doctor.render([DoctorCheck("a", .fail, "broken", remedy: "pick one:\nx: 1\ny: 2")])
        #expect(text == "FAIL a  broken\n     -> pick one:\n        x: 1\n        y: 2\n")
    }

    @Test func aMissingHomeFails() async throws {
        let d = Doctor(
            home: home.appending(path: "nope"), environment: ["PATH": bin.path], runner: ScriptedRunner(), git: FakeGit(), servicePath: [bin.path],
            credentialVariables: { _ in [] }, makeBackends: { _, _ in (FakeBacklog(), FakeForge()) })
        let checks = await d.run()
        #expect(check(checks, "home")?.level == .fail)
    }

    @Test("B248: agent instructions in or above clones_dir warn, except the user's own ~/.claude")
    func instructionsAboveClonesDir() throws {
        let root = try temporaryDirectory()
        let fm = FileManager.default
        let clones = root.appending(path: "a/b/clones")
        for dir in ["a/.claude/rules", "a/b/.claude/rules", "a/b/clones"] {
            try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        for file in ["AGENTS.md", "a/CLAUDE.md", "a/b/clones/CLAUDE.local.md"] { try Data("@AGENTS.md\n".utf8).write(to: root.appending(path: file)) }
        let checks = Doctor.instructionsAbove(clonesDir: clones, home: root.appending(path: "a/b"), root: root)
        #expect(checks.allSatisfy { $0.level == .warn && $0.name == "clones_dir" })
        #expect(checks.map { $0.detail.components(separatedBy: " is in or above").first! }.sorted() == [
            clones.appending(path: "CLAUDE.local.md").path, root.appending(path: "a/CLAUDE.md").path,
            root.appending(path: "a/.claude/rules").path, root.appending(path: "AGENTS.md").path,
        ].sorted())
        #expect(checks.contains { $0.remedy == "move clones_dir out of \(root.appending(path: "a").path), or move that file" })

        let clean = root.appending(path: "a/b/clones/sub")
        try fm.removeItem(at: root.appending(path: "a/b/clones/CLAUDE.local.md"))
        let ok = Doctor.instructionsAbove(clonesDir: clean, home: nil, root: root.appending(path: "a/b"))
        #expect(ok.count == 1 && ok.first?.level == .warn && ok.first?.detail.hasPrefix(root.appending(path: "a/b/.claude/rules").path) == true)
        #expect(Doctor.instructionsAbove(clonesDir: clean, home: root.appending(path: "a/b"), root: root.appending(path: "a/b"))
                == [DoctorCheck("clones_dir", .ok, "no agent instructions in or above \(clean.path)")])
    }

    @Test("B248: a file reached through a symlinked clones_dir is reported once; .claude/AGENTS.md counts")
    func instructionsAboveASymlinkedClonesDir() throws {
        let root = try temporaryDirectory().resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "real/.claude"), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: root.appending(path: "real/CLAUDE.md"))
        try Data("x\n".utf8).write(to: root.appending(path: "real/.claude/AGENTS.md"))
        try fm.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "real"))
        let checks = Doctor.instructionsAbove(clonesDir: root.appending(path: "link/clones"), home: nil, root: root)
        #expect(checks.map { $0.detail.components(separatedBy: " is in or above").first! } == [
            root.appending(path: "link/CLAUDE.md").path, root.appending(path: "link/.claude/AGENTS.md").path,
        ])
    }
}
