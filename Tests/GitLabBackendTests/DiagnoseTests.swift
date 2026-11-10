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

    @Test("B251: doctor's card query passes on a readable backlog")
    func cardQueryPasses() async throws {
        let checks = await Doctor.cardQueries(try World().backlog(), kind: "gitlab", projects: [World.app])
        #expect(checks == [DoctorCheck("backlog gitlab cards mygroup/app", .ok, "the card query answered: 1 ready")])
    }

    @Test("B251: doctor's card query fails with the server's status and message")
    func cardQueryFailsWithTheServersMessage() async throws {
        let w = World()
        w.gitlab.on("GET", "/api/v4/issues", status: 400, json: ["message": "scope does not have a valid value"])
        let check = try #require(await Doctor.cardQueries(try w.backlog(), kind: "gitlab", projects: [World.app]).first)
        #expect(check.level == .fail)
        #expect(check.detail.contains("GET /issues") && check.detail.contains("400") && check.detail.contains("scope does not have a valid value"))
        #expect(w.gitlab.requests.allSatisfy { $0.method == "GET" })
    }
}
