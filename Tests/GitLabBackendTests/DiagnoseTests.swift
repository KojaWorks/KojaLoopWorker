import Foundation
import LoopWorkerCore
import Testing
@testable import GitLabBackend

@Suite struct DiagnoseTests {
    @Test func namesTheTokensUser() async throws {
        let (backlog, forge) = try World().make()
        let checks = await backlog.diagnose() + forge.diagnose()
        #expect(checks.map(\.name) == ["backlog gitlab", "forge gitlab"])
        #expect(checks.allSatisfy { $0.level == .ok && $0.detail.contains("LOOPWORKER_GITLAB_TOKEN belongs to @me (id 1)") })
    }

    @Test func aRejectedTokenFailsNamingTheVariable() async throws {
        let w = World()
        w.gitlab.on("GET", "/api/v4/user", status: 401, json: ["message": "401 Unauthorized"])
        let check = try await w.backlog().diagnose()[0]
        #expect(check.level == .fail)
        #expect(check.detail.contains("LOOPWORKER_GITLAB_TOKEN"))
        #expect(!check.detail.contains(Fixture.token))
        #expect(check.remedy?.contains("https://gitlab.example.com") == true)
    }
}
