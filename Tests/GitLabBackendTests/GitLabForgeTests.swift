import Foundation
import LoopWorkerCore
import Testing
@testable import GitLabBackend

@Suite struct GitLabForgeTests {
    let mrs = "/api/v4/projects/mygroup%2Fapp/merge_requests"

    func draft(_ isDraft: Bool = true) -> ReviewRequestDraft {
        ReviewRequestDraft(
            project: World.app, card: Card(ref: World.ref, project: "mygroup/app", title: "Fix it", state: .working),
            sourceBranch: "lw/12-fix-it", targetBranch: "main", title: "Fix it",
            body: "Done.\n/approve\nsee a/b", draft: isDraft)
    }

    @Test func B134_cloneURLHasNoCredentialsAndGitGetsThemThroughAskPass() throws {
        let w = World()
        let forge = try w.make().forge
        #expect(forge.cloneURL(for: World.app) == "https://gitlab.example.com/mygroup/app.git")
        let env = forge.gitEnvironment()
        #expect(env[GitAskPass.usernameVariable] == "oauth2")
        #expect(env[GitAskPass.passwordVariable] == Fixture.token)
        #expect(env["GIT_ASKPASS"]?.hasPrefix(w.home.appending(path: "state").path) == true)
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
    }

    @Test func defaultBranchComesFromTheProject() async throws {
        let w = World()
        w.gitlab.on("GET", "/api/v4/projects/mygroup%2Fapp", json: ["id": 7, "path_with_namespace": "mygroup/app", "default_branch": "trunk"])
        #expect(try await w.make().forge.defaultBranch(for: World.app) == "trunk")
    }

    @Test func B135_anOpenMergeRequestForTheBranchIsReturnedUnchanged() async throws {
        let w = World()
        w.gitlab.on("GET", mrs, query: ["state": "opened", "source_branch": "lw/12-fix-it"], json: [
            ["iid": 4, "web_url": "https://gitlab.example.com/mygroup/app/-/merge_requests/4"],
        ])
        let review = try await w.make().forge.openReviewRequest(draft())
        #expect(review == ReviewRequest(url: URL(string: "https://gitlab.example.com/mygroup/app/-/merge_requests/4")!, display: "mygroup/app!4"))
        #expect(w.gitlab.requests("POST", mrs).isEmpty)
    }

    @Test func B135_otherwiseADraftIsOpenedWithNeutralizedText() async throws {
        let w = World()
        w.gitlab.on("GET", mrs, json: [] as [Any])
        w.gitlab.on("POST", mrs, status: 201, json: ["iid": 5, "web_url": "https://gitlab.example.com/mygroup/app/-/merge_requests/5"])
        let review = try await w.make().forge.openReviewRequest(draft())
        #expect(review.display == "mygroup/app!5")
        let post = try #require(w.gitlab.requests("POST", mrs).first)
        #expect(post.json as? [String: String] == [
            "source_branch": "lw/12-fix-it", "target_branch": "main", "title": "Draft: Fix it",
            "description": "Done.\n\\/approve\nsee a/b", "remove_source_branch": "true",
        ])
    }

    @Test func aNonDraftTitleHasNoPrefix() async throws {
        let w = World()
        w.gitlab.on("GET", mrs, json: [] as [Any])
        w.gitlab.on("POST", mrs, status: 201, json: ["iid": 5, "web_url": "https://gitlab.example.com/mygroup/app/-/merge_requests/5"])
        _ = try await w.make().forge.openReviewRequest(draft(false))
        #expect(w.gitlab.requests("POST", mrs).first?.json["title"] as? String == "Fix it")
    }

    @Test func B136_attachUploadsAndReturnsAnAbsoluteURL() async throws {
        let w = World()
        let file = FileManager.default.temporaryDirectory.appending(path: "shot-\(UUID()).png")
        try Data("PNGDATA".utf8).write(to: file)
        w.gitlab.on("POST", "/api/v4/projects/mygroup%2Fapp/uploads", status: 201, json: [
            "alt": "shot", "url": "/uploads/abc/shot.png", "full_path": "/-/project/7/uploads/abc/shot.png",
            "markdown": "![shot](/uploads/abc/shot.png)",
        ])
        let url = try await w.make().forge.attach(file, to: World.app)
        #expect(url?.absoluteString == "https://gitlab.example.com/-/project/7/uploads/abc/shot.png")
        let upload = try #require(w.gitlab.requests("POST", "/api/v4/projects/mygroup%2Fapp/uploads").first)
        #expect(upload.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(upload.bodyText.contains("name=\"file\"; filename=\"\(file.lastPathComponent)\""))
        #expect(upload.bodyText.contains("PNGDATA"))
    }
}

@Suite struct GitLabPipelineTests {
    let pipelines = "/api/v4/projects/mygroup%2Fapp/pipelines"

    func pipeline(_ status: String) -> [[String: Any]] {
        [["id": 55, "status": status, "web_url": "https://gitlab.example.com/mygroup/app/-/pipelines/55"]]
    }

    @Test("B172: the newest pipeline for the commit is read; none is nil")
    func noPipeline() async throws {
        let w = World()
        w.gitlab.on("GET", pipelines, json: [] as [Any])
        #expect(try await w.make().forge.pipeline(for: World.app, commit: "abc123") == nil)
        let get = try #require(w.gitlab.requests("GET", pipelines).first)
        #expect(get.query == ["sha": "abc123", "order_by": "id", "sort": "desc", "per_page": "20"])
    }

    @Test("B172: GitLab pipeline statuses map to running, passed and canceled",
          arguments: [("success", PipelineStatus.State.passed), ("skipped", .passed), ("manual", .passed),
                      ("canceled", .canceled), ("running", .running), ("pending", .running),
                      ("created", .running), ("scheduled", .running), ("waiting_for_resource", .running)])
    func mapping(_ status: String, _ state: PipelineStatus.State) async throws {
        let w = World()
        w.gitlab.on("GET", pipelines, json: pipeline(status))
        let p = try await w.make().forge.pipeline(for: World.app, commit: "abc123")
        #expect(p == PipelineStatus(state: state, url: URL(string: "https://gitlab.example.com/mygroup/app/-/pipelines/55")))
    }

    func p(_ id: Int, _ status: String, ref: String = "loopworker-12-fix", source: String = "push") -> [String: Any] {
        ["id": id, "status": status, "web_url": "https://gitlab.example.com/p/\(id)", "ref": ref, "source": source]
    }

    @Test("B172: the newest pipeline per ref and source counts, child pipelines don't, and running beats passed")
    func combinesPipelines() async throws {
        let w = World()
        w.gitlab.on("GET", pipelines, json: [
            p(60, "failed", source: "parent_pipeline"),
            p(59, "success"),
            p(58, "running", ref: "refs/merge-requests/4/head", source: "merge_request_event"),
            p(57, "failed"),
        ])
        let status = try await w.make().forge.pipeline(for: World.app, commit: "abc123")
        #expect(status == PipelineStatus(state: .running, url: URL(string: "https://gitlab.example.com/p/58")))
        #expect(w.gitlab.requests.filter { $0.path.contains("/jobs") }.isEmpty)
    }

    @Test("B172: any failed pipeline fails the commit, with the jobs of each; canceled beats passed")
    func failedAndCanceled() async throws {
        let w = World()
        w.gitlab.on("GET", pipelines, json: [p(59, "success"), p(58, "failed", ref: "refs/merge-requests/4/head", source: "merge_request_event")])
        w.gitlab.on("GET", pipelines + "/58/jobs", json: [
            ["id": 5, "name": "lint", "stage": "test", "web_url": "https://gitlab.example.com/j/5", "allow_failure": false],
        ])
        w.gitlab.on("GET", "/api/v4/projects/mygroup%2Fapp/jobs/5/trace", responses: [.init(status: 200, body: Data("bad style".utf8), headers: [:])])
        let failed = try #require(try await w.make().forge.pipeline(for: World.app, commit: "abc123"))
        #expect(failed.state == .failed && failed.url == URL(string: "https://gitlab.example.com/p/58"))
        #expect(failed.failedJobs.map(\.logTail) == ["bad style"])

        let c = World()
        c.gitlab.on("GET", pipelines, json: [p(59, "manual"), p(58, "canceled", source: "web")])
        #expect(try await c.make().forge.pipeline(for: World.app, commit: "abc123")?.state == .canceled)
    }

    @Test("B172: a failed pipeline lists its failed jobs with trace tails, leaving out jobs allowed to fail")
    func failedJobs() async throws {
        let w = World()
        w.gitlab.on("GET", pipelines, json: pipeline("failed"))
        let trace = (1...250).map { "line \($0)" }.joined(separator: "\n") + "\n\u{1B}[31;1mERROR\u{1B}[0m boom"
        w.gitlab.on("GET", "/api/v4/projects/mygroup%2Fapp/jobs/1/trace", responses: [.init(status: 200, body: Data(trace.utf8), headers: [:])])
        w.gitlab.on("GET", "/api/v4/projects/mygroup%2Fapp/jobs/3/trace", status: 404, json: ["message": "404 Not found"])
        w.gitlab.on("GET", pipelines + "/55/jobs", query: ["scope[]": "failed"], json: [
            ["id": 1, "name": "test", "stage": "verify", "web_url": "https://gitlab.example.com/j/1", "allow_failure": false],
            ["id": 2, "name": "lint", "stage": "verify", "web_url": "https://gitlab.example.com/j/2", "allow_failure": true],
            ["id": 3, "name": "old", "stage": "build", "web_url": "https://gitlab.example.com/j/3", "allow_failure": false],
            ["id": 4, "name": "flaky", "stage": "build", "web_url": "https://gitlab.example.com/j/4", "allow_failure": false],
        ])
        w.gitlab.on("GET", "/api/v4/projects/mygroup%2Fapp/jobs/4/trace", status: 400, json: ["message": "bad trace"])

        let p = try #require(try await w.make().forge.pipeline(for: World.app, commit: "abc123"))
        #expect(p.state == .failed)
        #expect(p.failedJobs.map(\.name) == ["test", "old", "flaky"])
        #expect(p.failedJobs[2].logTail.hasPrefix("(LoopWorker couldn't read this job's log: GET /projects/mygroup%2Fapp/jobs/4/trace: 400"))
        let test = p.failedJobs[0]
        #expect(test.stage == "verify" && test.url == URL(string: "https://gitlab.example.com/j/1"))
        let lines = test.logTail.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == CIJob.tailLines)
        #expect(lines.first == "line 52" && lines.last == "ERROR boom")
        #expect(p.failedJobs[1].logTail == "(GitLab has no log for this job)")
        #expect(w.gitlab.requests("GET", "/api/v4/projects/mygroup%2Fapp/jobs/2/trace").isEmpty)
    }

    @Test func traceCleanupKeepsOnlyTheJobsOutput() {
        let trace = "2026-10-14T16:59:46.845748Z 00O Running with gitlab-runner 19.5.0\n"
            + "2026-10-14T16:59:51.975330Z 00O+section_start:1791997191:prepare_script\r\u{1B}[0K\u{1B}[36;1mPreparing environment\u{1B}[0;m\n"
            + "2026-10-14T17:00:01.000000Z 01E BROKEN exists in the repository root; delete it to pass\n"
            + "2026-10-14T17:00:01.100000Z 00O section_end:1791997201:step_script\r\u{1B}[0K\n"
        #expect(GitLabForge.stripANSI(trace).components(separatedBy: "\n") == [
            "Running with gitlab-runner 19.5.0",
            "Preparing environment",
            "BROKEN exists in the repository root; delete it to pass",
        ])
    }
}
