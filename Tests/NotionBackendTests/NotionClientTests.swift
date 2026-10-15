import Foundation
import LoopWorkerCore
import Testing
@testable import NotionBackend

@Suite struct NotionConfigTests {
    @Test func B187_parsesTheDatabaseURLAndConstructionDoesNoNetworkIO() throws {
        let fake = FakeNotion()
        let backlog = try make(fake)
        #expect(fake.requests.isEmpty)
        let config = try NotionConfig.from(try hostConfig())
        #expect(config.projectPaths == [databaseID: "owner/app"])
        #expect(config.trustedUsers == [alice])
        #expect(config.tokenEnv == "LOOPWORKER_NOTION_TOKEN")
        #expect(config.stateProperty == "LoopWorker")
        _ = backlog
    }

    @Test func databaseIDForms() {
        let hex = "0123456789abcdef0123456789abcdef"
        let dashed = "01234567-89ab-cdef-0123-456789abcdef"
        #expect(NotionID.database(hex) == dashed)
        #expect(NotionID.database(dashed.uppercased()) == dashed)
        #expect(NotionID.database("https://www.notion.so/ws/My-Cards-\(hex)?v=fedcba9876543210fedcba9876543210") == dashed)
        #expect(NotionID.database("https://www.notion.so/\(dashed)#x") == dashed)
        #expect(NotionID.database("0123") == nil)
        #expect(NotionID.database("https://www.notion.so/ws/Cards") == nil)
        #expect(NotionID.database("zz23456789abcdef0123456789abcdef") == nil)
    }

    @Test func B187_trustedUsersAreRequired() throws {
        let error = #expect(throws: ConfigError.self) { try NotionConfig.from(try hostConfig(trusted: "")) }
        #expect(error?.description.contains("trusted_users is required") == true)
        let bad = #expect(throws: ConfigError.self) { try NotionConfig.from(try hostConfig(trusted: "trusted_users = [\"alice\"]")) }
        #expect(bad?.description.contains("\"alice\" is not a Notion user id") == true)
    }

    @Test func B187_aBadDatabaseIDNamesTheKey() throws {
        let error = #expect(throws: ConfigError.self) { try NotionConfig.from(try hostConfig(projects: "\"owner/app\" = \"cards\"")) }
        #expect(error?.description.contains("[backlog.notion.projects] owner/app") == true)
    }

    @Test func B187_everyProjectNeedsADatabaseAndEveryMappingAProject() throws {
        let unmapped = #expect(throws: ConfigError.self) {
            try NotionConfig.from(try hostConfig(extraProjects: "[[project]]\npath = \"owner/other\""))
        }
        #expect(unmapped?.description == "config.toml: [backlog.notion.projects] has no database for owner/other")
        let typo = #expect(throws: ConfigError.self) {
            try NotionConfig.from(try hostConfig(projects: "\"owner/app\" = \"\(databaseID)\"\n\"owner/typo\" = \"\(id(9, "d"))\""))
        }
        #expect(typo?.description.contains("owner/typo, which is not a configured [[project]]") == true)
    }

    @Test func B187_aMissingTokenNamesTheVariable() throws {
        let error = #expect(throws: ConfigError.self) {
            try NotionBackend.makeBacklog(config: try hostConfig(), log: LogRecorder(), environment: [:])
        }
        #expect(error?.description.contains("LOOPWORKER_NOTION_TOKEN is not set") == true)
        #expect(error?.description.contains("secrets.env") == true)
        #expect(try NotionBackend.credentialVariables(config: try hostConfig("token_env = \"NOTION_X\"")) == ["NOTION_X"])
    }
}

@Suite struct NotionClientTests {
    @Test func B188_aPersonsTokenIsRefused() async throws {
        let fake = FakeNotion()
        fake.addDatabase()
        fake.meID = alice
        let error = await #expect(throws: NotionError.self) { try await make(fake).workable(in: [app]) }
        #expect(error == .personToken(tokenEnv: "LOOPWORKER_NOTION_TOKEN", name: "Alice"))
        #expect(error?.description.contains("look like that person's edits") == true)
    }

    @Test func B189_everyRequestSendsTheVersionAndABearerToken() async throws {
        let fake = FakeNotion()
        fake.addDatabase()
        fake.addPage(1)
        _ = try await make(fake).workable(in: [app])
        #expect(!fake.requests.isEmpty)
        #expect(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11" })
        #expect(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer ntn_FAKE_token_value" })
        #expect(fake.requests.allSatisfy { $0.timeoutInterval == 30 })
    }

    @Test func B189_aDatabaseWithTwoDataSourcesFailsListingThem() async throws {
        let fake = FakeNotion()
        fake.addDatabase(sources: [id(1, "d5"), id(2, "d5")])
        let error = await #expect(throws: NotionError.self) { try await make(fake).workable(in: [app]) }
        guard case .dataSources(let db, let found)? = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(db == databaseID)
        #expect(found.count == 2)
        #expect(error!.description.contains(id(2, "d5")))
    }

    @Test func B192_queriesFollowCursorsToTheEnd() async throws {
        let fake = FakeNotion()
        fake.addDatabase()
        for n in 1...5 { fake.addPage(n) }
        fake.pageSize = 2
        let cards = try await make(fake).workable(in: [app])
        #expect(cards.count == 5)
        let queries = fake.requests("POST", "/v1/data_sources/\(dataSourceID)/query")
        #expect(queries.count == 3)
        let bodies = queries.map { try! JSONDecoder().decode(JSON.self, from: $0.httpBody!) }
        #expect(bodies.map { $0["start_cursor"]?.string } == [nil, "2", "4"])
        #expect(bodies.allSatisfy { $0["page_size"] == .number(100) })
    }

    @Test func B192_aFailedSecondPageThrows() async throws {
        let fake = FakeNotion()
        fake.addDatabase()
        for n in 1...3 { fake.addPage(n) }
        fake.pageSize = 2
        fake.queued["POST /v1/data_sources/\(dataSourceID)/query"] = [nil, (502, [:], .object(["message": "bad gateway"]))]
        let error = await #expect(throws: NotionError.self) { try await make(fake).workable(in: [app]) }
        #expect(error == .unavailable(request: "POST /v1/data_sources/\(dataSourceID)/query", status: 502, body: "{\"message\":\"bad gateway\"}"))
    }

    @Test func B192_anIncompleteQueryThrows() async throws {
        let fake = FakeNotion()
        fake.addDatabase()
        fake.addPage(1)
        fake.queryExtra = ["request_status": .object(["type": "incomplete", "incomplete_reason": "query_result_limit_reached"])]
        let error = await #expect(throws: NotionError.self) { try await make(fake).workable(in: [app]) }
        #expect(error == .incomplete(request: "POST /v1/data_sources/\(dataSourceID)/query", reason: "query_result_limit_reached"))
    }

    @Test func B193_a401NamesTheTokenVariable() async throws {
        let fake = FakeNotion()
        fake.queued["GET /v1/users/me"] = [(401, [:], .object(["code": "unauthorized", "message": "API token is invalid."]))]
        let error = await #expect(throws: NotionError.self) { try await make(fake).managerNotes(card(id(1, "c"))) }
        #expect(error?.description.contains("LOOPWORKER_NOTION_TOKEN") == true)
        #expect(error?.description.contains("ntn_FAKE") == false)
    }

    @Test func B193_a404OnTheDatabaseSaysToConnectTheIntegration() async throws {
        let fake = FakeNotion()
        let error = await #expect(throws: NotionError.self) { try await make(fake).workable(in: [app]) }
        #expect(error == .notConnected(database: databaseID, request: "GET /v1/databases/\(databaseID)"))
        #expect(error?.description.contains("Connections") == true)
    }

    @Test func B193_a429WaitsForRetryAfter() async throws {
        let fake = FakeNotion()
        let clock = TestClock()
        fake.queued["GET /v1/users/me"] = [(429, ["Retry-After": "7"], .object(["code": "rate_limited", "message": "slow down"]))]
        _ = try await make(fake, clock: clock).managerNotes(card(id(1, "c")))
        #expect(clock.sleeps.first == 7)
        #expect(fake.requests("GET", "/v1/users/me").count == 2)
    }

    @Test func B193_a429WithoutTheHeaderUsesTheBodysRetryAfter() async throws {
        let fake = FakeNotion()
        let clock = TestClock()
        fake.queued["GET /v1/users/me"] = [(429, [:], .object(["code": "rate_limited", "additional_data": .object(["retry_after": "4"])]))]
        _ = try await make(fake, clock: clock).managerNotes(card(id(1, "c")))
        #expect(clock.sleeps.first == 4)
    }

    @Test func B193_requestsAreSpacedAThirdOfASecondApart() async throws {
        let fake = FakeNotion()
        fake.addDatabase()
        fake.addPage(1)
        let clock = TestClock()
        _ = try await make(fake, clock: clock).workable(in: [app])
        #expect(fake.requests.count >= 3)
        #expect(clock.sleeps.count == fake.requests.count - 1)
        #expect(clock.sleeps.allSatisfy { abs($0 - 1.0 / 3) < 1e-6 })
    }

    @Test func B193_otherClientErrorsAreRejections() async throws {
        let fake = FakeNotion()
        fake.queued["GET /v1/users/me"] = [(400, [:], .object(["code": "validation_error", "message": "body failed validation"]))]
        let error = await #expect(throws: BackendRejection.self) { try await make(fake).managerNotes(card(id(1, "c"))) }
        #expect(error?.description == "GET /v1/users/me: 400 validation_error: body failed validation")
    }
}
