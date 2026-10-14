import Foundation
@testable import LoopWorkerCore

/// Records lifecycle calls as `"<verb> <key>/<index>"`. Failures are injected per verb.
final class FakeLifecycle: SlotLifecycle, @unchecked Sendable {
    struct State {
        var calls: [String] = []
        var acquireFailure: SlotFailure?
        var prepareFailure: SlotFailure?
        var acquiredBranches: [String] = []
        var acquiredBases: [String] = []
        /// When set, `prepare` waits on it after recording the call.
        var prepareGate: Gate?
        /// The teardown script name of the contract each `recycle` got.
        var recycledWithTeardown: [String] = []
    }

    let state = Guarded(State())
    var calls: [String] { state.get.calls }

    private func id(_ slot: SlotSpec) -> String { "\(slot.project.key)/\(slot.index)" }

    func prepare(_ slot: SlotSpec, contract: ProjectContract) async throws(SlotFailure) {
        let (failure, gate): (SlotFailure?, Gate?) = state {
            $0.calls.append("prepare \(id(slot))")
            return (slot.project.hot ? $0.prepareFailure : nil, $0.prepareGate)
        }
        await gate?.wait()
        if let failure { throw failure }
    }

    func acquire(_ slot: SlotSpec, contract: ProjectContract, base: String, branch: String) async throws(SlotFailure) -> String {
        let failure: SlotFailure? = state {
            $0.calls.append("acquire \(id(slot))")
            $0.acquiredBranches.append(branch)
            $0.acquiredBases.append(base)
            return $0.acquireFailure
        }
        if let failure { throw failure }
        return "base123"
    }

    func recycle(_ slot: SlotSpec, contract: ProjectContract) async {
        state {
            $0.calls.append("recycle \(id(slot))")
            $0.recycledWithTeardown.append(contract.scripts.teardown)
        }
    }

    func retire(_ slot: SlotSpec, contract: ProjectContract) async {
        state { $0.calls.append("retire \(id(slot))") }
    }
}

final class FakeEngine: EngineRecovering, @unchecked Sendable {
    let result = Guarded(true)
    let calls = Guarded(0)

    func recover() async -> Bool {
        calls { $0 += 1 }
        return result.get
    }
}
