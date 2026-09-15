import Foundation
import SwiftData
import Testing
@testable import Stabilyz

private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func metrics(ad1: Double = 0.80) -> GaitMetrics {
    GaitMetrics(
        stepRegularity: ad1, strideRegularity: 0.78, cadenceMean: 109,
        stepTimeCV: 0.04, trunkMotionML: 1.0, trunkMotionVT: 2.0,
        stepTimeAsymmetry: 0.09, steps: nil, distance: nil,
        validStrideCount: 100, windowCount: 10
    )
}

/// Sessions are spaced a day apart so chronological order is unambiguous.
private func validSession(
    _ index: Int,
    mode: TestMode = .quickTest,
    algorithmVersion: String = "1.0.0-provisional",
    ad1: Double = 0.80
) -> GaitSession {
    let start = base.addingTimeInterval(Double(index) * 86_400)
    return GaitSession.valid(
        id: UUID(), mode: mode, startedAt: start,
        endedAt: start.addingTimeInterval(120),
        advertisedClockElapsed: mode.advertisedDuration,
        validWalkingDuration: .seconds(110), metrics: metrics(ad1: ad1),
        audioConfig: .none, algorithmVersion: algorithmVersion,
        appVersion: "1.0", deviceModel: "iPhone17,1"
    )
}

private func invalidSession(_ index: Int, mode: TestMode = .quickTest) -> GaitSession {
    let start = base.addingTimeInterval(Double(index) * 86_400)
    return GaitSession.invalid(
        id: UUID(), mode: mode, reason: .excessiveNoise, startedAt: start,
        endedAt: start.addingTimeInterval(120),
        advertisedClockElapsed: mode.advertisedDuration,
        validWalkingDuration: .seconds(30), audioConfig: .none,
        algorithmVersion: "1.0.0-provisional", appVersion: "1.0", deviceModel: "iPhone17,1"
    )
}

// MARK: - The calibration lifecycle (docs/09 §9.4)

@Test func theFourthValidCommitIsStillBuildingWithNoBaseline() async throws {
    let store = try InMemoryStore()

    var result: SessionCommitResult?
    for index in 0..<4 {
        result = try await store.commits.commit(validSession(index))
    }

    let final = try #require(result)
    #expect(final.validSessionCount == 4)
    #expect(final.state == .building(validCount: 4))
    #expect(final.baselineOutcome == .notReady(validCount: 4))
    #expect(try await store.baselines.baseline(mode: .quickTest) == nil)
}

@Test func theFifthValidCommitEstablishesTheBaselineAndFlipsTheState() async throws {
    let store = try InMemoryStore()
    var result: SessionCommitResult?

    for index in 0..<5 {
        result = try await store.commits.commit(validSession(index))
    }

    let final = try #require(result)
    #expect(final.validSessionCount == 5)
    #expect(final.state.isEstablished)

    guard case .established(let baseline) = final.baselineOutcome else {
        Issue.record("expected the fifth commit to establish a baseline")
        return
    }
    #expect(baseline.mode == .quickTest)
    #expect(baseline.sourceSessionIDs.count == 5)

    // Both the session and the baseline are in the store.
    let stored = try #require(try await store.baselines.baseline(mode: .quickTest))
    #expect(stored.id == baseline.id)
    #expect(try await store.sessions.validSessionCount(mode: .quickTest) == 5)
}

@Test func theSixthValidCommitLeavesTheBaselineUntouched() async throws {
    // [PRD §6] frozen: no recalibration, no updates from later sessions.
    let store = try InMemoryStore()
    for index in 0..<5 { try await store.commits.commit(validSession(index)) }
    let established = try #require(try await store.baselines.baseline(mode: .quickTest))

    // A sixth session with markedly different metrics.
    let result = try await store.commits.commit(validSession(5, ad1: 0.20))

    #expect(result.baselineOutcome == .alreadyEstablished)
    #expect(result.validSessionCount == 6)
    #expect(result.state.isEstablished)

    let after = try #require(try await store.baselines.baseline(mode: .quickTest))
    #expect(after == established)
    #expect(after.stats == established.stats)
    // The session itself is persisted.
    #expect(try await store.sessions.validSessionCount(mode: .quickTest) == 6)
}

@Test func invalidSessionsNeverAdvanceTheCount() async throws {
    // [PRD §6, §7] a noisy session does not count toward its mode's five.
    let store = try InMemoryStore()
    for index in 0..<4 { try await store.commits.commit(validSession(index)) }

    let result = try await store.commits.commit(invalidSession(4))

    #expect(result.validSessionCount == 4)
    #expect(result.state == .building(validCount: 4))
    #expect(try await store.baselines.baseline(mode: .quickTest) == nil)
    // The invalid session is still stored for diagnostics.
    #expect(try await store.sessions.sessions(mode: .quickTest, includeInvalid: true, limit: nil).count == 5)
}

// MARK: - Atomicity

@Test func aFailedBaselineInsertRollsBackTheSessionToo() async throws {
    // Forced failure at the baseline insert: the create-only check fires inside
    // the transaction, so the session written moments earlier must roll back
    // with it. Writing them separately would leave a session stored with no
    // baseline and the count reading five.
    let store = try InMemoryStore()
    try await store.writer.establish(.fixture(mode: .quickTest))

    let sessionsBefore = try await store.sessions.sessions(mode: .quickTest, includeInvalid: true, limit: nil)
    let baselinesBefore = try await store.baselines.allBaselines()

    let session = validSession(0)
    await #expect(throws: StoreWriter.WriteError.baselineAlreadyExists(mode: .quickTest)) {
        try await store.writer.commit(session, establishing: .fixture(mode: .quickTest))
    }

    let sessionsAfter = try await store.sessions.sessions(mode: .quickTest, includeInvalid: true, limit: nil)
    let baselinesAfter = try await store.baselines.allBaselines()

    // Byte-stable: neither the session nor a second baseline landed.
    #expect(sessionsAfter.map(\.id) == sessionsBefore.map(\.id))
    #expect(sessionsAfter.isEmpty)
    #expect(baselinesAfter.map(\.id) == baselinesBefore.map(\.id))
    #expect(baselinesAfter.count == 1)
}

@Test func theSessionAndBaselineLandTogether() async throws {
    let store = try InMemoryStore()
    let session = validSession(0)
    let baseline = Baseline.fixture(mode: .fullTest)

    try await store.writer.commit(session, establishing: baseline)

    #expect(try await store.sessions.session(id: session.id) != nil)
    #expect(try await store.baselines.baseline(mode: .fullTest)?.id == baseline.id)
}

// MARK: - Refusal (docs/decisions.md entry 17)

@Test func aMixedVersionSetCommitsTheSessionAndRefusesTheBaseline() async throws {
    let store = try InMemoryStore()
    for index in 0..<4 { try await store.commits.commit(validSession(index)) }

    // The fifth session was computed under a different algorithm version.
    let fifth = validSession(4, algorithmVersion: "2.0.0")
    let result = try await store.commits.commit(fifth)

    guard case .refused(let reason, let count) = result.baselineOutcome else {
        Issue.record("expected refusal, got \(result.baselineOutcome)")
        return
    }
    #expect(reason == .mixedAlgorithmVersions)
    #expect(count == 5)

    // The walk is valid data and is kept.
    #expect(try await store.sessions.session(id: fifth.id) != nil)
    #expect(result.validSessionCount == 5)
    // No baseline was invented.
    #expect(try await store.baselines.baseline(mode: .quickTest) == nil)
    // The count stands at five, pending — calibration is not restarted.
    #expect(result.state == .baselineRefused(validCount: 5))
    #expect(result.state.isEstablished == false)
}

@Test func aRefusalDoesNotRestartCalibration() async throws {
    // A sixth session must not reset the user to "1 of 5".
    let store = try InMemoryStore()
    for index in 0..<4 { try await store.commits.commit(validSession(index)) }
    try await store.commits.commit(validSession(4, algorithmVersion: "2.0.0"))

    let result = try await store.commits.commit(validSession(5, algorithmVersion: "2.0.0"))

    #expect(result.validSessionCount == 6)
    #expect(result.state.isEstablished == false)
    // Still refusing on the same first five, not starting over.
    if case .refused(let reason, _) = result.baselineOutcome {
        #expect(reason == .mixedAlgorithmVersions)
    } else {
        Issue.record("expected continued refusal, got \(result.baselineOutcome)")
    }
}

// MARK: - The counter is derived

@Test func theCountIsRecountedFromTheStoreNotAccumulated() async throws {
    // docs/09 §9.4: a rolled-back commit cannot corrupt a derived count.
    let store = try InMemoryStore()
    for index in 0..<3 { try await store.commits.commit(validSession(index)) }

    // A direct write behind the service's back: the next commit still recounts
    // correctly rather than trusting anything it remembered.
    try await store.writer.save(validSession(10))

    let result = try await store.commits.commit(validSession(11))
    #expect(result.validSessionCount == 5)
}

// MARK: - Mode segregation [PRD OQ-5, §6]

@Test func threeQuickAndTwoFullEstablishNoBaselineInEitherMode() async throws {
    let store = try InMemoryStore()

    for index in 0..<3 { try await store.commits.commit(validSession(index, mode: .quickTest)) }
    for index in 3..<5 { try await store.commits.commit(validSession(index, mode: .fullTest)) }

    #expect(try await store.stateStore.refresh(.quickTest) == .building(validCount: 3))
    #expect(try await store.stateStore.refresh(.fullTest) == .building(validCount: 2))
    #expect(try await store.baselines.allBaselines().isEmpty)
}

@Test func establishingOneModeLeavesTheOtherAtItsOwnCount() async throws {
    // [PRD §6] the new mode starts its own "1 of 5".
    let store = try InMemoryStore()
    for index in 0..<5 { try await store.commits.commit(validSession(index, mode: .quickTest)) }

    let result = try await store.commits.commit(validSession(5, mode: .fullTest))

    #expect(result.state == .building(validCount: 1))
    #expect(try await store.stateStore.refresh(.quickTest).isEstablished)
    #expect(try await store.baselines.baseline(mode: .fullTest) == nil)
    // The Quick baseline was built only from Quick sessions.
    let quick = try #require(try await store.baselines.baseline(mode: .quickTest))
    #expect(quick.mode == .quickTest)
}

// MARK: - State broadcast (docs/09 §9.4)

@Test func everyCommitBroadcastsTheModesNewState() async throws {
    let store = try InMemoryStore()

    let collector = Task { () -> [BaselineStateChange] in
        var seen: [BaselineStateChange] = []
        for await change in store.stateStore.changes {
            seen.append(change)
            if seen.count == 3 { break }
        }
        return seen
    }

    for index in 0..<3 { try await store.commits.commit(validSession(index)) }
    let seen = await collector.value

    #expect(seen.count == 3)
    #expect(seen.allSatisfy { $0.mode == .quickTest })
    #expect(seen.last?.state == .building(validCount: 3))
}

@Test func theStateStoreCachesUntilRefreshed() async throws {
    let store = try InMemoryStore()
    #expect(await store.stateStore.current(.quickTest) == nil)

    try await store.commits.commit(validSession(0))
    #expect(await store.stateStore.current(.quickTest) == .building(validCount: 1))
}

@Test func rebuildRecomputesEveryModeWholesale() async throws {
    // The invalidation a restore needs (docs/11 §11.4): cached state describing
    // replaced data is thrown away, not patched.
    let store = try InMemoryStore()
    for index in 0..<2 { try await store.commits.commit(validSession(index, mode: .quickTest)) }
    #expect(await store.stateStore.current(.quickTest) == .building(validCount: 2))

    // Replace the store wholesale, as a restore does.
    try await store.writer.replaceAll(profile: nil, sessions: [], baselines: [])
    try await store.commits.rebuildState()

    #expect(await store.stateStore.current(.quickTest) == .notStarted)
    #expect(await store.stateStore.current(.fullTest) == .notStarted)
}

// MARK: - Compute before write

@Test func nothingIsWrittenBeforeTheCalculationIsAttempted() async throws {
    // The refusal path proves the ordering: the calculation runs, fails, and the
    // session is then committed on its own. If the write came first there would
    // be no way to distinguish "committed then refused" from "refused then
    // committed" — so the observable consequence is that no baseline row is ever
    // created and rolled back.
    let store = try InMemoryStore()
    for index in 0..<4 { try await store.commits.commit(validSession(index)) }
    try await store.commits.commit(validSession(4, algorithmVersion: "2.0.0"))

    #expect(try await store.baselines.allBaselines().isEmpty)
    #expect(try await store.sessions.validSessionCount(mode: .quickTest) == 5)
}
