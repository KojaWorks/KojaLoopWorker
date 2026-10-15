import Foundation
import LoopWorkerCore
import Testing
@testable import GitLabBackend

@Suite struct GitLabForgeTests {
    let mrs = "/api/v4/projects/mygroup%2Fapp/merge_requests"

    func draft(_ isDraft: Bool = true, assign: Bool = false) -> ReviewRequestDraft {
        ReviewRequestDraft(
            project: World.app, card: Card(ref: World.ref, project: "mygroup/app", title: "Fix it", state: .working),
            sourceBranch: "lw/12-fix-it", targetBranch: "main", title: "Fix it",
            body: "Done.\n/approve\nsee a/b", draft: isDraft, assignToOwner: assign)
    }

    @Test("B186: a new merge request is assigned to the token's user")
    func aNewMergeRequestIsAssigned() async throws {
        let w = World()
        w.gitlab.on("GET", mrs, json: [] as [Any])
        w.gitlab.on("POST", mrs, status: 201, json: ["iid": 5, "web_url": "https://gitlab.example.com/mygroup/app/-/merge_requests/5"])
        _ = try await w.make().forge.openReviewRequest(draft(assign: true))
        #expect(w.gitlab.requests("POST", mrs).first?.json["assignee_id"] as? String == "1")

        var withCommit = draft()
        withCommit.marker = ReviewMarker.round("r1", commit: "c1", read: nil)
        _ = try await w.make().forge.openReviewRequest(withCommit)
        #expect((w.gitlab.requests("POST", mrs).last?.json["description"] as? String)?.hasSuffix("see a/b\n\n<!-- loopworker:round=r1 commit=c1 -->") == true)  // B208
    }

    @Test("B186: an open merge request gets the assignee only when it has none")
    func anOpenMergeRequestWithoutAssigneeIsAssigned() async throws {
        let w = World()
        w.gitlab.on("GET", mrs, json: [["iid": 4, "web_url": "https://gitlab.example.com/mygroup/app/-/merge_requests/4", "assignees": [] as [Any]]])
        w.gitlab.on("PUT", mrs + "/4", json: ["iid": 4, "web_url": "https://gitlab.example.com/mygroup/app/-/merge_requests/4"])
        _ = try await w.make().forge.openReviewRequest(draft(assign: true))
        #expect(w.gitlab.requests("PUT", mrs + "/4").map { $0.json as? [String: String] } == [["assignee_id": "1"]])
        #expect(w.gitlab.requests("POST", mrs).isEmpty)

        let assigned = World()
        assigned.gitlab.on("GET", mrs, json: [["iid": 4, "web_url": "https://gitlab.example.com/mygroup/app/-/merge_requests/4", "assignees": [Fixture.me]]])
        _ = try await assigned.make().forge.openReviewRequest(draft(assign: true))
        #expect(assigned.gitlab.requests("PUT", mrs + "/4").isEmpty)
    }

    @Test("B186: a failed assignment is logged and the merge request is still returned")
    func aFailedAssignmentIsBestEffort() async throws {
        let w = World()
        w.gitlab.on("GET", mrs, json: [["iid": 4, "web_url": "https://gitlab.example.com/mygroup/app/-/merge_requests/4", "assignees": [] as [Any]]])
        w.gitlab.on("PUT", mrs + "/4", status: 403, json: ["message": "403 Forbidden"])
        let review = try await w.make().forge.openReviewRequest(draft(assign: true))
        #expect(review.url.absoluteString == "https://gitlab.example.com/mygroup/app/-/merge_requests/4")
        #expect(w.log.lines.contains { $0.contains("can't assign mygroup/app!4 (https://gitlab.example.com/mygroup/app/-/merge_requests/4) to the token's user") && $0.contains("403") })

        let anonymous = World()
        anonymous.gitlab.on("GET", "/api/v4/user", status: 403, json: ["message": "403 Forbidden"])
        anonymous.gitlab.on("GET", mrs, json: [] as [Any])
        anonymous.gitlab.on("POST", mrs, status: 201, json: ["iid": 5, "web_url": "https://gitlab.example.com/mygroup/app/-/merge_requests/5"])
        _ = try await anonymous.make().forge.openReviewRequest(draft(assign: true))
        #expect(anonymous.gitlab.requests("POST", mrs).first?.json["assignee_id"] == nil)
        #expect(anonymous.log.lines.contains { $0.contains("can't read the token's user to assign the merge request for mygroup/app lw/12-fix-it") })
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

    @Test("B180: a baseline is the latest attempt of each named job in the newest finished, non-child pipeline on the branch")
    func baseline() async throws {
        let w = World()
        w.gitlab.on("GET", pipelines, json: [
            p(70, "running", ref: "main"), p(69, "failed", ref: "main", source: "parent_pipeline"),
            p(68, "canceled", ref: "main"), p(67, "failed", ref: "main"), p(66, "success", ref: "main"),
        ])
        func job(_ id: Int, _ name: String, _ status: String) -> [String: Any] {
            ["id": id, "name": name, "stage": "test", "web_url": "https://gitlab.example.com/j/\(id)", "allow_failure": false, "status": status]
        }
        w.gitlab.on("GET", pipelines + "/67/jobs", json: [
            job(3, "test", "success"), job(1, "test", "failed"), job(2, "lint", "failed"), job(4, "e2e", "skipped"), job(5, "other", "failed"),
        ])
        let b = try await w.make().forge.baselineJobs(for: World.app, ref: "main", names: ["test", "lint", "e2e", "new"])
        #expect(b == [
            "test": .passed(URL(string: "https://gitlab.example.com/j/3")), "lint": .failed(URL(string: "https://gitlab.example.com/j/2")),
            "e2e": .unknown, "new": .unknown,
        ])
        let get = try #require(w.gitlab.requests("GET", pipelines).first)
        #expect(get.query == ["ref": "main", "order_by": "id", "sort": "desc", "per_page": "20"])
    }

    @Test("B180: no finished pipeline on the branch leaves every job unknown")
    func noBaseline() async throws {
        let w = World()
        w.gitlab.on("GET", pipelines, json: [p(70, "running", ref: "main")])
        let b = try await w.make().forge.baselineJobs(for: World.app, ref: "main", names: ["test"])
        #expect(b == ["test": .unknown])
        #expect(w.gitlab.requests.filter { $0.path.contains("/jobs") }.isEmpty)
    }

    @Test("B180: failed jobs carry their id, and a retry POSTs each job's retry")
    func retry() async throws {
        let w = World()
        w.gitlab.on("GET", pipelines, json: pipeline("failed"))
        w.gitlab.on("GET", pipelines + "/55/jobs", json: [
            ["id": 7, "name": "test", "stage": "verify", "web_url": "https://gitlab.example.com/j/7", "allow_failure": false],
        ])
        w.gitlab.on("GET", "/api/v4/projects/mygroup%2Fapp/jobs/7/trace", responses: [.init(status: 200, body: Data("x".utf8), headers: [:])])
        w.gitlab.on("POST", "/api/v4/projects/mygroup%2Fapp/jobs/7/retry", status: 201, json: ["id": 8])
        let forge = try w.make().forge
        let jobs = try #require(try await forge.pipeline(for: World.app, commit: "abc123")).failedJobs
        #expect(jobs.map(\.id) == ["7"])
        #expect(try await forge.retryJobs(project: World.app, jobs: jobs))
        #expect(w.gitlab.requests("POST", "/api/v4/projects/mygroup%2Fapp/jobs/7/retry").count == 1)
        #expect(try await !forge.retryJobs(project: World.app, jobs: [CIJob(name: "x", stage: "", url: nil, logTail: "")]))
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

@Suite struct GitLabMergeTests {
    let mr = "/api/v4/projects/mygroup%2Fapp/merge_requests/34"
    let review = ReviewRequest(url: URL(string: "https://gitlab.example.com/mygroup/app/-/merge_requests/34")!, display: "mygroup/app!34")
    let head = "0123456789abcdef0123456789abcdef01234567"

    func state(_ state: String, _ status: String = "mergeable", commit: String? = nil) -> [String: Any] {
        ["iid": 34, "web_url": review.url.absoluteString, "state": state, "detailed_merge_status": status,
         "merge_commit_sha": Fixture.orNull(commit)]
    }

    func merge(_ w: World) async throws -> MergeResult {
        try await w.make().forge.merge(review, project: World.app, head: head)
    }

    @Test("B225: a merge sends only sha and returns the merge commit")
    func mergesWithTheMergeCommit() async throws {
        let w = World()
        w.gitlab.on("PUT", mr + "/merge", json: state("merged", commit: "feed"))
        #expect(try await merge(w) == .merged(commit: "feed"))
        #expect(w.gitlab.requests("PUT", mr + "/merge").map { $0.json as? [String: String] } == [["sha": head]])
        #expect(w.gitlab.requests("GET", mr).isEmpty)
    }

    @Test("B225: a refused merge of an already merged merge request is merged")
    func alreadyMerged() async throws {
        let w = World()
        w.gitlab.on("PUT", mr + "/merge", status: 405, json: ["message": "405 Method Not Allowed"])
        w.gitlab.on("GET", mr, json: state("merged", "not_open", commit: "feed"))
        #expect(try await merge(w) == .merged(commit: "feed"))
    }

    @Test("B225: an unmerged 2xx re-reads the merge request")
    func unmergedSuccessRereads() async throws {
        let w = World()
        w.gitlab.on("PUT", mr + "/merge", json: state("opened"))
        w.gitlab.on("GET", mr, json: state("opened", "checking"))
        #expect(try await merge(w) == .pending("GitLab: checking (GitLab is checking whether it can merge)"))
    }

    @Test("B225: detailed_merge_status decides pending, outdated or blocked, naming the value", arguments: [
        ("checking", "pending"), ("unchecked", "pending"), ("preparing", "pending"), ("ci_still_running", "pending"),
        ("approvals_syncing", "pending"), ("mergeable", "pending"), ("conflict", "outdated"), ("need_rebase", "outdated"),
        ("not_approved", "blocked"), ("blocked_status", "blocked"), ("draft_status", "blocked"),
        ("discussions_not_resolved", "blocked"), ("requested_changes", "blocked"), ("not_open", "blocked"),
        ("some_future_rule", "blocked"),
    ])
    func refusalClasses(_ status: String, _ kind: String) async throws {
        let w = World()
        w.gitlab.on("PUT", mr + "/merge", status: 422, json: ["message": "Branch cannot be merged"])
        w.gitlab.on("GET", mr, json: state("opened", status))
        let reason: String
        switch try await merge(w) {
        case .pending(let r) where kind == "pending": reason = r
        case .outdated(let r) where kind == "outdated": reason = r
        case .blocked(let r) where kind == "blocked": reason = r
        case let other: Issue.record("\(status): \(other), expected \(kind)"); return
        }
        #expect(reason.hasPrefix("GitLab: \(status)"))
    }

    @Test("B225: ci_must_pass is pending while the head's pipeline is missing or running, blocked once it ended")
    func ciMustPass() async throws {
        let w = World()
        let pipelines = "/api/v4/projects/mygroup%2Fapp/pipelines"
        w.gitlab.on("PUT", mr + "/merge", status: 405, json: ["message": "405 Method Not Allowed"])
        w.gitlab.on("GET", mr, json: state("opened", "ci_must_pass"))
        w.gitlab.on("GET", pipelines, json: [Any]())
        #expect(try await merge(w) == .pending("GitLab: ci_must_pass (a pipeline must pass first)"))
        w.gitlab.on("GET", pipelines, json: [["id": 7, "status": "running", "web_url": "https://gitlab.example.com/p/7", "source": "push"]])
        #expect(try await merge(w) == .pending("GitLab: ci_must_pass (a pipeline must pass first)"))
        w.gitlab.on("GET", pipelines, json: [["id": 7, "status": "canceled", "web_url": "https://gitlab.example.com/p/7", "source": "push"]])
        #expect(try await merge(w) == .blocked("GitLab: ci_must_pass (a pipeline must pass first)"))
    }

    @Test("B225: a merge request that hasn't caught up with the push is pending; one whose branch moved on is blocked")
    func lagsThePush() async throws {
        let w = World()
        var lagging = state("opened", "need_rebase")
        lagging["sha"] = "0ld"
        lagging["source_branch"] = "loopworker-12"
        w.gitlab.on("PUT", mr + "/merge", status: 409, json: ["message": "SHA does not match HEAD of source branch"])
        w.gitlab.on("GET", mr, json: lagging)
        let branch = "/api/v4/projects/mygroup%2Fapp/repository/branches/loopworker-12"
        w.gitlab.on("GET", branch, json: ["commit": ["id": head]])
        #expect(try await merge(w) == .pending("GitLab: the merge request doesn't show the push of 0123456789ab yet"))
        w.gitlab.on("GET", branch, json: ["commit": ["id": "n3w"]])
        #expect(try await merge(w) == .blocked("GitLab: the source branch's head moved past 0123456789ab"))
    }

    @Test("B225: reasons gloss known values and pass unknown ones through raw")
    func reasons() async throws {
        let w = World()
        w.gitlab.on("PUT", mr + "/merge", status: 405, json: ["message": "405 Method Not Allowed"])
        w.gitlab.on("GET", mr, json: state("opened", "not_approved"))
        #expect(try await merge(w) == .blocked("GitLab: not_approved (the merge request needs approvals)"))
        w.gitlab.on("GET", mr, json: state("opened", "some_future_rule"))
        #expect(try await merge(w) == .blocked("GitLab: some_future_rule"))
        w.gitlab.on("GET", mr, json: state("opened", "mergeable"))
        #expect(try await merge(w) == .pending(
            #"GitLab: mergeable (it can merge), but the merge answered 405 {"message":"405 Method Not Allowed"}"#))
    }

    @Test("B225: a 409 is a moved head, a closed merge request is blocked, a locked one is merging")
    func headMovedClosedAndLocked() async throws {
        let w = World()
        w.gitlab.on("PUT", mr + "/merge", status: 409, json: ["message": "SHA does not match HEAD of source branch"])
        w.gitlab.on("GET", mr, json: state("opened"))
        #expect(try await merge(w) == .blocked("GitLab: the source branch's head moved past 0123456789ab"))
        w.gitlab.on("GET", mr, json: state("closed", "not_open"))
        #expect(try await merge(w) == .blocked("GitLab: closed (the merge request isn't open)"))
        w.gitlab.on("GET", mr, json: state("locked", "mergeable"))
        #expect(try await merge(w) == .pending("GitLab: locked (the merge is in progress)"))
    }

    @Test("B227: a 401 with a working token is blocked, naming who may merge when the rule is readable")
    func mergePermissionMissing() async throws {
        let w = World()
        w.gitlab.on("PUT", mr + "/merge", status: 401, json: ["message": "401 Unauthorized"])
        w.gitlab.on("GET", mr, json: state("opened").merging(["target_branch": "release/1"]) { _, b in b })
        let rule = "/api/v4/projects/mygroup%2Fapp/protected_branches/release%2F1"
        w.gitlab.on("GET", rule, json: ["name": "release/1", "merge_access_levels": [["access_level": 40, "access_level_description": "Maintainers"]]])
        #expect(try await merge(w) == .blocked(
            #"GitLab: @me may not merge into release/1; its protected branch rule allows Maintainers (the merge answered 401 {"message":"401 Unauthorized"})"#))
        w.gitlab.on("GET", rule, status: 403, json: ["message": "403 Forbidden"])
        #expect(try await merge(w) == .blocked(
            #"GitLab: @me may not merge into release/1; its protected branch rule or @me's role in mygroup/app decides who may (the merge answered 401 {"message":"401 Unauthorized"})"#))
        #expect(w.log.lines.isEmpty)
    }

    @Test("B227: a 401 or an insufficient_scope 403 with a rejected token throws the token error")
    func mergeWithBadToken() async throws {
        let w = World()
        w.gitlab.on("PUT", mr + "/merge", status: 401, json: ["message": "401 Unauthorized"])
        w.gitlab.on("GET", "/api/v4/user", status: 401, json: ["message": "401 Unauthorized"])
        let error = await #expect(throws: GitLabError.self) { try await merge(w) }
        #expect(error?.description == #"PUT /projects/mygroup%2Fapp/merge_requests/34/merge: 401 {"message":"401 Unauthorized"}. The token in LOOPWORKER_GITLAB_TOKEN is invalid, expired or lacks the api scope."#)

        let scoped = World()
        scoped.gitlab.on("PUT", mr + "/merge", status: 403, json: ["error": "insufficient_scope"])
        let scopeError = await #expect(throws: GitLabError.self) { try await merge(scoped) }
        #expect(scopeError?.description.contains("lacks the api scope") == true)
        #expect(scoped.gitlab.requests("GET", "/api/v4/user").isEmpty)
        #expect(w.gitlab.requests("GET", mr).isEmpty && scoped.gitlab.requests("GET", mr).isEmpty)
    }

    @Test("B225: a 5xx throws after the retries instead of returning a value")
    func serverErrorThrows() async throws {
        let w = World()
        w.gitlab.on("PUT", mr + "/merge", status: 502, json: ["message": "Bad Gateway"])
        await #expect(throws: GitLabError.self) { try await merge(w) }
        #expect(w.gitlab.requests("GET", mr).isEmpty)
    }

    @Test("B225: a review URL without a number is a BackendRejection naming it")
    func urlWithoutNumber() async throws {
        let w = World()
        let bad = ReviewRequest(url: URL(string: "https://gitlab.example.com/mygroup/app/-/merge_requests")!, display: "mygroup/app!?")
        let error = await #expect(throws: BackendRejection.self) {
            try await w.make().forge.merge(bad, project: World.app, head: head)
        }
        #expect(error?.description.contains("https://gitlab.example.com/mygroup/app/-/merge_requests ") == true)
        #expect(w.gitlab.requests.isEmpty)
    }
}

@Suite struct GitLabReviewTests {
    let mrs = "/api/v4/projects/mygroup%2Fapp/merge_requests"
    static let review = ReviewRequest(url: URL(string: "https://gitlab.example.com/mygroup/app/-/merge_requests/4")!, display: "mygroup/app!4")

    func discussion(_ id: String, individual: Bool = true, _ notes: [[String: Any]]) -> [String: Any] {
        ["id": id, "individual_note": individual, "notes": notes]
    }

    func mrNote(_ id: Int, _ body: String, by author: [String: Any] = Fixture.mallory, at minutes: Int, system: Bool = false,
                resolved: Bool? = nil, position: [String: Any]? = nil) -> [String: Any] {
        var n = Fixture.note(id, body, by: author, at: minutes, system: system)
        if let resolved { n["resolvable"] = true; n["resolved"] = resolved } else { n["resolvable"] = false }
        if let position { n["position"] = position }
        return n
    }

    func editsPage(_ ids: [Int], edited: [Int: (user: [String: Any], at: Int)] = [:], next: String? = nil) -> [String: Any] {
        ["data": ["project": ["mergeRequest": ["notes": [
            "pageInfo": ["hasNextPage": next != nil, "endCursor": Fixture.orNull(next)],
            "nodes": ids.map { id in
                ["id": "gid://gitlab/Note/\(id)", "lastEditedAt": Fixture.orNull(edited[id].map { Fixture.t($0.at) }),
                 "lastEditedBy": Fixture.orNull(edited[id].map { Fixture.gid($0.user) })] as [String: Any]
            },
        ]]]]]
    }

    @Test("B204: review feedback: unresolved threads and plain comments after LoopWorker's latest note, trust-checked with GraphQL edits")
    func reviewFeedback() async throws {
        let w = World()
        w.gitlab.on("GET", mrs + "/4", json: ["iid": 4, "web_url": Self.review.url.absoluteString, "created_at": Fixture.t(0)])
        let summary = ReviewMarker.note("LoopWorker pushed abc", markers: [ReviewMarker.round("r1", commit: "abc", read: Fixture.date(3))])
        w.gitlab.on("GET", mrs + "/4/discussions", json: [
            discussion("d1", individual: false, [
                mrNote(11, "Rename this.", at: 1, resolved: false,
                       position: ["head_sha": "abc", "new_path": "a.swift", "old_path": "a.swift", "new_line": 10, "old_line": NSNull()]),
                mrNote(12, "Agreed.", by: Fixture.me, at: 2, resolved: false),
            ]),
            discussion("d2", individual: false, [mrNote(21, "Fixed already.", at: 1, resolved: true)]),
            discussion("d3", [mrNote(31, "Old remark.", at: 1)]),
            discussion("d4", [mrNote(41, summary, by: Fixture.me, at: 3)]),
            discussion("d5", [mrNote(51, "/merge\nAlso the docs.", at: 4)]),
            discussion("d6", [mrNote(61, "added 1 commit", at: 4, system: true)]),
            discussion("d7", [mrNote(71, "Late remark.", at: 6)]),
        ])
        w.gitlab.on("POST", "/api/graphql", bodyContains: "mergeRequest(iid", json: editsPage([11, 12, 21], edited: [12: (Fixture.mallory, 7)], next: "c1"))
        w.gitlab.on("POST", "/api/graphql", bodyContains: "\"after\":\"c1\"", json: editsPage([31, 41, 51, 61, 71]))
        let feedback = try await w.make().forge.reviewFeedback(for: Self.review, project: World.app, vouchedAt: Fixture.date(5))
        #expect(feedback.threads.map(\.id) == ["d1", "d5"])
        #expect(feedback.threads[0].position == ReviewFeedback.Position(path: "a.swift", line: 10, side: .new, commit: "abc"))
        #expect(feedback.threads[0].notes.map(\.body) == ["Rename this."])
        #expect(feedback.threads[1].notes == [ReviewFeedback.Note(author: "mallory", createdAt: Fixture.date(4), body: "/merge\nAlso the docs.")])
        #expect(feedback.withheld.count == 2)
        #expect(feedback.withheld[0].hasPrefix("note 12 by @me in thread d1: edited by @mallory"))
        #expect(feedback.withheld[1].hasPrefix("note 71 by @mallory in thread d7: posted at"))
        #expect(w.gitlab.requests("POST", "/api/graphql").count == 2)
    }

    @Test("B208: a reply to a single comment is a new merge request note that links it, posted once")
    func singleCommentReply() async throws {
        let w = World()
        let marker = ReviewMarker.reply("r1", thread: "d5")
        w.gitlab.on("GET", mrs + "/4/discussions/d5", json: discussion("d5", [mrNote(51, "Also the docs.", at: 4)]))
        w.gitlab.on("GET", mrs + "/4/notes", json: [] as [Any])
        w.gitlab.on("POST", mrs + "/4/notes", status: 201, json: Fixture.note(52, "x", at: 5))
        let forge = try w.make().forge
        #expect(try await forge.replyToThread("d5", text: "/close\nAdded.", marker: marker, on: Self.review, project: World.app) == .posted)
        #expect(w.gitlab.requests("POST", mrs + "/4/notes").map { $0.json["body"] as? String } == [
            "<!-- loopworker -->\n\(marker)\n\nIn reply to [@mallory's comment](\(Self.review.url.absoluteString)#note_51):\n\n\\/close\nAdded.",
        ])
        #expect(w.gitlab.requests("POST", mrs + "/4/discussions/d5/notes").isEmpty)

        w.gitlab.on("GET", mrs + "/4/notes", json: [Fixture.note(52, "<!-- loopworker -->\n\(marker)\n\nIn reply", by: Fixture.me, at: 5)])
        #expect(try await forge.replyToThread("d5", text: "Added.", marker: marker, on: Self.review, project: World.app) == .alreadyPosted)
        #expect(w.gitlab.requests("POST", mrs + "/4/notes").count == 1)
    }

    @Test("B204: GraphQL's lastEditedAt without lastEditedBy (unedited, or a thread resolved later) is no edit; DiffNote ids match REST")
    func liveEditShapes() async throws {
        let w = World()
        w.gitlab.on("GET", mrs + "/4", json: ["iid": 4, "web_url": Self.review.url.absoluteString, "created_at": Fixture.t(0)])
        w.gitlab.on("GET", mrs + "/4/discussions", json: [
            discussion("d1", individual: false, [
                mrNote(11, "Rename this.", at: 1, resolved: false, position: ["head_sha": "abc", "new_path": "a.swift", "new_line": 3]),
                mrNote(12, "Also here.", at: 2, resolved: false),
                mrNote(13, "Changed my mind.", at: 3, resolved: false),
            ]),
        ])
        w.gitlab.on("POST", "/api/graphql", bodyContains: "mergeRequest(iid", json: ["data": ["project": ["mergeRequest": ["notes": [
            "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
            "nodes": [
                ["id": "gid://gitlab/DiffNote/11", "lastEditedAt": Fixture.t(1), "lastEditedBy": NSNull()],
                ["id": "gid://gitlab/Note/12", "lastEditedAt": Fixture.t(9), "lastEditedBy": NSNull()],
                ["id": "gid://gitlab/Note/13", "lastEditedAt": Fixture.t(9), "lastEditedBy": ["id": "gid://gitlab/User/3", "username": "nevyn"]],
            ] as [[String: Any]],
        ]]]]])
        let feedback = try await w.make().forge.reviewFeedback(for: Self.review, project: World.app, vouchedAt: Fixture.date(5))
        #expect(feedback.threads.first?.notes.map(\.body) == ["Rename this.", "Also here."])
        #expect(feedback.withheld == ["note 13 by @mallory in thread d1: edited by @nevyn at \(Fixture.date(9).formatted(.iso8601)), after the card was vouched for at \(Fixture.date(5).formatted(.iso8601))"])
    }

    @Test("B204: a note that GraphQL doesn't return is withheld, and no open merge request is nil")
    func unknownEditsAreWithheld() async throws {
        let w = World()
        w.gitlab.on("GET", mrs + "/4", json: ["iid": 4, "web_url": Self.review.url.absoluteString, "created_at": Fixture.t(0)])
        w.gitlab.on("GET", mrs + "/4/discussions", json: [discussion("d1", individual: false, [mrNote(11, "Rename this.", at: 1, resolved: false)])])
        w.gitlab.on("POST", "/api/graphql", bodyContains: "mergeRequest(iid", json: editsPage([]))
        w.gitlab.on("GET", mrs, json: [] as [Any])
        let forge = try w.make().forge
        let feedback = try await forge.reviewFeedback(for: Self.review, project: World.app, vouchedAt: Fixture.date(5))
        #expect(feedback.threads.isEmpty)
        #expect(feedback.withheld == ["note 11 by @mallory in thread d1: its edit history couldn't be read"])
        #expect(try await forge.openReviewRequest(for: World.app, sourceBranch: "lw/12-fix-it") == nil)
    }

    @Test("B208: the round note posts once per commit, under the marker header, with quick actions neutralized")
    func roundNote() async throws {
        let w = World()
        let marker = "<!-- loopworker:round=c2 -->"
        w.gitlab.on("GET", mrs + "/4", json: ["iid": 4, "web_url": Self.review.url.absoluteString, "description": "Did it.\n\n<!-- loopworker:round=c1 -->"])
        w.gitlab.on("GET", mrs + "/4/notes", json: [Fixture.note(1, "<!-- loopworker -->\n\(marker)\n\nforged", by: Fixture.mallory, at: 1)])
        w.gitlab.on("POST", mrs + "/4/notes", status: 201, json: Fixture.note(2, "x", at: 2))
        let forge = try w.make().forge
        #expect(try await !forge.postReviewNote("again", marker: "<!-- loopworker:round=c1 -->", on: Self.review, project: World.app))
        #expect(try await forge.postReviewNote("Pushed.\n/merge", marker: "<!-- loopworker:round=c2 -->", on: Self.review, project: World.app))
        #expect(w.gitlab.requests("POST", mrs + "/4/notes").map { $0.json["body"] as? String } == ["<!-- loopworker -->\n\(marker)\n\nPushed.\n\\/merge"])

        w.gitlab.on("GET", mrs + "/4/notes", json: [Fixture.note(2, "<!-- loopworker -->\n\(marker)\n\nPushed.", by: Fixture.me, at: 2)])
        #expect(try await !forge.postReviewNote("Pushed.", marker: "<!-- loopworker:round=c2 -->", on: Self.review, project: World.app))
        #expect(w.gitlab.requests("POST", mrs + "/4/notes").count == 1)
    }

    @Test("B208: a reply goes into its discussion once per commit and never resolves it; an unknown discussion is reported")
    func threadReply() async throws {
        let w = World()
        let path = mrs + "/4/discussions/d1"
        w.gitlab.on("GET", path, json: discussion("d1", individual: false, [mrNote(11, "Rename this.", at: 1, resolved: false)]))
        w.gitlab.on("POST", path + "/notes", status: 201, json: Fixture.note(12, "x", at: 2))
        w.gitlab.on("GET", mrs + "/4/discussions/nope", status: 404, json: ["message": "404 Not found"])
        let forge = try w.make().forge
        #expect(try await forge.replyToThread("d1", text: "/close\nRenamed.", marker: ReviewMarker.reply("c2", thread: "d1"), on: Self.review, project: World.app) == .posted)
        #expect(w.gitlab.requests("POST", path + "/notes").map { $0.json["body"] as? String }
                == ["<!-- loopworker -->\n<!-- loopworker:reply=c2 thread=d1 -->\n\n\\/close\nRenamed."])
        #expect(try await forge.replyToThread("nope", text: "x", marker: ReviewMarker.reply("c2", thread: "nope"), on: Self.review, project: World.app) == .noSuchThread)

        w.gitlab.on("GET", path, json: discussion("d1", individual: false, [
            mrNote(11, "Rename this.", at: 1, resolved: false),
            mrNote(12, "<!-- loopworker -->\n<!-- loopworker:reply=c2 thread=d1 -->\n\nRenamed.", by: Fixture.me, at: 2, resolved: false),
        ]))
        #expect(try await forge.replyToThread("d1", text: "Renamed.", marker: ReviewMarker.reply("c2", thread: "d1"), on: Self.review, project: World.app) == .alreadyPosted)
        #expect(w.gitlab.requests("POST", path + "/notes").count == 1)
        #expect(!w.gitlab.requests.contains { $0.method == "PUT" })
    }
}
