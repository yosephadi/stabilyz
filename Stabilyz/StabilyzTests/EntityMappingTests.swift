import Foundation
import SwiftData
import Testing
@testable import Stabilyz

// MARK: - Schema

@Test func schemaVersionIsStamped() throws {
    #expect(StoreContainer.schemaVersion == Schema.Version(1, 0, 0))
    #expect(StabilyzSchemaV1.models.count == 3)
}

@Test func inMemoryContainerBuilds() throws {
    _ = try StoreContainer.make(inMemory: true)
}

// MARK: - Session round trip

@Test func validSessionRoundTripsThroughTheEntity() throws {
    let session = GaitSession.fixtureValid(
        mode: .fullTest,
        score: SessionScore.fixture(relativeIndex: 112),
        audioConfig: .metronome(cue: .fixture(bpm: 104)),
        interruptionCount: 1,
        gapInfo: SessionGapInfo(gapCount: 1, totalGapDuration: .seconds(4), longestGapDuration: .seconds(4))
    )

    let entity = try EntityMapping.entity(from: session)
    let restored = try EntityMapping.session(from: entity)

    #expect(restored == session)
}

@Test func invalidSessionRoundTripsAndStaysUnscored() throws {
    for reason in InvalidReason.allCases {
        let session = GaitSession.fixtureInvalid(reason: reason)
        let restored = try EntityMapping.session(from: try EntityMapping.entity(from: session))

        #expect(restored == session)
        #expect(restored.metrics == nil)
        #expect(restored.score == nil)
    }
}

@Test func queriedFieldsAreScalarColumnsNotBlobFields() throws {
    // CLAUDE.md: scalar columns only for id, mode, startedAt, validity,
    // relativeIndex, algorithmVersion. Everything else rides in the blob.
    let session = GaitSession.fixtureValid(mode: .fullTest, score: SessionScore.fixture(relativeIndex: 112))
    let entity = try EntityMapping.entity(from: session)

    #expect(entity.id == session.id)
    #expect(entity.mode == "fullTest")
    #expect(entity.startedAt == session.startedAt)
    #expect(entity.validity == "valid")
    #expect(entity.relativeIndex == 112)
    #expect(entity.algorithmVersion == "1.0.0")
}

@Test func validityColumnCarriesTheInvalidReasonForFiltering() throws {
    let entity = try EntityMapping.entity(from: .fixtureInvalid(reason: .excessiveNoise))

    #expect(entity.validity == "excessiveNoise")
    #expect(entity.relativeIndex == nil)
    #expect(SessionValidity.outcome(from: entity.validity) == .invalid(reason: .excessiveNoise))
}

// MARK: - Mapping failures surface rather than corrupt

@Test func unknownRawValuesAreRejected() throws {
    let entity = try EntityMapping.entity(from: .fixtureValid())

    entity.mode = "sprintTest"
    #expect(throws: EntityMapping.MappingError.unknownTestMode("sprintTest")) {
        try EntityMapping.session(from: entity)
    }

    entity.mode = "quickTest"
    entity.validity = "somethingElse"
    #expect(throws: EntityMapping.MappingError.unknownValidity("somethingElse")) {
        try EntityMapping.session(from: entity)
    }
}

@Test func aCorruptBlobIsReportedRatherThanSilentlyEmptied() throws {
    let entity = try EntityMapping.entity(from: .fixtureValid())
    entity.payload = Data("not json".utf8)

    #expect(throws: EntityMapping.MappingError.corruptPayload) {
        try EntityMapping.session(from: entity)
    }
}

@Test func aValidRowWithoutMetricsIsRejected() throws {
    // Would otherwise produce a "valid" session with nothing measured.
    let invalid = try EntityMapping.entity(from: .fixtureInvalid())
    invalid.validity = "valid"

    #expect(throws: EntityMapping.MappingError.outcomeMetricsMismatch) {
        try EntityMapping.session(from: invalid)
    }
}

@Test func anInvalidRowCarryingAScoreIsRejected() throws {
    // The store must not be able to smuggle a score onto a noisy session.
    let entity = try EntityMapping.entity(from: .fixtureValid(score: SessionScore.fixture(relativeIndex: 112)))
    entity.validity = "excessiveNoise"

    #expect(throws: EntityMapping.MappingError.outcomeMetricsMismatch) {
        try EntityMapping.session(from: entity)
    }
}

// MARK: - Baseline and profile round trips

@Test func baselineRoundTripsAndRevalidatesItsInvariant() throws {
    let baseline = Baseline.fixture(mode: .fullTest)
    let entity = try EntityMapping.entity(from: baseline)

    #expect(entity.mode == "fullTest")
    #expect(try EntityMapping.baseline(from: entity) == baseline)

    // A row with the wrong number of source sessions cannot become a Baseline.
    entity.payload = try JSONEncoder().encode(
        BaselinePayload(stats: baseline.stats, sourceSessionIDs: [UUID(), UUID()])
    )
    #expect(throws: Baseline.ValidationError.wrongSourceSessionCount(expected: 5, actual: 2)) {
        try EntityMapping.baseline(from: entity)
    }
}

@Test func profileRoundTripsAndRevalidatesLevelSideConsistency() throws {
    let profile = UserProfile.fixture(level: .bilateral, side: .both)
    let entity = EntityMapping.entity(from: profile)

    #expect(try EntityMapping.profile(from: entity) == profile)

    // A store row that violates the PRD consistency rule is rejected, not loaded.
    entity.side = "left"
    #expect(throws: UserProfile.ValidationError.bilateralRequiresBothSides(actual: .left)) {
        try EntityMapping.profile(from: entity)
    }
}

@Test func optionalProfileFieldsSurviveAsNil() throws {
    let profile = UserProfile.fixture(kLevel: nil, prosthesisType: nil)
    let restored = try EntityMapping.profile(from: EntityMapping.entity(from: profile))

    #expect(restored.kLevel == nil)
    #expect(restored.prosthesisType == nil)
}
