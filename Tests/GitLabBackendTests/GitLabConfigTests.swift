import Foundation
import LoopWorkerCore
import Testing
@testable import GitLabBackend

@Suite struct GitLabConfigTests {
    let env = ["LOOPWORKER_GITLAB_TOKEN": Fixture.token]
    let home = FileManager.default.temporaryDirectory.appending(path: "lw-gitlab-config-\(UUID())")

    func backlog(_ section: String) throws -> GitLabBacklogSettings {
        try GitLabConfig.backlog(toml: "[backlog]\nkind = \"gitlab\"\n[backlog.gitlab]\n" + section, environment: env)
    }

    @Test func defaults() throws {
        let s = try backlog(#"allowed = ["MyGroup/"]"#)
        #expect(s.connection.baseURL.absoluteString == "https://gitlab.com")
        #expect(s.connection.tokenEnv == "LOOPWORKER_GITLAB_TOKEN")
        #expect(s.allowed == ["mygroup/"])
        #expect(s.labelPrefix == "loopworker:")
        #expect(s.statusMode == StatusMode.none)
        #expect(s.statusNames == [.ready: "To do", .working: "In progress", .verifying: "In progress", .review: "In review", .stuck: "To do"])
        #expect(s.isAllowed("mygroup/App"))
        #expect(!s.isAllowed("other/app"))
    }

    @Test func aMissingTokenNamesTheKeyAndVariable() {
        let error = #expect(throws: ConfigError.self) {
            try GitLabConfig.backlog(toml: "[backlog.gitlab]\nallowed = [\"a/\"]\ntoken_env = \"MY_TOKEN\"", environment: env)
        }
        #expect(error?.description.contains("token_env names MY_TOKEN") == true)
    }

    @Test func anEmptyAllowedIsRejected() {
        let error = #expect(throws: ConfigError.self) { try backlog("allowed = []") }
        #expect(error?.description.contains("[backlog.gitlab] allowed") == true)
        #expect(throws: ConfigError.self) { try backlog("") }
    }

    @Test func anUnknownStatusModeIsRejected() {
        let error = #expect(throws: ConfigError.self) { try backlog("allowed = [\"a/\"]\nstatus_mode = \"columns\"") }
        #expect(error?.description.contains("status_mode") == true)
    }

    @Test func aBadBaseURLIsRejected() {
        #expect(throws: ConfigError.self) { try backlog("allowed = [\"a/\"]\nbase_url = \"gitlab.example.com\"") }
    }

    @Test func statusNamesOverrideDefaults() throws {
        let s = try backlog("allowed = [\"a/\"]\nbase_url = \"https://gitlab.example.com/\"\nstatus_mode = \"labels\"\n[backlog.gitlab.status]\nworking = \"Doing\"")
        #expect(s.connection.baseURL.absoluteString == "https://gitlab.example.com")
        #expect(s.statusMode == .labels)
        #expect(s.statusNames[.working] == "Doing")
        #expect(s.statusNames[.verifying] == "Doing")
        #expect(s.statusNames[.ready] == "To do")
    }

    @Test func theForgeFallsBackToTheBacklogSection() throws {
        let toml = """
            [backlog.gitlab]
            base_url = "https://gitlab.example.com"
            token_env = "BACKLOG_TOKEN"
            [forge.gitlab]
            token_env = "FORGE_TOKEN"
            """
        let c = try GitLabConfig.forge(toml: toml, environment: ["BACKLOG_TOKEN": "glpat-FAKE1", "FORGE_TOKEN": "glpat-FAKE2"])
        #expect(c.baseURL.absoluteString == "https://gitlab.example.com")
        #expect(c.token == "glpat-FAKE2")
    }

    @Test func makeBuildsOnlyTheGitLabParts() async throws {
        let log = CollectingLog()
        func make(_ toml: String) throws -> (backlog: GitLabBacklog?, forge: GitLabForge?) {
            try GitLabBackend.make(config: HostConfig.parse(toml, home: home), log: log, environment: env, transport: FakeGitLab()) { _ in }
        }
        let both = try make("[backlog]\nkind = \"gitlab\"\n[backlog.gitlab]\nallowed = [\"a/\"]")
        #expect(both.backlog != nil && both.forge != nil)
        let shared = await both.backlog!.client
        #expect(shared === both.forge!.client)

        let forgeOnly = try make("[backlog]\nkind = \"patch\"\n[forge]\nkind = \"gitlab\"")
        #expect(forgeOnly.backlog == nil && forgeOnly.forge != nil)

        let backlogOnly = try make("[backlog]\nkind = \"gitlab\"\n[backlog.gitlab]\nallowed = [\"a/\"]\n[forge]\nkind = \"github\"")
        #expect(backlogOnly.backlog != nil && backlogOnly.forge == nil)
    }
}
