import Foundation
@testable import LoopWorkerCore

/// A forge that opens review requests in memory, idempotently per source branch, like the
/// real ones. `failNextOpen` makes the next `openReviewRequest` throw once.
final class FakeForge: Forge, @unchecked Sendable {
    struct State {
        var opened: [ReviewRequestDraft] = []
        var byBranch: [String: ReviewRequest] = [:]
        /// Every `openReviewRequest` call, including failed and deduplicated ones.
        var openCalls: [ReviewRequestDraft] = []
        var failNextOpen: (any Error)?
        var attached: [URL] = []
        var supportsAttachments = true
        var failAttach: (any Error)?
        var defaultBranch = "main"
        /// The pipeline per commit; a commit without one has no pipeline.
        var pipelines: [String: PipelineStatus] = [:]
        /// Every commit `pipeline` was asked about.
        var pipelineCalls: [String] = []
        var failPipeline = false
        /// How each job name did on the base branch; a missing name is `.unknown`.
        var baselines: [String: CIJobBaseline] = [:]
        /// `<ref>: <names>` per `baselineJobs` call.
        var baselineCalls: [String] = []
        var failBaseline = false
        /// The job ids of each `retryJobs` call.
        var retries: [[String]] = []
        var retrySupported = true
        var failRetry = false
    }

    let state = Guarded(State())
    static let environment = ["GIT_ASKPASS": "/fake/askpass", "LOOPWORKER_GIT_PASSWORD": "fabricated"]

    func cloneURL(for project: ProjectSpec) -> String { "https://forge.example/\(project.path).git" }
    func gitEnvironment() -> [String: String] { Self.environment }
    func defaultBranch(for project: ProjectSpec) async throws -> String { state.get.defaultBranch }

    func openReviewRequest(_ draft: ReviewRequestDraft) async throws -> ReviewRequest {
        try state {
            $0.openCalls.append(draft)
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

    func pipeline(for project: ProjectSpec, commit: String) async throws -> PipelineStatus? {
        try state {
            $0.pipelineCalls.append(commit)
            if $0.failPipeline { throw FakeError("pipeline read for \(commit) failed") }
            return $0.pipelines[commit]
        }
    }

    func baselineJobs(for project: ProjectSpec, ref: String, names: [String]) async throws -> [String: CIJobBaseline] {
        try state {
            $0.baselineCalls.append("\(ref): \(names.joined(separator: ", "))")
            if $0.failBaseline { throw FakeError("baseline read for \(ref) failed") }
            let known = $0.baselines
            return Dictionary(names.map { ($0, known[$0] ?? .unknown) }, uniquingKeysWith: { a, _ in a })
        }
    }

    func retryJobs(project: ProjectSpec, jobs: [CIJob]) async throws -> Bool {
        try state {
            $0.retries.append(jobs.map { $0.id ?? "nil" })
            if $0.failRetry { throw FakeError("retry failed") }
            return $0.retrySupported
        }
    }

    func attach(_ file: URL, to project: ProjectSpec) async throws -> URL? {
        try state {
            if let e = $0.failAttach { throw e }
            guard $0.supportsAttachments else { return nil }
            $0.attached.append(file)
            return URL(string: "https://forge.example/uploads/\(file.lastPathComponent)")
        }
    }
}
