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
