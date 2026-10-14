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
        case resumeFix(String)
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
        var failVerifying = false
        /// `resumeFix` returns this instead of checking the card.
        var resumeFixOverride: Bool?
        var failResumeFix = false
        /// The note each `markReview` got, by card id.
        var reviewNotes: [String: String] = [:]
        var claimOverride: Bool?
        /// `claim` throws after (true) or instead of (false) moving the card, like a lost response.
        var claimThrows: Bool?
        var workableCalls: [[String]] = []
        var cardCalls: [String] = []
        /// When set, `card(_:)` waits on it after recording the call.
        var cardGate: Gate?
        /// Manager notes by card id: `markStuck` and `release` append theirs.
        var notes: [String: [String]] = [:]
        var failManagerNotes = false
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

    func markVerifying(_ card: Card, review: ReviewRequest) async throws {
        try state {
            if let e = $0.failMarkVerifying { throw e }
            guard $0.cards[card.ref.id]?.state == .working else { throw FakeError("markVerifying \(card.ref): not working") }
            $0.writes.append(.markVerifying(card.ref.id, url: review.url))
            $0.cards[card.ref.id]?.state = .verifying
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

    func claim(_ card: Card) async throws -> Bool {
        try state {
            $0.writes.append(.claim(card.ref.id))
            if let landed = $0.claimThrows {
                if landed { $0.cards[card.ref.id]?.state = .working }
                throw FakeError("no response from the backlog")
            }
            if let o = $0.claimOverride { return o }
            guard $0.cards[card.ref.id]?.state == .ready else { return false }
            $0.cards[card.ref.id]?.state = .working
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

    func markReview(_ card: Card, review: ReviewRequest, note: String?) async throws {
        try state {
            if let e = $0.failMarkReview { throw e }
            $0.writes.append(.markReview(card.ref.id, url: review.url))
            $0.reviewNotes[card.ref.id] = note
            $0.cards[card.ref.id]?.state = .review
        }
    }

    func markStuck(_ card: Card, blocker: String) async throws {
        state {
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
            if countsAsAttempt { $0.cards[card.ref.id]?.attempts += 1 }
        }
    }
}
