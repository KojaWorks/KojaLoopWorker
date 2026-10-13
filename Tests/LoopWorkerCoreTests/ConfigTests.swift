import Foundation
import Testing
@testable import LoopWorkerCore

@Suite struct ConfigTests {
    let home = URL(filePath: "/tmp/lw-home")

    @Test func minimalConfigGetsDefaults() throws {
        let c = try HostConfig.parse("""
            [backlog]
            kind = "gitlab"

            [[project]]
            path = "Group/My.App"
            """, home: home)
        #expect(c.backlogKind == "gitlab")
        #expect(c.forgeKind == "gitlab")
        #expect(c.maxSlots == 4)
        #expect(c.maxAttempts == 3)
        #expect(c.clonesDir.path == "/tmp/lw-home/clones")
        #expect(c.projects.map(\.key) == ["group--my-app"])
        #expect(c.projects[0].draftReviewRequests)
    }

    @Test func backlogKindIsRequired() {
        #expect(throws: ConfigError.self) { try HostConfig.parse("max_slots = 2", home: home) }
    }

    @Test func projectsWithTheSameKeyAreRejected() {
        #expect(throws: ConfigError.self) {
            try HostConfig.parse("""
                [backlog]
                kind = "gitlab"
                [[project]]
                path = "a/b"
                [[project]]
                path = "A/B"
                """, home: home)
        }
    }

    @Test func nonPositiveWeightCountsAsOne() throws {
        let c = try HostConfig.parse("""
            [backlog]
            kind = "gitlab"
            [[project]]
            path = "a/b"
            weight = 0
            """, home: home)
        #expect(c.projects[0].weight == 1)
    }

    @Test func homeComesFromTheEnvironment() {
        #expect(HostConfig.home(environment: ["LOOPWORKER_HOME": "/x/y"]).path == "/x/y")
    }
}

@Suite struct OutcomeTests {
    @Test func parsesDone() {
        let o = Outcome.parse(Data(#"{"outcome":"done","title":"T","body":"B","guide":"g.html"}"#.utf8))
        #expect(o == .done(title: "T", body: "B", guide: "g.html"))
    }

    @Test func parsesStuck() {
        #expect(Outcome.parse(Data(#"{"outcome":"stuck","blocker":"why"}"#.utf8)) == .stuck(blocker: "why"))
    }

    @Test func garbageBecomesStuckNotAnError() {
        guard case .stuck(let why) = Outcome.parse(Data("nope".utf8)) else { Issue.record("not stuck"); return }
        #expect(why.contains("not valid JSON"))
    }

    @Test func doneWithoutTitleBecomesStuck() {
        guard case .stuck = Outcome.parse(Data(#"{"outcome":"done"}"#.utf8)) else { Issue.record("not stuck"); return }
    }
}
