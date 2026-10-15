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
        #expect(c.projects[0].finish == .draft)
    }

    @Test("B213: finish decodes, draft is its deprecated alias, and conflicts or unknown modes fail")
    func finishModes() throws {
        func parse(_ keys: String) throws -> HostConfig {
            try HostConfig.parse("[backlog]\nkind = \"gitlab\"\n[[project]]\npath = \"a/b\"\n\(keys)\n", home: home)
        }
        #expect(try parse("finish = \"ci_then_merge\"").projects[0].finish == .ciThenMerge)
        #expect(try parse("finish = \"merge\"").warnings.isEmpty)
        let ready = try parse("draft = false")
        #expect(ready.projects[0].finish == .ready)
        #expect(ready.warnings == [#"config.toml: a/b: draft is deprecated; replace it with finish = "ready""#])
        #expect(try parse("draft = true").projects[0].finish == .draft)
        let unknown = try #require(throws: ConfigError.self) { try parse("finish = \"auto\"") }
        #expect("\(unknown)".contains(#"finish must be one of "draft", "ready", "merge", "ci_then_merge", got "auto""#))
        let both = try #require(throws: ConfigError.self) { try parse("finish = \"ready\"\ndraft = false") }
        #expect("\(both)".contains("set finish only"))
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
        let replies = Outcome.parse(Data(#"{"outcome":"done","title":"T","body":"B","replies":{"d1":"Renamed."}}"#.utf8))
        #expect(replies == .done(title: "T", body: "B", guide: nil, replies: ["d1": "Renamed."]))  // B207
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

@Suite struct ConfigValidationTests {
    let home = URL(filePath: "/tmp/lw-home")
    let base = "[backlog]\nkind = \"gitlab\"\n"

    @Test func rejectsRelativeClonesDirAndHome() {
        #expect(throws: ConfigError.self) { try HostConfig.parse("clones_dir = \"rel\"\n" + base, home: home) }
        #expect(throws: ConfigError.self) { try HostConfig.parse(base, home: URL(filePath: "rel")) }
    }

    @Test func rejectsZeroConcurrency() {
        #expect(throws: ConfigError.self) { try HostConfig.parse("max_concurrent_workers = 0\n" + base, home: home) }
    }

    @Test func tildeNeedsASlash() {
        #expect(expandTilde("~foo") == "~foo")
        #expect(expandTilde("~/x").hasSuffix("/x"))
    }

    @Test func workerEnvComesFromHostConfig() throws {
        let c = try HostConfig.parse(base + "[[project]]\npath = \"a/b\"\nworker_env = [\"FOO\"]\n", home: home)
        #expect(c.projects[0].workerEnv == ["FOO"])
    }

    @Test func branchTemplateNeedsNumber() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "contract-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "[worker]\nbranch = \"lw-{slug}\"\n".write(to: dir.appending(path: "manifest.toml"), atomically: true, encoding: .utf8)
        #expect(throws: ConfigError.self) { try ProjectContract.load(from: dir) }
    }

    @Test("B161: [lfs] keys decode with defaults and are validated")
    func lfsTable() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "contract-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func load(_ toml: String) throws -> ProjectContract {
            try toml.write(to: dir.appending(path: "manifest.toml"), atomically: true, encoding: .utf8)
            return try ProjectContract.load(from: dir)
        }
        #expect(try load("").lfs == ProjectContract.LFS())
        #expect(ProjectContract.LFS().pull && ProjectContract.LFS().pullTimeout == .seconds(3600))

        let lfs = try load("[lfs]\npull = false\ninclude = [\"assets/**\"]\nexclude = [\"*.mov\", \"raw/\"]\npull_timeout_minutes = 5\n").lfs
        #expect(!lfs.pull)
        #expect(lfs.include == ["assets/**"] && lfs.exclude == ["*.mov", "raw/"])
        #expect(lfs.pullTimeout == .seconds(300))

        let zero = try #require(throws: ConfigError.self) { try load("[lfs]\npull_timeout_minutes = 0\n") }
        #expect("\(zero)".contains("pull_timeout_minutes must be > 0"))
        let comma = try #require(throws: ConfigError.self) { try load("[lfs]\ninclude = [\"a,b\"]\n") }
        #expect("\(comma)".contains("\"a,b\" contains a comma"))
    }

    @Test("B163: [review] CI keys decode with defaults and are validated")
    func reviewCIKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "contract-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func load(_ toml: String) throws -> ProjectContract {
            try toml.write(to: dir.appending(path: "manifest.toml"), atomically: true, encoding: .utf8)
            return try ProjectContract.load(from: dir)
        }
        let defaults = try load("[review]\nguide = true\n").ci
        #expect(!defaults.waitForCI && defaults.timeoutMinutes == 120 && defaults.fixAttempts == 2)

        let ci = try load("[review]\nwait_for_ci = true\nci_timeout_minutes = 30\nci_fix_attempts = 0\n").ci
        #expect(ci.waitForCI && ci.timeoutMinutes == 30 && ci.fixAttempts == 0)

        let timeout = try #require(throws: ConfigError.self) { try load("[review]\nci_timeout_minutes = 0\n") }
        #expect("\(timeout)".contains("[review] ci_timeout_minutes must be > 0"))
        let attempts = try #require(throws: ConfigError.self) { try load("[review]\nci_fix_attempts = -1\n") }
        #expect("\(attempts)".contains("[review] ci_fix_attempts must be >= 0"))
    }

    @Test func outcomeTitleIsOneBoundedLine() {
        let long = String(repeating: "x", count: 500)
        guard case .done(let title, _, _, _) = Outcome.parse(Data(#"{"outcome":"done","title":"\#(long)\nsecond"}"#.utf8)) else {
            Issue.record("not done"); return
        }
        #expect(title.count == Outcome.maxTitleLength)
    }
}
