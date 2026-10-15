import Foundation
import LoopWorkerCore
import NotionBackend
import Testing
@testable import loopworker

@Suite struct CompositionTests {
    func config(_ workerEnv: String = "") throws -> HostConfig {
        let home = FileManager.default.temporaryDirectory.appending(path: "lw-cli-\(UUID().uuidString)")
        return try HostConfig.parse("""
            [backlog]
            kind = "gitlab"

            [backlog.gitlab]
            base_url = "https://gitlab.invalid"
            token_env = "GL_LOOPWORKER"
            allowed = ["g/"]

            [[project]]
            path = "g/app"
            worker_env = [\(workerEnv)]
            """, home: home)
    }

    let environment = ["GL_LOOPWORKER": "fabricated-gitlab-token-value", "PATH": "/bin"]

    @Test func aBackendTokenIsSecretWhateverItsName() throws {
        #expect(try secretVariables(config: try config(), environment: environment) == ["GL_LOOPWORKER"])
        let deps = try makeDependencies(config: try config(), environment: environment)
        #expect(!deps.redact("token fabricated-gitlab-token-value here").contains("fabricated-gitlab-token-value"))
    }

    @Test func workerEnvCannotForwardABackendToken() throws {
        let error = #expect(throws: CompositionError.self) {
            try makeDependencies(config: try config(#""GL_LOOPWORKER""#), environment: environment)
        }
        #expect(error?.description.contains("g/app: GL_LOOPWORKER") == true)
    }

    @Test func B187_workerEnvCannotForwardTheNotionToken() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "lw-cli-\(UUID().uuidString)")
        let config = try HostConfig.parse("""
            [backlog]
            kind = "notion"
            [forge]
            kind = "gitlab"
            [forge.gitlab]
            base_url = "https://gitlab.invalid"
            token_env = "GL_LOOPWORKER"
            [backlog.notion]
            trusted_users = ["0123456789abcdef0123456789abcdef"]
            [backlog.notion.projects]
            "g/app" = "fedcba9876543210fedcba9876543210"
            [[project]]
            path = "g/app"
            """, home: home)
        #expect(try credentialVariables(config: config) == ["GL_LOOPWORKER", "LOOPWORKER_NOTION_TOKEN"])
        let notionEnv = environment.merging(["LOOPWORKER_NOTION_TOKEN": "fabricated-notion-token-value"]) { $1 }
        let deps = try makeDependencies(config: config, environment: notionEnv)
        #expect(deps.backlog is NotionBacklog)
        #expect(!deps.redact("fabricated-notion-token-value").contains("fabricated-notion-token-value"))

        var leaky = config
        leaky.projects[0].workerEnv = ["LOOPWORKER_NOTION_TOKEN"]
        let error = #expect(throws: CompositionError.self) { try makeDependencies(config: leaky, environment: notionEnv) }
        #expect(error?.description.contains("g/app: LOOPWORKER_NOTION_TOKEN") == true)
    }
}
