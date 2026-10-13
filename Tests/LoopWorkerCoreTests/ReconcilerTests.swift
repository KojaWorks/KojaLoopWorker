import Testing
@testable import LoopWorkerCore

@Suite struct ReconcilerTests {
    let policy = ReconcilePolicy(outcomeGrace: 20, wallclockCap: 3600)

    func decide(
        _ state: CardState?, alive: Bool = true, auth: Bool = false,
        outcomeAge: Double? = nil, running: Double = 60
    ) -> SlotDecision {
        Reconciler.decide(
            SlotObservation(cardState: state, sessionAlive: alive, authFailed: auth,
                            outcomeAge: outcomeAge, runningFor: running),
            policy: policy)
    }

    @Test func healthyWorkerIsKept() {
        #expect(decide(.working) == .keep)
    }

    @Test func goneCardIsAbandoned() {
        #expect(decide(nil) == .abandon("card no longer exists"))
    }

    @Test func cardMovedByAHumanIsAbandonedEvenWithAnOutcome() {
        #expect(decide(.ready, outcomeAge: 100) == .abandon("card moved to ready outside the loop"))
    }

    @Test func outcomeWaitsForGraceWhileSessionIsAlive() {
        #expect(decide(.working, outcomeAge: 5) == .keep)
        #expect(decide(.working, outcomeAge: 20) == .finish)
    }

    @Test func outcomeFinishesAtOnceWhenSessionIsDead() {
        #expect(decide(.working, alive: false, outcomeAge: 1) == .finish)
    }

    @Test func outcomeBeatsTheWallclockCap() {
        #expect(decide(.working, outcomeAge: 30, running: 99_999) == .finish)
    }

    @Test func deadSessionWithoutOutcomeIsACrash() {
        #expect(decide(.working, alive: false) == .release(.crashed))
    }

    @Test func authScreenIsReleasedBeforeTheCap() {
        #expect(decide(.working, auth: true) == .release(.auth))
    }

    @Test func overTheCapIsHung() {
        #expect(decide(.working, running: 3601) == .release(.hung))
    }
}
