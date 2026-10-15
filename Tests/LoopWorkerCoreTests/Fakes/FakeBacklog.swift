import Foundation
@testable import LoopWorkerCore

/// An in-memory backlog. Cards move between states the way a real backlog's would, every
/// write is recorded in `writes`, and each read can be made to throw.
final class FakeBacklog: Backlog, @unchecked Sendable {
    enum Write: Equatable {
        case claim(String)
        case release(String, reason: String, countsAsAttempt: Bool)
        case markStuck(String, blocker: String)
        case markReview(String, url: URL)
        case markVerifying(String, url: URL)
        case markMerged(String, url: URL)
        case resumeFix(String)
        case recordPush(String, PushRecord)
    }

    struct State {
        var cards: [String: Card] = [:]
        var snapshots: [String: CardSnapshot] = [:]
        var writes: [Write] = []
        var failCard: Set<String> = []
        var failWorkable = false
        var failWorking = false
        var failRelease = false
        var failMarkReview: (any Error)?
        var failMarkVerifying: (any Error)?
        var failMarkMerged: (any Error)?
        /// The plan each `markVerifying` got, by card id.
        var verifyingPlans: [String: VerifyingPlan] = [:]
        /// The note each `markMerged` got, by card id.
        var mergedNotes: [String: String] = [:]
        var failVerifying = false
        /// `resumeFix` returns this instead of checking the card.
        var resumeFixOverride: Bool?
        var failResumeFix = false
        /// The note each `markReview` got, by card id.
        var reviewNotes: [String: String] = [:]
        var claimOverride: Bool?
        /// `claim` throws after (true) or instead of (false) moving the card, like a lost response.
        var claimThrows: Bool?
        /// A rival Manager's newer claim: `claim` succeeds but records this holder instead.
        var rivalHolder: String?
        var workableCalls: [[String]] = []
        var cardCalls: [String] = []
        /// When set, `card(_:)` waits on it after recording the call.
        var cardGate: Gate?
        /// Manager notes by card id: `markStuck` and `release` append theirs.
        var notes: [String: [String]] = [:]
        var failManagerNotes = false
        /// The next `markStuck` throws this instead.
        var failMarkStuckOnce: (any Error)?
        /// Every push that a write recorded, in order; `lastPush` returns the card's last one.
        var pushes: [(card: String, push: PushRecord)] = []
        var failLastPush = false
        var failRecordPush = false
    }

    let state = Guarded(State())

    @discardableResult
    func add(_ card: Card, snapshot: CardSnapshot? = nil) -> Card {
        state {
            $0.cards[card.ref.id] = card
            if let snapshot { $0.snapshots[card.ref.id] = snapshot }
        }
        return card
    }

    func card(id: String) -> Card? { state.get.cards[id] }
    var writes: [Write] { state.get.writes }
    func setState(_ id: String, _ s: CardState) { state { $0.cards[id]?.state = s } }

    func workable(in projects: [ProjectSpec]) async throws -> [Card] {
        try state {
            $0.workableCalls.append(projects.map(\.path))
            if $0.failWorkable { throw FakeError("workable failed") }
            let keys = Set(projects.map { $0.path.lowercased() })
            return $0.cards.values
                .filter { $0.state == .ready && keys.contains($0.project.lowercased()) }
                .sorted { ($0.priority, $1.ref.id) > ($1.priority, $0.ref.id) }
        }
    }

    func card(_ ref: CardRef) async throws -> Card? {
        let gate = state {
            $0.cardCalls.append(ref.id)
            return $0.cardGate
        }
        await gate?.wait()
        return try state {
            if $0.failCard.contains(ref.id) { throw FakeError("card \(ref.display) read failed") }
            return $0.cards[ref.id]
        }
    }

    func working(in projects: [ProjectSpec]) async throws -> [Card] {
        try state {
            if $0.failWorking { throw FakeError("working failed") }
            let keys = Set(projects.map { $0.path.lowercased() })
            return $0.cards.values.filter { $0.state == .working && keys.contains($0.project.lowercased()) }
        }
    }

    func verifying(in projects: [ProjectSpec]) async throws -> [Card] {
        try state {
            if $0.failVerifying { throw FakeError("verifying failed") }
            let keys = Set(projects.map { $0.path.lowercased() })
            return $0.cards.values.filter { $0.state == .verifying && keys.contains($0.project.lowercased()) }
        }
    }

    func lastPush(_ card: Card) async throws -> PushRecord? {
        try state {
            if $0.failLastPush { throw FakeError("lastPush \(card.ref) failed") }
            return $0.pushes.last { $0.card == card.ref.id }?.push
        }
    }

    func recordPush(_ card: Card, pushed: PushRecord) async throws {
        try state {
            if $0.failRecordPush { throw FakeError("recordPush \(card.ref) failed") }
            guard $0.pushes.last(where: { $0.card == card.ref.id })?.push != pushed else { return }
            $0.writes.append(.recordPush(card.ref.id, pushed))
            $0.pushes.append((card.ref.id, pushed))
        }
    }

    func pushes(_ id: String) -> [PushRecord] { state.get.pushes.filter { $0.card == id }.map(\.push) }

    func markVerifying(_ card: Card, review: ReviewRequest, plan: VerifyingPlan, pushed: PushRecord?) async throws {
        try state {
            if let e = $0.failMarkVerifying { throw e }
            guard $0.cards[card.ref.id]?.state == .working else { throw FakeError("markVerifying \(card.ref): not working") }
            if let pushed { $0.pushes.append((card.ref.id, pushed)) }
            $0.writes.append(.markVerifying(card.ref.id, url: review.url))
            $0.verifyingPlans[card.ref.id] = plan
            $0.cards[card.ref.id]?.state = .verifying
        }
    }

    func markMerged(_ card: Card, review: ReviewRequest, note: String?) async throws {
        try state {
            if let e = $0.failMarkMerged { throw e }
            guard $0.cards[card.ref.id]?.state == .verifying else { throw FakeError("markMerged \(card.ref): not verifying") }
            $0.writes.append(.markMerged(card.ref.id, url: review.url))
            $0.mergedNotes[card.ref.id] = note
            $0.cards[card.ref.id]?.state = .reviewMerged
        }
    }

    func resumeFix(_ card: Card) async throws -> Bool {
        try state {
            $0.writes.append(.resumeFix(card.ref.id))
            if $0.failResumeFix { throw FakeError("resumeFix \(card.ref) failed") }
            if let o = $0.resumeFixOverride { return o }
            guard $0.cards[card.ref.id]?.state == .verifying else { return false }
            $0.cards[card.ref.id]?.state = .working
            return true
        }
    }

    func claim(_ card: Card, holder: String) async throws -> Bool {
        try state {
            $0.writes.append(.claim(card.ref.id))
            if let landed = $0.claimThrows {
                if landed {
                    $0.cards[card.ref.id]?.state = .working
                    $0.cards[card.ref.id]?.holder = holder
                }
                throw FakeError("no response from the backlog")
            }
            if let o = $0.claimOverride { return o }
            guard $0.cards[card.ref.id]?.state == .ready else { return false }
            $0.cards[card.ref.id]?.state = .working
            $0.cards[card.ref.id]?.holder = $0.rivalHolder ?? holder
            return true
        }
    }

    func snapshot(_ card: Card) async throws -> CardSnapshot {
        state { $0.snapshots[card.ref.id] ?? CardSnapshot(markdown: "# \(card.title)\n") }
    }

    func managerNotes(_ card: Card) async throws -> [String] {
        try state {
            if $0.failManagerNotes { throw FakeError("managerNotes \(card.ref) failed") }
            return $0.notes[card.ref.id] ?? []
        }
    }

    func markReview(_ card: Card, review: ReviewRequest, note: String?, pushed: PushRecord?) async throws {
        try state {
            if let e = $0.failMarkReview { throw e }
            if let pushed { $0.pushes.append((card.ref.id, pushed)) }
            $0.writes.append(.markReview(card.ref.id, url: review.url))
            $0.reviewNotes[card.ref.id] = note
            $0.cards[card.ref.id]?.state = .review
        }
    }

    func markStuck(_ card: Card, blocker: String, pushed: PushRecord?) async throws {
        try state {
            if let e = $0.failMarkStuckOnce { $0.failMarkStuckOnce = nil; throw e }
            if let pushed { $0.pushes.append((card.ref.id, pushed)) }
            $0.writes.append(.markStuck(card.ref.id, blocker: blocker))
            $0.notes[card.ref.id, default: []].append(blocker)
            $0.cards[card.ref.id]?.state = .stuck
        }
    }

    func release(_ card: Card, reason: String, countsAsAttempt: Bool) async throws {
        try state {
            if $0.failRelease { throw FakeError("release failed") }
            $0.writes.append(.release(card.ref.id, reason: reason, countsAsAttempt: countsAsAttempt))
            $0.notes[card.ref.id, default: []].append(reason)
            $0.cards[card.ref.id]?.state = .ready
            $0.cards[card.ref.id]?.holder = nil
            if countsAsAttempt { $0.cards[card.ref.id]?.attempts += 1 }
        }
    }
}
