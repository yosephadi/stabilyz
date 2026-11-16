import Testing
@testable import Stabilyz

// MARK: - TestMode

@Test func advertisedDurationsMatchTheTwoClinicalWalkTests() {
    // [PRD §5, OQ-3] provisional 90 s Quick Test, 180 s Full Test.
    #expect(TestMode.quickTest.advertisedDuration == .seconds(90))
    #expect(TestMode.fullTest.advertisedDuration == .seconds(180))
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

@Test func v1MinimumsAreOneMinuteAndTwoFifteen() {
    // [PRD OQ-3] provisional: 60 s Quick Test, 135 s (2:15) Full Test.
    #expect(SessionPolicy.v1.minimumValidWalkingDuration(for: .quickTest) == .seconds(60))
    #expect(SessionPolicy.v1.minimumValidWalkingDuration(for: .fullTest) == .seconds(135))
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
        quickTestMinimumValidWalking: .seconds(70),
        fullTestMinimumValidWalking: .seconds(150)
    )

    #expect(tuned.minimumValidWalkingDuration(for: .quickTest) == .seconds(70))
    #expect(tuned != SessionPolicy.v1)
    #expect(TestMode.quickTest.advertisedDuration == .seconds(90))
}
