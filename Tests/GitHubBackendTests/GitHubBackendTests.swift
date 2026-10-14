import Foundation
import LoopWorkerCore
import Testing
@testable import GitHubBackend
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers each request from `respond` and records it.
private final class StubGitHub: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _sleeps: [Double] = []
    var respond: (URLRequest, Int) -> (Int, [String: String], String)
    init(_ respond: @escaping (URLRequest, Int) -> (Int, [String: String], String)) { self.respond = respond }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var sleeps: [Double] { lock.withLock { _sleeps } }
    func slept(_ s: Double) { lock.withLock { _sleeps.append(s) } }

    var transport: HTTPTransport {
        { [self] req in
            let (status, headers, body) = lock.withLock { () -> (Int, [String: String], String) in
                _requests.append(req)
                return respond(req, _requests.count)
            }
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }
}

private final class NullLog: LogSink {
    func log(_ level: LogLevel, _ message: String) {}
}

private let project = ProjectSpec(path: "owner/app")

private func host(_ forge: String = "") throws -> HostConfig {
    let home = FileManager.default.temporaryDirectory.appending(path: "lw-github-\(UUID().uuidString)")
    return try HostConfig.parse("""
        [backlog]
        kind = "patch"
        [forge]
        kind = "github"
        \(forge)
        [[project]]
        path = "owner/app"
        """, home: home)
}

private func forge(_ stub: StubGitHub, _ forgeSection: String = "") throws -> GitHubForge {
    try GitHubBackend.makeForge(
        config: host(forgeSection), log: NullLog(), environment: ["GITHUB_TOKEN": "ghp_FAKE0000"],
        transport: stub.transport, sleep: { stub.slept($0) }, now: { Date(timeIntervalSince1970: 1_000) })
}

private func draft(_ isDraft: Bool = true, assign: Bool = false) -> ReviewRequestDraft {
    ReviewRequestDraft(
        project: project, card: Card(ref: CardRef(id: "u1", display: "~1"), project: "owner/app", title: "t", state: .working),
        sourceBranch: "loopworker-1-add-export", targetBranch: "main", title: "Add export", body: "Body", draft: isDraft,
        assignToOwner: assign)
}

private let pullJSON = #"{"number": 7, "html_url": "https://github.com/owner/app/pull/7"}"#

@Suite struct GitHubForgeTests {
    @Test func cloneURLAndGitEnvironmentCarryNoTokenInTheURL() throws {
        let f = try forge(StubGitHub { _, _ in (500, [:], "") })
        #expect(f.cloneURL(for: project) == "https://github.com/owner/app.git")
        let env = f.gitEnvironment()
        #expect(env[GitAskPass.usernameVariable] == "x-access-token")
        #expect(env[GitAskPass.passwordVariable] == "ghp_FAKE0000")
        #expect(FileManager.default.fileExists(atPath: env["GIT_ASKPASS"]!))
    }

    @Test func enterpriseCloneURLDropsTheAPIPath() throws {
        let f = try forge(StubGitHub { _, _ in (500, [:], "") }, "[forge.github]\napi_base = \"https://ghe.example.com/api/v3\"")
        #expect(f.cloneURL(for: project) == "https://ghe.example.com/owner/app.git")
    }

    @Test func missingTokenIsAConfigError() throws {
        #expect(throws: ConfigError.self) { try GitHubBackend.makeForge(config: host(), log: NullLog(), environment: [:]) }
    }

    @Test func defaultBranchReadsTheRepo() async throws {
        let stub = StubGitHub { req, _ in
            #expect(req.url?.path == "/repos/owner/app")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_FAKE0000")
            return (200, [:], #"{"default_branch": "trunk"}"#)
        }
        #expect(try await forge(stub).defaultBranch(for: project) == "trunk")
    }

    @Test func openReviewRequestReturnsTheOpenPullRequest() async throws {
        let stub = StubGitHub { _, _ in (200, [:], "[\(pullJSON)]") }
        let pr = try await forge(stub).openReviewRequest(draft())
        #expect(pr == ReviewRequest(url: URL(string: "https://github.com/owner/app/pull/7")!, display: "owner/app#7"))
        #expect(stub.requests.count == 1)
        let query = URLComponents(url: stub.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(URLQueryItem(name: "head", value: "owner:loopworker-1-add-export")))
        #expect(query.contains(URLQueryItem(name: "state", value: "open")))
    }

    @Test func openReviewRequestCreatesADraft() async throws {
        let stub = StubGitHub { req, _ in req.httpMethod == "GET" ? (200, [:], "[]") : (201, [:], pullJSON) }
        let pr = try await forge(stub).openReviewRequest(draft())
        #expect(pr.display == "owner/app#7")
        let post = try #require(stub.requests.last)
        #expect(post.httpMethod == "POST")
        #expect(post.url?.path == "/repos/owner/app/pulls")
        let body = try JSONSerialization.jsonObject(with: post.httpBody!) as! [String: Any]
        #expect(body["draft"] as? Bool == true)
        #expect(body["head"] as? String == "loopworker-1-add-export")
        #expect(body["base"] as? String == "main")
        #expect(body["title"] as? String == "Add export")
        #expect(body["body"] as? String == "Body")
    }

    @Test("B186: a new pull request is assigned to the token's login")
    func aNewPullRequestIsAssigned() async throws {
        let stub = StubGitHub { req, _ in
            switch (req.httpMethod!, req.url!.path) {
            case ("GET", "/user"): (200, [:], #"{"login": "octo"}"#)
            case ("GET", _): (200, [:], "[]")
            case (_, "/repos/owner/app/issues/7/assignees"): (201, [:], #"{"number": 7}"#)
            default: (201, [:], pullJSON)
            }
        }
        _ = try await forge(stub).openReviewRequest(draft(assign: true))
        let assign = try #require(stub.requests.last)
        #expect(assign.httpMethod == "POST")
        #expect(assign.url?.path == "/repos/owner/app/issues/7/assignees")
        #expect(try JSONSerialization.jsonObject(with: assign.httpBody!) as? [String: [String]] == ["assignees": ["octo"]])
    }

    @Test("B186: an open pull request gets the assignee only when it has none")
    func anOpenPullRequestWithoutAssigneeIsAssigned() async throws {
        for (assignees, expected) in [("[]", 1), (#"[{"login": "octo"}]"#, 0)] {
            let stub = StubGitHub { req, _ in
                switch (req.httpMethod!, req.url!.path) {
                case ("GET", "/user"): (200, [:], #"{"login": "octo"}"#)
                case ("GET", _): (200, [:], #"[{"number": 7, "html_url": "https://github.com/owner/app/pull/7", "assignees": \#(assignees)}]"#)
                default: (201, [:], "{}")
                }
            }
            _ = try await forge(stub).openReviewRequest(draft(assign: true))
            #expect(stub.requests.filter { $0.url?.path == "/repos/owner/app/issues/7/assignees" }.count == expected)
            #expect(!stub.requests.contains { $0.url?.path == "/repos/owner/app/pulls" && $0.httpMethod == "POST" })
        }
    }

    @Test func aRepoThatRefusesDraftsGetsAReadyPullRequest() async throws {
        let stub = StubGitHub { req, n in
            if req.httpMethod == "GET" { return (200, [:], "[]") }
            return n == 2
                ? (422, [:], #"{"message": "Validation Failed", "errors": [{"message": "Draft pull requests are not supported in this repository."}]}"#)
                : (201, [:], pullJSON)
        }
        _ = try await forge(stub).openReviewRequest(draft())
        let last = try JSONSerialization.jsonObject(with: stub.requests.last!.httpBody!) as! [String: Any]
        #expect(last["draft"] as? Bool == false)
    }

    @Test func attachIsNil() async throws {
        let stub = StubGitHub { _, _ in (500, [:], "") }
        #expect(try await forge(stub).attach(URL(filePath: "/tmp/guide.html"), to: project) == nil)
        #expect(stub.requests.isEmpty)
    }

    @Test func a422IsABackendRejection() async throws {
        let stub = StubGitHub { req, _ in
            req.httpMethod == "GET" ? (200, [:], "[]") : (422, [:], #"{"message": "Validation Failed", "errors": [{"message": "No commits between main and x"}]}"#)
        }
        await #expect(throws: BackendRejection("POST /repos/owner/app/pulls: 422 Validation Failed: No commits between main and x")) {
            try await forge(stub).openReviewRequest(draft(false))
        }
    }

    @Test func a401NamesTheTokenVariable() async throws {
        let stub = StubGitHub { _, _ in (401, [:], #"{"message": "Bad credentials"}"#) }
        await #expect(throws: GitHubError.unauthorized(tokenEnv: "GITHUB_TOKEN", request: "GET /repos/owner/app", status: 401, message: "Bad credentials")) {
            try await forge(stub).defaultBranch(for: project)
        }
        #expect(stub.requests.count == 1)
    }

    @Test func a429HonorsRetryAfter() async throws {
        let stub = StubGitHub { _, n in n == 1 ? (429, ["Retry-After": "7"], "{}") : (200, [:], #"{"default_branch": "main"}"#) }
        #expect(try await forge(stub).defaultBranch(for: project) == "main")
        #expect(stub.sleeps == [7])
    }

    @Test func aSpentRateLimit403WaitsForTheReset() async throws {
        let stub = StubGitHub { _, n in
            n == 1
                ? (403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1030"], #"{"message": "API rate limit exceeded"}"#)
                : (200, [:], #"{"default_branch": "main"}"#)
        }
        #expect(try await forge(stub).defaultBranch(for: project) == "main")
        #expect(stub.sleeps == [30])
    }

    @Test func persistent5xxGivesUpAfterThreeRetries() async throws {
        let stub = StubGitHub { _, _ in (502, [:], "bad gateway") }
        await #expect(throws: GitHubError.unavailable(request: "GET /repos/owner/app", status: 502, message: "bad gateway")) {
            try await forge(stub).defaultBranch(for: project)
        }
        #expect(stub.sleeps == [2, 4, 8])
        #expect(stub.requests.count == 4)
    }
}

@Suite struct GitHubPipelineTests {
    func runs(_ runs: [String], total: Int? = nil) -> String {
        #"{"total_count": \#(total ?? runs.count), "check_runs": [\#(runs.joined(separator: ","))]}"#
    }
    func run(_ name: String, _ status: String, _ conclusion: String?, text: String? = nil) -> String {
        let c = conclusion.map { "\"\($0)\"" } ?? "null"
        let t = text.map { #""text": "\#($0)""# } ?? #""text": null"#
        return #"{"name": "\#(name)", "status": "\#(status)", "conclusion": \#(c), "html_url": "https://github.com/owner/app/runs/\#(name)", "output": {"summary": "summary of \#(name)", \#(t)}}"#
    }

    @Test("B173: no check runs is no pipeline; the commit's check runs are read")
    func none() async throws {
        let stub = StubGitHub { _, _ in (200, [:], #"{"total_count": 0, "check_runs": []}"#) }
        #expect(try await forge(stub).pipeline(for: project, commit: "abc123") == nil)
        #expect(stub.requests.first?.url?.path == "/repos/owner/app/commits/abc123/check-runs")
    }

    @Test("B173: check runs map to running, failed, canceled and passed",
          arguments: [
            ([("a", "completed", "success"), ("b", "in_progress", nil)], PipelineStatus.State.running),
            ([("a", "completed", "failure"), ("b", "queued", nil)], .running),
            ([("a", "completed", "failure"), ("b", "completed", "cancelled")], .failed),
            ([("a", "completed", "timed_out")], .failed),
            ([("a", "completed", "cancelled"), ("b", "completed", "success")], .canceled),
            ([("a", "completed", "success"), ("b", "completed", "neutral"), ("c", "completed", "skipped")], .passed),
            ([("a", "completed", "action_required")], .running),
          ] as [([(String, String, String?)], PipelineStatus.State)])
    func mapping(_ checks: [(String, String, String?)], _ state: PipelineStatus.State) async throws {
        let body = runs(checks.map { run($0.0, $0.1, $0.2) })
        let p = try await forge(StubGitHub { _, _ in (200, [:], body) }).pipeline(for: project, commit: "abc123")
        #expect(p?.state == state)
        #expect(p?.url == URL(string: "https://github.com/owner/app/commit/abc123/checks"))
    }

    @Test("B173: failed jobs come from the failing runs, with output text or summary as the tail; pages are followed")
    func failedJobsAndPages() async throws {
        let stub = StubGitHub { [self] _, n in
            n == 1 ? (200, [:], runs([run("test", "completed", "failure", text: "assert failed")], total: 2))
                   : (200, [:], runs([run("lint", "completed", "timed_out")], total: 2))
        }
        let p = try #require(try await forge(stub).pipeline(for: project, commit: "abc123"))
        #expect(p.state == .failed)
        #expect(p.failedJobs == [
            CIJob(name: "test", stage: "", url: URL(string: "https://github.com/owner/app/runs/test"), logTail: "assert failed"),
            CIJob(name: "lint", stage: "", url: URL(string: "https://github.com/owner/app/runs/lint"), logTail: "summary of lint"),
        ])
        let pages = stub.requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value }
        #expect(pages == ["1", "2"])
    }

    @Test("B181: only GitHub Actions jobs can be re-run, each through its rerun endpoint")
    func retry() async throws {
        let actions = #"{"id": 41, "app": {"slug": "github-actions"}, "name": "test", "status": "completed", "conclusion": "failure", "html_url": null, "output": null}"#
        let other = #"{"id": 42, "app": {"slug": "ci-app"}, "name": "lint", "status": "completed", "conclusion": "failure", "html_url": null, "output": null}"#
        let stub = StubGitHub { [self] req, _ in
            req.httpMethod == "POST" ? (201, [:], "") : (200, [:], runs([actions, other]))
        }
        let forge = try forge(stub)
        let jobs = try #require(try await forge.pipeline(for: project, commit: "abc123")).failedJobs
        #expect(jobs.map(\.id) == ["41", nil])
        #expect(try await !forge.retryJobs(project: project, jobs: jobs))
        #expect(try await forge.retryJobs(project: project, jobs: [jobs[0]]))
        let posts = stub.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.map(\.url?.path) == ["/repos/owner/app/actions/jobs/41/rerun"])
    }

    @Test("B181: a baseline is the latest completed check runs on the branch head, a passed run winning over a same-named failure")
    func baseline() async throws {
        let stub = StubGitHub { [self] _, _ in
            (200, [:], runs([
                run("test", "completed", "failure"), run("test", "completed", "success"),
                run("lint", "completed", "timed_out"), run("e2e", "completed", "cancelled"), run("other", "completed", "failure"),
            ]))
        }
        let b = try await forge(stub).baselineJobs(for: project, ref: "main", names: ["test", "lint", "e2e", "new"])
        #expect(b == [
            "test": .passed(URL(string: "https://github.com/owner/app/runs/test")), "lint": .failed(URL(string: "https://github.com/owner/app/runs/lint")),
            "e2e": .unknown, "new": .unknown,
        ])
        let url = try #require(stub.requests.first?.url)
        #expect(url.path == "/repos/owner/app/commits/heads/main/check-runs")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "status", value: "completed")) == true)
    }
}
