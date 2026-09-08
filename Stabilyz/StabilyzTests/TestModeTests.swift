import Testing
@testable import Stabilyz

// MARK: - TestMode

@Test func advertisedDurationsMatchTheTwoClinicalWalkTests() {
    // [PRD §5] 2-minute Quick Test, 6-minute Full Test.
    #expect(TestMode.quickTest.advertisedDuration == .seconds(120))
    #expect(TestMode.fullTest.advertisedDuration == .seconds(360))
}

@Test func displayNamesMatchThePRDCopy() {
    #expect(TestMode.quickTest.displayName == "Quick Test")
    #expect(TestMode.fullTest.displayName == "Full Test")
}

@Test func rawValuesAreStableForPersistence() {
    // These are persisted on session and baseline rows (docs/05 §5.2).
    // Changing them silently orphans stored data.
    #expect(TestMode.quickTest.rawValue == "quickTest")
    #expect(TestMode.fullTest.rawValue == "fullTest")
    #expect(TestMode(rawValue: "quickTest") == .quickTest)
    #expect(TestMode.allCases.count == 2)
}

// MARK: - SessionPolicy

@Test func v1MinimumsAreNinetySecondsAndFourMinutes() {
    // [PRD OQ-3] ~90 seconds Quick Test, ~4 minutes Full Test.
    #expect(SessionPolicy.v1.minimumValidWalkingDuration(for: .quickTest) == .seconds(90))
    #expect(SessionPolicy.v1.minimumValidWalkingDuration(for: .fullTest) == .seconds(240))
    #expect(SessionPolicy.v1.version == 1)
}

@Test func validWalkingMinimumIsShorterThanTheAdvertisedLength() {
    // [PRD OQ-3] draws an explicit distinction between the clock length and the
    // valid-walking requirement. Collapsing the two would let a session that
    // ran the full clock but spent it standing still produce a score.
    for mode in TestMode.allCases {
        #expect(SessionPolicy.v1.minimumValidWalkingDuration(for: mode) < mode.advertisedDuration)
    }
}

@Test func policyIsTunableWithoutTouchingTestMode() {
    // The thresholds are provisional and will be tuned against real sessions
    // (docs/22 Phase 12), so a new policy version must not require a model change.
    let tuned = SessionPolicy(
        version: 2,
        quickTestMinimumValidWalking: .seconds(100),
        fullTestMinimumValidWalking: .seconds(250)
    )

    #expect(tuned.minimumValidWalkingDuration(for: .quickTest) == .seconds(100))
    #expect(tuned != SessionPolicy.v1)
    #expect(TestMode.quickTest.advertisedDuration == .seconds(120))
}
