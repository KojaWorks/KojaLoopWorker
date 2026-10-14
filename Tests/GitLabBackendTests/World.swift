import Foundation
import LoopWorkerCore
@testable import GitLabBackend

/// A fake GitLab with one trusted ready card, `mygroup/app#12`: created by me at minute 0,
/// assigned by me at minute 1, `loopworker::next` added by me at minute 2.
struct World {
    let gitlab = FakeGitLab()
    let log = CollectingLog()
    let sleeps = SleepRecorder()
    var toml: String
    let home = FileManager.default.temporaryDirectory.appending(path: "lw-gitlab-\(UUID())")

    init(statusMode: String = "none", extra: String = "") {
        toml = """
            [backlog]
            kind = "gitlab"

            [backlog.gitlab]
            base_url = "https://gitlab.example.com"
            allowed = ["mygroup/"]
            status_mode = "\(statusMode)"
            \(extra)

            [[project]]
            path = "mygroup/app"

            [[project]]
            path = "elsewhere/tool"
            """
        gitlab.on("GET", "/api/v4/user", json: Fixture.me)
        gitlab.on("GET", "/api/v4/projects/7", json: ["id": 7, "path_with_namespace": "mygroup/app", "default_branch": "main"])
        gitlab.on("GET", "/api/v4/projects/8", json: ["id": 8, "path_with_namespace": "elsewhere/tool", "default_branch": "main"])
        gitlab.on("GET", "/api/v4/projects/9", json: ["id": 9, "path_with_namespace": "mygroup/unserved", "default_branch": "main"])
        issue(Fixture.issue())
        notes([Fixture.assigned()])
        events([Fixture.labelEvent(1, at: 2)])
    }

    func issue(_ issue: [String: Any], listedAs label: String = "loopworker::next") {
        let iid = issue["iid"] as! Int, pid = issue["project_id"] as! Int
        gitlab.on("GET", "/api/v4/projects/\(pid)/issues/\(iid)", json: issue)
        listed([issue], as: label)
    }

    func listed(_ issues: [[String: Any]], as label: String = "loopworker::next") {
        gitlab.on("GET", "/api/v4/issues", query: ["labels": label], json: issues)
    }

    func notes(_ notes: [[String: Any]], iid: Int = 12, projectID: Int = Fixture.projectID) {
        gitlab.on("GET", "/api/v4/projects/\(projectID)/issues/\(iid)/notes", json: notes)
    }

    func events(_ events: [[String: Any]], iid: Int = 12, projectID: Int = Fixture.projectID) {
        gitlab.on("GET", "/api/v4/projects/\(projectID)/issues/\(iid)/resource_label_events", json: events)
    }

    func make() throws -> (backlog: GitLabBacklog, forge: GitLabForge) {
        let config = try HostConfig.parse(toml, home: home)
        let sleeps = self.sleeps
        let made = try GitLabBackend.make(
            config: config, log: log, environment: ["LOOPWORKER_GITLAB_TOKEN": Fixture.token],
            transport: gitlab, sleep: { sleeps.sleep($0) })
        return (made.backlog!, made.forge!)
    }

    func backlog() throws -> GitLabBacklog { try make().backlog }

    static let app = ProjectSpec(path: "mygroup/app")
    static let tool = ProjectSpec(path: "elsewhere/tool")
    static let ref = CardRef(id: "7/12", display: "mygroup/app#12")
}
