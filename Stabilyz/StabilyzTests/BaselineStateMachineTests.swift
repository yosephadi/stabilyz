import Foundation
import Testing
@testable import Stabilyz

// MARK: - Progression

@Test func stateProgressesFromNotStartedThroughBuildingToEstablished() throws {
    #expect(try BaselineStateMachine.state(for: .quickTest, validSessionCount: 0, baseline: nil) == .notStarted)

    // docs/09 §9.4: building(1) … building(4), the "Session X of 5" states.
    for count in 1...4 {
        let state = try BaselineStateMachine.state(for: .quickTest, validSessionCount: count, baseline: nil)
        #expect(state == .building(validCount: count))
        #expect(state.isEstablished == false)
    }

    let baseline = Baseline.fixture(mode: .quickTest)
    let established = try BaselineStateMachine.state(for: .quickTest, validSessionCount: 5, baseline: baseline)
    #expect(established == .established(baseline))
}

@Test func invalidSessionsNeverAdvanceTheCounter() throws {
    // The counter is a count of *valid* sessions only [PRD §6, §7]. Four valid
    // sessions plus any number of invalid ones is still building(4).
    let state = try BaselineStateMachine.state(for: .fullTest, validSessionCount: 4, baseline: nil)
    #expect(state == .building(validCount: 4))
    #expect(state.validCount == 4)
}

@Test func establishedBaselineIsFrozenRegardlessOfLaterSessions() throws {
    // [PRD §6] no recalibration in v1: more valid sessions do not change state.
    let baseline = Baseline.fixture(mode: .fullTest)

    for count in [5, 6, 20] {
        let state = try BaselineStateMachine.state(for: .fullTest, validSessionCount: count, baseline: baseline)
        #expect(state == .established(baseline))
    }
}

// MARK: - Establishment trigger

@Test func baselineIsReadyToEstablishOnTheFifthValidSession() {
    #expect(BaselineStateMachine.isReadyToEstablish(validSessionCount: 4, baseline: nil) == false)
    #expect(BaselineStateMachine.isReadyToEstablish(validSessionCount: 5, baseline: nil))

    // Already established: never re-established [PRD §6].
    #expect(BaselineStateMachine.isReadyToEstablish(validSessionCount: 5, baseline: .fixture()) == false)
    #expect(BaselineStateMachine.isReadyToEstablish(validSessionCount: 9, baseline: .fixture()) == false)
}

@Test func aRolledBackEstablishmentStaysReadyRatherThanBeingLost() throws {
    // docs/09 §9.4: the count is derived, so a failed commit leaves the mode
    // ready to establish rather than stuck.
    #expect(BaselineStateMachine.isReadyToEstablish(validSessionCount: 5, baseline: nil))

    let state = try BaselineStateMachine.state(for: .quickTest, validSessionCount: 5, baseline: nil)
    #expect(state.isEstablished == false)
    #expect(state == .baselineRefused(validCount: 5))
}

// MARK: - Mode segregation [PRD OQ-5]

@Test func threeQuickAndTwoFullProduceNoBaselineInEitherMode() throws {
    // docs/09 §9.7 item 4 / [PRD §6 edge case]: the two modes never pool.
    let quick = try BaselineStateMachine.state(for: .quickTest, validSessionCount: 3, baseline: nil)
    let full = try BaselineStateMachine.state(for: .fullTest, validSessionCount: 2, baseline: nil)

    #expect(quick == .building(validCount: 3))
    #expect(full == .building(validCount: 2))
    #expect(quick.isEstablished == false)
    #expect(full.isEstablished == false)
    #expect(BaselineStateMachine.isReadyToEstablish(validSessionCount: 3, baseline: nil) == false)
    #expect(BaselineStateMachine.isReadyToEstablish(validSessionCount: 2, baseline: nil) == false)
}

@Test func anEstablishedModeDoesNotAdvanceTheOtherMode() throws {
    // [PRD §6] a user with a Quick baseline starting Full Tests begins at 1 of 5.
    let quickBaseline = Baseline.fixture(mode: .quickTest)

    let quick = try BaselineStateMachine.state(for: .quickTest, validSessionCount: 7, baseline: quickBaseline)
    let full = try BaselineStateMachine.state(for: .fullTest, validSessionCount: 1, baseline: nil)

    #expect(quick.isEstablished)
    #expect(full == .building(validCount: 1))
}

@Test func aBaselineFromTheWrongModeIsRejected() {
    // Tolerating this would blend the modes — the one thing [PRD OQ-5] forbids.
    #expect(throws: BaselineStateMachine.StateError.baselineModeMismatch(expected: .fullTest, actual: .quickTest)) {
        try BaselineStateMachine.state(for: .fullTest, validSessionCount: 5, baseline: .fixture(mode: .quickTest))
    }
}

@Test func negativeCountsAreRejected() {
    #expect(throws: BaselineStateMachine.StateError.negativeValidSessionCount(-1)) {
        try BaselineStateMachine.state(for: .quickTest, validSessionCount: -1, baseline: nil)
    }
}

// MARK: - A refused baseline is its own state (Task 9.2.1)

@Test func fiveOrMoreValidWalksWithNoBaselineReadAsRefusedNeverAsBuilding() throws {
    for count in [5, 6, 7, 20] {
        let state = try BaselineStateMachine.state(for: .quickTest, validSessionCount: count, baseline: nil)
        #expect(state == .baselineRefused(validCount: count))
        #expect(state.isEstablished == false)
        // Capped: nothing reading the count can print "7 of 5".
        #expect(state.validCount == 5)
        // No baseline, so no metronome, and the pre-baseline cue stays offered.
        #expect(state.allowsMetronome == false)
        #expect(state.allowsStepFeedback)
    }
}

@Test func buildingOnlyEverMeansOneToFour() throws {
    for count in 0...20 {
        let state = try BaselineStateMachine.state(for: .fullTest, validSessionCount: count, baseline: nil)
        if case .building(let building) = state {
            #expect((1...4).contains(building), "building(\(building)) escaped the state machine")
        }
    }
}

@Test func aRefusedModeDoesNotAffectTheOtherMode() throws {
    let quick = try BaselineStateMachine.state(for: .quickTest, validSessionCount: 6, baseline: nil)
    let full = try BaselineStateMachine.state(for: .fullTest, validSessionCount: 2, baseline: nil)
    #expect(quick == .baselineRefused(validCount: 6))
    #expect(full == .building(validCount: 2))
}
