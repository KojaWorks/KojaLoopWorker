import Foundation
@testable import LoopWorkerCore

/// A forge that opens review requests in memory, idempotently per source branch, like the
/// real ones. `failNextOpen` makes the next `openReviewRequest` throw once.
final class FakeForge: Forge, @unchecked Sendable {
    struct State {
        var opened: [ReviewRequestDraft] = []
        var byBranch: [String: ReviewRequest] = [:]
        var openCalls = 0
        var failNextOpen: (any Error)?
        var attached: [URL] = []
        var supportsAttachments = true
        var defaultBranch = "main"
    }

    let state = Locked(State())
    static let environment = ["GIT_ASKPASS": "/fake/askpass", "LOOPWORKER_GIT_PASSWORD": "fabricated"]

    func cloneURL(for project: ProjectSpec) -> String { "https://forge.example/\(project.path).git" }
    func gitEnvironment() -> [String: String] { Self.environment }
    func defaultBranch(for project: ProjectSpec) async throws -> String { state.get.defaultBranch }

    func openReviewRequest(_ draft: ReviewRequestDraft) async throws -> ReviewRequest {
        try state {
            $0.openCalls += 1
            if let e = $0.failNextOpen { $0.failNextOpen = nil; throw e }
            if let existing = $0.byBranch[draft.sourceBranch] { return existing }
            let n = $0.opened.count + 1
            let rr = ReviewRequest(url: URL(string: "https://forge.example/\(draft.project.path)/-/merge_requests/\(n)")!,
                                   display: "\(draft.project.path)!\(n)")
            $0.opened.append(draft)
            $0.byBranch[draft.sourceBranch] = rr
            return rr
        }
    }

    func attach(_ file: URL, to project: ProjectSpec) async throws -> URL? {
        state {
            guard $0.supportsAttachments else { return nil }
            $0.attached.append(file)
            return URL(string: "https://forge.example/uploads/\(file.lastPathComponent)")
        }
    }
}
