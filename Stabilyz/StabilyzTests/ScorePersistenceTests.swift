import Foundation
import SwiftData
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1
private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func metrics(ad1: Double = 0.80, ad2: Double = 0.78) -> GaitMetrics {
    GaitMetrics(
        stepRegularity: ad1, strideRegularity: ad2, cadenceMean: 109,
        stepTimeCV: 0.04, trunkMotionML: 1.0, trunkMotionVT: 2.0,
        stepTimeAsymmetry: 0.09, steps: nil, distance: nil,
        validStrideCount: 100, windowCount: 10, asymmetryAffectedSide: .left
    )
}

private func validSession(
    _ index: Int, mode: TestMode = .quickTest, ad1: Double = 0.80
) -> GaitSession {
    let start = base.addingTimeInterval(Double(index) * 86_400)
    return GaitSession.valid(
        id: UUID(), mode: mode, startedAt: start, endedAt: start.addingTimeInterval(120),
        advertisedClockElapsed: mode.advertisedDuration, validWalkingDuration: .seconds(110),
        metrics: metrics(ad1: ad1), audioConfig: .none, algorithmVersion: config.version,
        appVersion: "1.0", deviceModel: "iPhone17,1"
    )
}

private func invalidSession(_ index: Int, mode: TestMode = .quickTest) -> GaitSession {
    let start = base.addingTimeInterval(Double(index) * 86_400)
    return GaitSession.invalid(
        id: UUID(), mode: mode, reason: .excessiveNoise, startedAt: start,
        endedAt: start.addingTimeInterval(120), advertisedClockElapsed: mode.advertisedDuration,
        validWalkingDuration: .seconds(30), audioConfig: .none,
        algorithmVersion: config.version, appVersion: "1.0", deviceModel: "iPhone17,1"
    )
}

/// The partial score a pipeline run would hand the commit step, standardized
/// against a real baseline so the breakdown and summary have genuine inputs.
private func partialScore(
    for session: GaitSession,
    baseline: Baseline,
    relativeIndex: Int = 112
) throws -> PartialSessionScore {
    let sessionMetrics = try #require(session.metrics)
    let standardization = try #require(
        try BaselineNormalization.standardize(
            metrics: sessionMetrics, mode: session.mode,
            against: baseline, configuration: config
        )
    )
    return PartialSessionScore(
        relativeIndex: relativeIndex,
        compositeZ: 0.12,
        algorithmVersion: baseline.algorithmVersion,
        breakdown: MetricBreakdownBuilder.breakdown(from: standardization, metrics: sessionMetrics),
        standardization: standardization
    )
}

/// Commits five valid sessions, establishing the mode's baseline.
private func establishBaseline(
    in store: InMemoryStore, mode: TestMode = .quickTest
) async throws -> Baseline {
    for index in 0..<5 {
        try await store.commits.commit(validSession(index, mode: mode))
    }
    return try #require(try await store.baselines.baseline(mode: mode))
}

// MARK: - Scoring eligibility follows the PRD exactly

@Test func theFifthValidSessionEstablishesTheBaselineAndCarriesNoScore() async throws {
    // [PRD §7, docs/09 §9.5] the establishing session is shown as "building".
    let store = try InMemoryStore()
    var result: SessionCommitResult?

    for index in 0..<5 {
        let session = validSession(index)
        // Even if a caller offered a score, the fifth cannot take one: no
        // baseline existed when it was processed.
        result = try await store.commits.commit(session)
    }

    let fifth = try #require(result)
    #expect(fifth.state.isEstablished)
    #expect(try await store.baselines.baseline(mode: .quickTest) != nil)

    let stored = try #require(try await store.sessions.session(id: fifth.session.id))
    #expect(stored.score == nil)
    #expect(stored.metrics != nil)
}

@Test func aPreBaselineSessionStoresMetricsOnly() async throws {
    // "Reference only" [PRD §5].
    let store = try InMemoryStore()
    let result = try await store.commits.commit(validSession(0))

    let stored = try #require(try await store.sessions.session(id: result.session.id))
    #expect(stored.score == nil)
    #expect(stored.metrics != nil)
    #expect(result.state == .building(validCount: 1))
}

@Test func theSixthValidSessionPersistsACompleteScore() async throws {
    let store = try InMemoryStore()
    let baseline = try await establishBaseline(in: store)

    let sixth = validSession(5, ad1: 0.90)
    let partial = try partialScore(for: sixth, baseline: baseline)
    let result = try await store.commits.commit(sixth, partialScore: partial)

    #expect(result.baselineOutcome == .alreadyEstablished)

    let stored = try #require(try await store.sessions.session(id: sixth.id))
    let score = try #require(stored.score)

    #expect(score.relativeIndex == 112)
    #expect(score.algorithmVersion == baseline.algorithmVersion)
    #expect(score.breakdown.isEmpty == false)
    #expect(score.summaryLine.isEmpty == false)
    // Never a percentage claim [PRD].
    #expect(score.summaryLine.contains("%") == false)
}

@Test func aScoredSessionSurvivesTheStoreRoundTripIntact() async throws {
    let store = try InMemoryStore()
    let baseline = try await establishBaseline(in: store)

    let sixth = validSession(5, ad1: 0.90)
    try await store.commits.commit(sixth, partialScore: try partialScore(for: sixth, baseline: baseline))

    let stored = try #require(try await store.sessions.session(id: sixth.id))
    let score = try #require(stored.score)

    // The breakdown survives the JSON blob with its signals and absence
    // vocabulary intact (docs/05 §5.2).
    #expect(score.breakdown.contains { $0.signal == .gaitConsistency })
    let consistency = try #require(score.breakdown.first { $0.signal == .gaitConsistency })
    #expect(consistency.components.count == 2)
    #expect(consistency.components.allSatisfy { $0.availability == .standardized })
}

@Test func theRelativeIndexIsAScalarColumnForQueries() async throws {
    // docs/05 §5.2: History and the trend chart query it, so it is not buried
    // in the blob.
    let store = try InMemoryStore()
    let baseline = try await establishBaseline(in: store)

    let sixth = validSession(5, ad1: 0.90)
    try await store.commits.commit(sixth, partialScore: try partialScore(for: sixth, baseline: baseline, relativeIndex: 108))

    let rows = try ModelContext(store.container).fetch(FetchDescriptor<GaitSessionEntity>())
    let row = try #require(rows.first { $0.id == sixth.id })
    #expect(row.relativeIndex == 108)

    // Unscored sessions leave the column null.
    #expect(rows.filter { $0.relativeIndex != nil }.count == 1)
}

// MARK: - Invalid sessions (regression guard)

@Test func anInvalidCommitStoresNoScoreAndDoesNotAdvanceTheCount() async throws {
    let store = try InMemoryStore()
    let baseline = try await establishBaseline(in: store)

    let noisy = invalidSession(5)
    let result = try await store.commits.commit(noisy)

    #expect(result.validSessionCount == 5)
    let all = try await store.sessions.sessions(mode: .quickTest, includeInvalid: true, limit: nil)
    let stored = try #require(all.first { $0.id == noisy.id })
    #expect(stored.score == nil)
    #expect(stored.isValid == false)
    #expect(try await store.baselines.baseline(mode: .quickTest)?.id == baseline.id)
}

@Test func anInvalidSessionCannotBeScoredEvenDirectly() throws {
    // The only path that could attach a score after the fact refuses.
    #expect(invalidSession(0).scored(.fixture()) == nil)
    #expect(validSession(0).scored(.fixture()) != nil)
}

// MARK: - History used for the summary

@Test func theHistoryReadExcludesTheSessionBeingCommitted() async throws {
    let store = try InMemoryStore()
    for index in 0..<3 { try await store.commits.commit(validSession(index)) }
    let current = validSession(3)
    try await store.writer.save(current)

    let history = try await store.reader.recentValidSessions(
        mode: .quickTest, excluding: current.id, limit: 3
    )

    #expect(history.count == 3)
    #expect(history.contains { $0.id == current.id } == false)
}

@Test func theHistoryReadExcludesInvalidAndOtherModeSessions() async throws {
    let store = try InMemoryStore()
    try await store.commits.commit(validSession(0))
    try await store.commits.commit(invalidSession(1))
    try await store.commits.commit(validSession(2, mode: .fullTest))

    let history = try await store.reader.recentValidSessions(
        mode: .quickTest, excluding: UUID(), limit: 3
    )

    #expect(history.count == 1)
    #expect(history.allSatisfy { $0.mode == .quickTest && $0.isValid })
}

@Test func theSummaryIsGeneratedFromRealSameModeHistory() async throws {
    let store = try InMemoryStore()
    let baseline = try await establishBaseline(in: store)

    // The five calibration sessions all sat at 0.80; this one is markedly
    // steadier, so the summary has a true improvement to report.
    let sixth = validSession(5, ad1: 0.95)
    try await store.commits.commit(sixth, partialScore: try partialScore(for: sixth, baseline: baseline))

    let score = try #require(try await store.sessions.session(id: sixth.id)?.score)
    #expect(score.summaryLine.localizedCaseInsensitiveContains("Quick Test"))
    #expect(score.summaryLine.contains("%") == false)
}

@Test func theSummaryIsFrozenAtCommit() async throws {
    // It records what was true then; later history does not rewrite it, the
    // same reasoning that freezes the baseline [PRD §6].
    let store = try InMemoryStore()
    let baseline = try await establishBaseline(in: store)

    let sixth = validSession(5, ad1: 0.95)
    try await store.commits.commit(sixth, partialScore: try partialScore(for: sixth, baseline: baseline))
    let atCommit = try #require(try await store.sessions.session(id: sixth.id)?.score?.summaryLine)

    // More sessions arrive afterwards.
    for index in 6..<9 {
        let later = validSession(index, ad1: 0.99)
        try await store.commits.commit(later, partialScore: try partialScore(for: later, baseline: baseline))
    }

    let unchanged = try #require(try await store.sessions.session(id: sixth.id)?.score?.summaryLine)
    #expect(unchanged == atCommit)
}

// MARK: - Mode segregation, at the persisted level [PRD OQ-5]

@Test func aFullSessionWithOnlyAQuickBaselineIsStoredWithNoScore() async throws {
    let store = try InMemoryStore()
    _ = try await establishBaseline(in: store, mode: .quickTest)

    // A Full Test session. No Full baseline exists, so nothing can score it.
    let full = validSession(5, mode: .fullTest)
    let result = try await store.commits.commit(full)

    let stored = try #require(try await store.sessions.session(id: full.id))
    #expect(stored.score == nil)
    #expect(result.state == .building(validCount: 1))
    #expect(try await store.baselines.baseline(mode: .fullTest) == nil)
}

@Test func scoringOneModeLeavesTheOtherModesSessionsUnscored() async throws {
    let store = try InMemoryStore()
    let quickBaseline = try await establishBaseline(in: store, mode: .quickTest)

    let scoredQuick = validSession(5, ad1: 0.90)
    try await store.commits.commit(scoredQuick, partialScore: try partialScore(for: scoredQuick, baseline: quickBaseline))
    let unscoredFull = validSession(6, mode: .fullTest)
    try await store.commits.commit(unscoredFull)

    #expect(try await store.sessions.session(id: scoredQuick.id)?.score != nil)
    #expect(try await store.sessions.session(id: unscoredFull.id)?.score == nil)
}

// MARK: - Atomicity

@Test func aFailedCommitLeavesNoScoredSessionBehind() async throws {
    // Force the transaction to fail at the baseline step while carrying a
    // scored session. Both must roll back: a scored session stored without its
    // transaction completing would be a score for a state that never existed.
    let store = try InMemoryStore()
    let baseline = try await establishBaseline(in: store)

    let sixth = validSession(5, ad1: 0.90)
    let partial = try partialScore(for: sixth, baseline: baseline)
    let complete = SessionScore(completing: partial, summaryLine: "Test line.")
    let scored = try #require(sixth.scored(complete))

    let sessionsBefore = try await store.sessions.sessions(mode: .quickTest, includeInvalid: true, limit: nil)

    await #expect(throws: StoreWriter.WriteError.baselineAlreadyExists(mode: .quickTest)) {
        try await store.writer.commit(scored, establishing: .fixture(mode: .quickTest))
    }

    let sessionsAfter = try await store.sessions.sessions(mode: .quickTest, includeInvalid: true, limit: nil)
    let idsBefore: [String] = sessionsBefore.map(\.id.uuidString).sorted()
    let idsAfter: [String] = sessionsAfter.map(\.id.uuidString).sorted()
    #expect(idsAfter == idsBefore)
    #expect(sessionsAfter.contains { $0.id == sixth.id } == false)
    #expect(try await store.baselines.allBaselines().count == 1)
}

@Test func aScoredSessionAndABaselineCommitTogether() async throws {
    // The transaction carries both shapes, even though the flow never produces
    // them at once — the writer must not care.
    let store = try InMemoryStore()
    let session = validSession(0, mode: .fullTest)
    let baseline = Baseline.fixture(mode: .fullTest)
    let scored = try #require(session.scored(.fixture(relativeIndex: 105)))

    try await store.writer.commit(scored, establishing: baseline)

    #expect(try await store.sessions.session(id: session.id)?.score?.relativeIndex == 105)
    #expect(try await store.baselines.baseline(mode: .fullTest)?.id == baseline.id)
}
