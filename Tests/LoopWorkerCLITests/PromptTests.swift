import Foundation
import LoopWorkerCore
import Testing
@testable import loopworker

/// B200: the context block of `loopworker prompt`.
@Suite struct PromptContextTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "lw-prompt-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func render(managerPid: Int32? = nil, environment: [String: String] = [:],
                credentialVariables: @escaping (HostConfig) throws -> [String] = { try loopworker.credentialVariables(config: $0) }) -> String {
        PromptContext(version: "9.9.9", binary: "/opt/bin/loopworker", home: home, homeFromEnvironment: true,
                      environment: environment, managerPid: managerPid, credentialVariables: credentialVariables).render()
    }

    func write(_ name: String, _ text: String, mode: Int = 0o600) throws {
        let file = home.appending(path: name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }

    let gitlabAndGitHub = """
        [backlog]
        kind = "gitlab"
        [backlog.gitlab]
        token_env = "LW_GITLAB"
        allowed = ["g/"]
        [forge]
        kind = "github"
        [forge.github]
        token_env = "LW_GITHUB"
        [[project]]
        path = "g/app"
        slots = 2
        hot = true
        [[project]]
        path = "g/lib"
        """

    @Test func noConfigNoSecretsNoManager() {
        let text = render()
        #expect(text.contains("loopworker 9.9.9"))
        #expect(text.contains("/opt/bin/loopworker"))
        #expect(text.contains("LOOPWORKER_HOME: \(home.path) (from the environment)"))
        #expect(text.contains("config.toml: missing"))
        #expect(text.contains("secrets.env: missing"))
        #expect(text.contains("CLAUDE_CODE_OAUTH_TOKEN: not in secrets.env"))
        #expect(text.contains("Manager: none runs"))
    }

    @Test func invalidConfigShowsTheError() throws {
        try write("config.toml", "[backlog]\n")
        #expect(render().contains("config.toml: invalid (\(home.path)/config.toml): config.toml: [backlog] kind is required"))
    }

    @Test func validConfigListsKindsAndProjects() throws {
        try write("config.toml", gitlabAndGitHub)
        let text = render()
        #expect(text.contains("backlog `gitlab`, forge `github`"))
        #expect(text.contains("project `g/app`: 2 slots, hot"))
        #expect(text.contains("project `g/lib`: 1 slot, cold"))
        #expect(text.contains("LW_GITLAB: not in secrets.env"))
        #expect(text.contains("LW_GITHUB: not in secrets.env"))
    }

    @Test func secretsShowNamesAndModeNeverValues() throws {
        try write("config.toml", gitlabAndGitHub)
        try write("secrets.env", "# comment\nLW_GITLAB = \"fabricated-secret-value-123\"\nLW_GITHUB=\nOTHER=x\n", mode: 0o644)
        let text = render(environment: ["LW_GITHUB": "fabricated-env-value-456"])
        #expect(text.contains("secrets.env: mode 644"))
        #expect(text.contains("chmod 600 \(home.path)/secrets.env"))
        #expect(text.contains("LW_GITLAB: set in secrets.env\n"))
        #expect(text.contains("LW_GITHUB: empty in secrets.env; set in this shell only"))
        #expect(!text.contains("fabricated-secret-value-123"))
        #expect(!text.contains("fabricated-env-value-456"))
        #expect(!text.contains("OTHER"))
    }

    @Test("B200: every secrets.env line that load rejects is named by its number and reason, never shown")
    func rejectedSecretsLines() throws {
        try write("secrets.env", "LW_GITLAB=x\nntn_fabricatedBareTokenValue\nexport LW_GITHUB=fabricatedExportedValue\n", mode: 0o600)
        let text = render()
        #expect(text.contains("line 2: no NAME=, so the Manager refuses to start"))
        #expect(text.contains("line 3: not a variable name, so the Manager refuses to start"))
        #expect(!text.contains("ntn_fabricatedBareTokenValue"))
        #expect(!text.contains("fabricatedExportedValue"))
    }

    @Test("B201: the secrets commands name the resolved secrets.env path")
    func secretsPath() {
        let text = Prompt.instructions(version: "1.2.3", home: URL(filePath: "/tmp/lw-home"))
        #expect(text.contains("chmod 600 '/tmp/lw-home/secrets.env'"))
        #expect(!text.contains("$LOOPWORKER_HOME/secrets.env\""))
    }

    @Test func privateSecretsAreNotFlagged() throws {
        try write("secrets.env", "CLAUDE_CODE_OAUTH_TOKEN=fabricated\n")
        let text = render()
        #expect(text.contains("secrets.env: mode 600 (\(home.path)/secrets.env)\n"))
        #expect(text.contains("CLAUDE_CODE_OAUTH_TOKEN: set in secrets.env"))
    }

    @Test func aHeldLockShowsThePid() {
        #expect(render(managerPid: 4242).contains("Manager: one runs on this home, pid 4242; don't start another"))
        #expect(render(managerPid: 0).contains("pid unknown"))
    }

    @Test("B200: a backend section that doesn't decode makes the config invalid")
    func aThrowingCredentialLookupIsAnInvalidConfig() throws {
        try write("config.toml", gitlabAndGitHub)
        let text = render(credentialVariables: { _ in throw ConfigError("[backlog.notion] trusted_users is required") })
        #expect(text.contains("config.toml: invalid (\(home.path)/config.toml): [backlog.notion] trusted_users is required"))
        #expect(!text.contains("config.toml: valid"))
        #expect(text.contains("CLAUDE_CODE_OAUTH_TOKEN: not in secrets.env"))
        #expect(text.contains("Manager: none runs"))
    }
}

/// B201: the built-in setup instructions.
@Suite struct PromptInstructionsTests {
    let home = URL(filePath: "/tmp/lw-home")

    @Test func everySectionIsPrinted() {
        let text = Prompt.instructions(version: "1.2.3", home: URL(filePath: "/tmp/lw-home"))
        let headings = ["What LoopWorker is", "Rules for you", "Ask the user", "Write config.toml", "Secrets",
                        "Prepare the backlog", "Project contract", "Verify", "Start"]
        for (n, heading) in headings.enumerated() {
            #expect(text.contains("\n## \(n + 1). \(heading)\n"))
        }
        #expect(text.contains("Run `loopworker doctor`"))
    }

    @Test("B201: code fences pair up, so no section is swallowed by an open block")
    func fencesPairUp() {
        let fences = Prompt.instructions(version: "1.2.3", home: home).split(separator: "\n").filter { $0.hasPrefix("```") }
        #expect(fences.count % 2 == 0)
    }

    @Test("B201: the secrets path is one shell word even when it contains a quote")
    func secretsPathIsShellQuoted() {
        #expect(Prompt.shellQuoted("/tmp/it's here") == #"'/tmp/it'\''s here'"#)
        let text = Prompt.instructions(version: "1.2.3", home: URL(filePath: "/tmp/it's"))
        #expect(text.contains(#"chmod 600 '/tmp/it'\''s/secrets.env'"#))
    }

    @Test("B201: the agent asks for the setup, looks up ids, never handles a token, asks before shared changes")
    func requiredRules() {
        let text = Prompt.instructions(version: "1.2.3", home: home)
        for phrase in ["Which backlog holds the cards", "Which forge hosts the code", "Which projects should LoopWorker serve",
                       "Who may vouch for cards", "Look up their Notion user ids",
                       "Never read, print or write the value of a token",
                       "Ask the user before you change a backlog that other people use"] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
    }

    @Test("B201: the agent asks how each project finishes, writes finish, and prepares the merged state")
    func finishModes() {
        let text = Prompt.instructions(version: "1.2.3", home: home)
        for phrase in ["how a finished card ends", "`ci_then_merge` waits for the pushed commit's CI",
                       #"finish      = "draft"           # draft, ready, merge or ci_then_merge"#,
                       "`loopworker::merged` if a project's `finish` is `merge` or `ci_then_merge`",
                       "also `merged` when the project's `finish` is `merge` or `ci_then_merge`"] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
        #expect(!text.contains("draft ="), "the config template still uses the deprecated draft key")
    }

    @Test func docLinksPinTheReleaseTag() {
        #expect(Prompt.docs(version: "1.2.3") == "https://github.com/KojaWorks/KojaLoopWorker/blob/v1.2.3/")
        #expect(Prompt.docs(version: "0.0.0-dev") == "https://github.com/KojaWorks/KojaLoopWorker/blob/main/")
        #expect(Prompt.instructions(version: "1.2.3", home: URL(filePath: "/tmp/lw-home")).contains("blob/v1.2.3/docs/project-contract.md"))
    }
}
