import Foundation
import LoopWorkerCore
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
}
