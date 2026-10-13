import Foundation
import Testing
@testable import LoopWorkerCore

@Suite struct WorkerBriefTests {
    func brief(guide: Bool, excluded: [String] = [], projectBrief: String? = nil) -> String {
        let project = ProjectSpec(path: "g/app")
        let slot = SlotSpec(project: project, index: 0, clone: URL(filePath: "/c/g--app"),
                            worktree: URL(filePath: "/c/g--app.slots/0"), port: 54400,
                            stateDir: URL(filePath: "/h/slots/g--app/0"))
        let contract = ProjectContract(directory: URL(filePath: "/c/g--app.slots/0/.loopworker"),
                                       reviewGuide: guide, brief: projectBrief)
        return WorkerBrief(
            card: Card(ref: CardRef(id: "1", display: "g/app#7"), project: "g/app", title: "Fix it", state: .working),
            project: project, slot: slot, baseBranch: "main", branch: "loopworker/7-fix-it",
            snapshotFile: URL(filePath: "/h/slots/g--app/0/card.md"), excluded: excluded,
            contract: contract
        ).render()
    }

    @Test func namesTheCardWorktreeAndOutcome() {
        let b = brief(guide: false)
        #expect(b.contains(#"g/app#7 "Fix it" in g/app"#))
        #expect(b.contains("/c/g--app.slots/0"))
        #expect(b.contains("$LOOPWORKER_OUTCOME"))
        #expect(!b.contains("storygrafter"))
    }

    @Test func guideStepOnlyWhenTheContractAsks() {
        let b = brief(guide: true)
        #expect(b.contains("storygrafter"))
        #expect(b.contains(#""guide": "guide.html""#))
    }

    @Test func listsWithheldContentAndAppendsProjectBrief() {
        let b = brief(guide: false, excluded: ["comment 9 by @x"], projectBrief: "Use make.")
        #expect(b.contains("- comment 9 by @x"))
        #expect(b.hasSuffix("## Project brief\n\nUse make.\n"))
    }
}
