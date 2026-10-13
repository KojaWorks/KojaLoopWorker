import Foundation
import LoopWorkerCore
import Testing
@testable import GitLabBackend

@Suite struct GitLabClientTests {
    let gitlab = FakeGitLab()
    let sleeps = SleepRecorder()
    var client: GitLabClient {
        let sleeps = self.sleeps
        return GitLabClient(
            connection: GitLabConnection(baseURL: URL(string: "https://gitlab.example.com")!, tokenEnv: "LOOPWORKER_GITLAB_TOKEN", token: Fixture.token),
            transport: gitlab, sleep: { sleeps.sleep($0) })
    }

    @Test func restRequestsCarryTheTokenHeaderAndATimeout() async throws {
        gitlab.on("GET", "/api/v4/user", json: Fixture.me)
        let me = try await client.me()
        #expect(me == GLUser(id: 1, username: "me"))
        #expect(gitlab.requests[0].headers["Authorization"] == "Bearer \(Fixture.token)")
        #expect(GitLabClient.requestTimeout == 30)
    }

    @Test func meIsReadOnce() async throws {
        gitlab.on("GET", "/api/v4/user", json: Fixture.me)
        let c = client
        _ = try await c.me()
        _ = try await c.me()
        #expect(gitlab.requests.count == 1)
    }

    @Test func B126_paginationFollowsNextPageToTheEnd() async throws {
        gitlab.on("GET", "/api/v4/projects/7/issues/12/notes", json: [Fixture.note(1, "a", at: 0)], headers: ["x-next-page": "2"])
        gitlab.on("GET", "/api/v4/projects/7/issues/12/notes", query: ["page": "2"], json: [Fixture.note(2, "b", at: 1)], headers: ["x-next-page": ""])
        let notes: [GLNote] = try await client.getAll("/projects/7/issues/12/notes")
        #expect(notes.map(\.id) == [1, 2])
        #expect(gitlab.requests.map { $0.query["per_page"] } == ["100", "100"])
    }

    @Test func B126_paginationFollowsASameHostLinkHeader() async throws {
        let next = "<https://gitlab.example.com/api/v4/projects/7/issues/12/notes?cursor=abc&per_page=100>; rel=\"next\""
        gitlab.on("GET", "/api/v4/projects/7/issues/12/notes", json: [Fixture.note(1, "a", at: 0)], headers: ["Link": next])
        gitlab.on("GET", "/api/v4/projects/7/issues/12/notes", query: ["cursor": "abc"], json: [Fixture.note(2, "b", at: 1)])
        let notes: [GLNote] = try await client.getAll("/projects/7/issues/12/notes")
        #expect(notes.map(\.id) == [1, 2])
    }

    @Test func linkHeaderToAnotherHostIsNotFollowed() async throws {
        let next = "<https://evil.example.net/api/v4/x?page=2>; rel=\"next\""
        gitlab.on("GET", "/api/v4/projects/7/issues/12/notes", json: [Fixture.note(1, "a", at: 0)], headers: ["Link": next])
        let notes: [GLNote] = try await client.getAll("/projects/7/issues/12/notes")
        #expect(notes.map(\.id) == [1])
        #expect(gitlab.requests.count == 1)
    }

    @Test func B126_aFailingSecondPageThrowsInsteadOfReturningPart() async throws {
        gitlab.on("GET", "/api/v4/projects/7/issues/12/notes", json: [Fixture.note(1, "a", at: 0)], headers: ["x-next-page": "2"])
        gitlab.on("GET", "/api/v4/projects/7/issues/12/notes", query: ["page": "2"], status: 502, json: ["message": "bad gateway"])
        let c = client
        await #expect(throws: GitLabError.self) {
            let _: [GLNote] = try await c.getAll("/projects/7/issues/12/notes")
        }
        #expect(gitlab.requests.count == 1 + 1 + GitLabClient.maxRetries)
    }

    @Test func B133_429IsRetriedAfterRetryAfter() async throws {
        gitlab.on("GET", "/api/v4/user", responses: [
            FakeGitLab.response(429, ["message": "slow down"], ["Retry-After": "7"]),
            FakeGitLab.response(429, ["message": "slow down"], ["Retry-After": "600"]),
            FakeGitLab.response(200, Fixture.me),
        ])
        let me = try await client.me()
        #expect(me.username == "me")
        #expect(sleeps.durations == [.seconds(7), .seconds(60)])
    }

    @Test func serverErrorsBackOffExponentiallyThenThrow() async throws {
        gitlab.on("GET", "/api/v4/user", status: 503, json: ["message": "down"])
        let c = client
        await #expect(throws: GitLabError.self) { try await c.me() }
        #expect(sleeps.durations == [.seconds(2), .seconds(4), .seconds(8)])
    }

    @Test func aPostIsNotRetriedOnA5xx() async throws {
        gitlab.on("POST", "/api/v4/projects/7/issues/12/notes", status: 500, json: ["message": "boom"])
        let c = client
        await #expect(throws: GitLabError.self) {
            let _: GLNote = try await c.send("POST", "/projects/7/issues/12/notes", body: ["body": "x"], idempotent: false)
        }
        #expect(gitlab.requests.count == 1)
    }

    @Test func B133_401FailsFastNamingTheTokenVariable() async throws {
        gitlab.on("GET", "/api/v4/user", status: 401, json: ["message": "401 Unauthorized"])
        let c = client
        let error = await #expect(throws: GitLabError.self) { try await c.me() }
        #expect(error?.description.contains("LOOPWORKER_GITLAB_TOKEN") == true)
        #expect(error?.description.contains("GET /user") == true)
        #expect(error?.description.contains(Fixture.token) == false)
        #expect(gitlab.requests.count == 1)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func a422IsABackendRejectionWithMethodPathAndBody() async throws {
        gitlab.on("POST", "/api/v4/projects/7/merge_requests", status: 422, json: ["message": ["title is too long"]])
        let c = client
        let error = await #expect(throws: BackendRejection.self) {
            let _: GLMergeRequest = try await c.send("POST", "/projects/7/merge_requests", body: [:], idempotent: false)
        }
        #expect(error?.description.contains("POST /projects/7/merge_requests: 422") == true)
        #expect(error?.description.contains("title is too long") == true)
    }

    @Test func a404IsNilOnlyWhereAsked() async throws {
        gitlab.on("GET", "/api/v4/projects/99", status: 404, json: ["message": "404 Project Not Found"])
        let c = client
        #expect(try await c.project(id: 99) == nil)
        await #expect(throws: BackendRejection.self) { let _: GLProject = try await c.get("/projects/99") }
    }

    @Test func graphQLErrorsThrowAndUseBearerAuth() async throws {
        gitlab.on("POST", "/api/graphql", json: ["errors": [["message": "Field 'nope' doesn't exist"]]])
        let c = client
        let error = await #expect(throws: GitLabError.self) {
            let _: [String: String] = try await c.graphQL("probe", "{ nope }", variables: [:])
        }
        #expect(error?.description.contains("doesn't exist") == true)
        #expect(gitlab.requests[0].headers["Authorization"] == "Bearer \(Fixture.token)")
    }

    @Test func projectPathsAreEncodedAsOneSegment() {
        #expect(GitLabPath.encode("group/sub/my.app") == "group%2Fsub%2Fmy.app")
        #expect(GitLabPath.encode("a+b c") == "a%2Bb%20c")
    }

    @Test func timesParseWithAndWithoutFractionsAndOffsets() {
        #expect(GitLabTime.parse("2026-10-01T10:00:00Z") != nil)
        #expect(GitLabTime.parse("2026-10-01T10:00:00.123Z") != nil)
        #expect(GitLabTime.parse("2026-10-01T12:00:00.000+02:00") == GitLabTime.parse("2026-10-01T10:00:00Z"))
    }
}
