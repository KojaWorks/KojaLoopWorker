import Foundation
import LoopWorkerCore
import Testing
@testable import NotionBackend

@Suite struct NotionDiagnoseTests {
    @Test func B199_aHealthySetupPasses() async throws {
        let fake = FakeNotion()
        fake.addDatabase()
        let checks = try await make(fake).diagnose()
        #expect(checks.map(\.name) == ["backlog notion", "backlog notion trusted users", "backlog notion owner/app"])
        #expect(checks.allSatisfy { $0.level == .ok })
        #expect(checks[0].detail == "LOOPWORKER_NOTION_TOKEN belongs to the integration LoopWorker in the workspace Acme (id \(botID))")
        #expect(checks[1].detail == "trusted users: Alice (\(alice))")
    }

    @Test func B199_aPersonsTokenFails() async throws {
        let fake = FakeNotion()
        fake.addDatabase()
        fake.meID = alice
        let check = try await make(fake).diagnose()[0]
        #expect(check.level == .fail)
        #expect(check.detail.contains("belongs to the person Alice"))
    }

    @Test func B199_anUntrustedIDListsTheWorkspacesPeople() async throws {
        let fake = FakeNotion()
        fake.addDatabase()
        let check = try await make(fake, config: hostConfig(trusted: "trusted_users = [\"\(botID)\", \"\(id(5, "a"))\"]")).diagnose()[1]
        #expect(check.level == .fail)
        #expect(check.detail.contains("\(botID) is a bot (LoopWorker), not a person"))
        #expect(check.detail.contains("\(id(5, "a")) is not a user in this workspace"))
        #expect(check.remedy?.hasSuffix("The workspace's people:\nAlice: \(alice)\nMallory: \(mallory)") == true)
    }

    @Test func B199_aMissingStatePropertyNamesWhatToAdd() async throws {
        let fake = FakeNotion()
        var schema = FakeNotion.schema()
        schema["LoopWorker"] = nil
        fake.addDatabase(properties: schema)
        let check = try await make(fake).diagnose()[2]
        #expect(check.level == .fail)
        #expect(check.detail.contains("has no property LoopWorker"))
        #expect(check.remedy == "add a select property named LoopWorker with the options next, working, ci, review, stuck")
    }

    @Test func B199_aMissingOptionAndAWrongPriorityTypeFail() async throws {
        let fake = FakeNotion()
        fake.addDatabase(properties: FakeNotion.schema(state: ["next", "working", "review"], extra: [
            "Priority": .object(["id": "pr", "name": "Priority", "type": "checkbox", "checkbox": .object([:])]),
        ]))
        let check = try await make(fake).diagnose()[2]
        #expect(check.level == .fail)
        #expect(check.detail.contains("LoopWorker lacks the options ci, stuck"))
        #expect(check.detail.contains("Priority is a checkbox property, not number, select or multi_select"))
        #expect(check.remedy?.contains("add the options ci, stuck to the select property LoopWorker") == true)
        #expect(check.remedy?.contains("make Priority a number, select or multi_select property") == true)
    }

    @Test func B199_anUnconnectedDatabaseSaysToConnectTheIntegration() async throws {
        let fake = FakeNotion()
        let check = try await make(fake).diagnose()[2]
        #expect(check.level == .fail)
        #expect(check.remedy?.contains("Connections") == true)
    }

    @Test("B212: doctor requires the merged option only for a project that finishes by merging")
    func mergedOptionOnlyForMergingProjects() async throws {
        let fake = FakeNotion()
        fake.addDatabase()
        let draft = try await make(fake).diagnose()[2]
        #expect(draft.level == .ok)
        #expect(draft.detail.hasSuffix("LoopWorker has the options next, working, ci, review, stuck"))

        let merging = try await make(fake, config: hostConfig(extraProjects: "finish = \"merge\"")).diagnose()[2]
        #expect(merging.level == .fail)
        #expect(merging.detail.contains("LoopWorker lacks the options merged"))
        #expect(merging.remedy == "add the options merged to the select property LoopWorker")

        fake.addDatabase(properties: FakeNotion.schema(state: ["next", "working", "ci", "review", "stuck", "merged"]))
        let ok = try await make(fake, config: hostConfig(extraProjects: "finish = \"ci_then_merge\"")).diagnose()[2]
        #expect(ok.level == .ok)
    }
}
