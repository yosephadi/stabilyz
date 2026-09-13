import Foundation
import SwiftUI
import Testing
@testable import Stabilyz

/// The completion gate and the Score screen (Task 8.2.5, docs/11 §11.3,
/// [PRD §5, §7]).

// MARK: - Helpers

private func commit(
    session: GaitSession,
    validCount: Int = 6,
    outcome: BaselineCommitOutcome = .alreadyEstablished,
    state: BaselineState = .established(.fixture())
) -> SessionCommitResult {
    SessionCommitResult(
        session: session,
        validSessionCount: validCount,
        baselineOutcome: outcome,
        state: state
    )
}

/// A committed session in the calibration window: no baseline, no score.
private func building(
    count: Int,
    mode: TestMode = .quickTest,
    outcome: BaselineCommitOutcome? = nil,
    session: GaitSession? = nil
) -> SessionCommitResult {
    commit(
        session: session ?? .fixtureValid(mode: mode),
        validCount: count,
        outcome: outcome ?? .notReady(validCount: count),
        state: .building(validCount: count)
    )
}

private func presentation(_ result: SessionCommitResult) -> SessionScorePresentation {
    SessionScorePresentation(result: result, baselineIndex: 100)
}

private func component(
    _ metric: MetricID,
    z: Double?,
    raw: Double? = 1,
    availability: MetricAvailability = .standardized
) -> MetricBreakdownComponent {
    MetricBreakdownComponent(
        metricID: metric,
        availability: availability,
        rawValue: raw,
        baselineMean: 1,
        baselineSD: 0.1,
        directionAdjustedZ: z
    )
}

// MARK: - Outcome routing [PRD §5]

@Test func aValidSessionOffersItsResult() {
    let content = SessionCompletionContent.content(for: commit(session: .fixtureValid()))

    #expect(content == .measured(mode: .quickTest))
    #expect(content.offersResult)
    #expect(content.title == "Quick Test Completed")
    #expect(content.glyph == "checkmark.circle.fill")
}

@Test func anInvalidSessionOffersOnlyTheWayBack() {
    // Never scored, never shown a result. The gate is where that becomes
    // visible to the user rather than merely true in the store.
    let content = SessionCompletionContent.content(for: commit(
        session: .fixtureInvalid(reason: .excessiveNoise),
        validCount: 0,
        outcome: .notReady(validCount: 0),
        state: .notStarted
    ))

    #expect(content == .unclear(mode: .quickTest))
    #expect(content.offersResult == false)
    #expect(content.title == SessionCompletionContent.unclearTitle)
    #expect(content.glyph == "exclamationmark.circle.fill")
}

@Test func theUnclearScreenSaysTheSessionDoesNotCount() {
    // [PRD §5]: the user is told the consequence, not left to infer it from a
    // missing number.
    let body = SessionCompletionContent.unclear(mode: .quickTest).body
    #expect(body.localizedCaseInsensitiveContains("won't count toward your baseline"))
}

@Test func everyInvalidReasonRoutesToTheSameUnclearScreen() {
    // One plain-language screen, not four. The reason is diagnostics
    // (docs/20), not copy.
    for reason in InvalidReason.allCases {
        let content = SessionCompletionContent.content(for: commit(
            session: .fixtureInvalid(reason: reason),
            validCount: 0,
            outcome: .notReady(validCount: 0),
            state: .notStarted
        ))
        #expect(content.offersResult == false, "\(reason) must not offer a result")
    }
}

@Test func theGateNamesTheModeThatWasWalked() {
    let full = SessionCompletionContent.content(for: commit(session: .fixtureValid(mode: .fullTest)))
    #expect(full.title == "Full Test Completed")
}

// MARK: - The score, when there is one [PRD §7]

@Test func aStoredScoreIsShownAgainstTheBaseline() {
    let session = GaitSession.fixtureValid(score: .fixture(relativeIndex: 112))
    let model = presentation(commit(session: session))

    #expect(model.progress == .scored(index: 112, delta: 12))
    #expect(model.highlight == "This Quick Test was about usual for you.")
}

@Test func aScoreBelowTheBaselineCarriesANegativeDelta() {
    let session = GaitSession.fixtureValid(score: .fixture(relativeIndex: 93))
    #expect(presentation(commit(session: session)).progress == .scored(index: 93, delta: -7))
}

@Test func aBaselineScoreCarriesNoDelta() {
    let session = GaitSession.fixtureValid(score: .fixture(relativeIndex: 100))
    #expect(presentation(commit(session: session)).progress == .scored(index: 100, delta: 0))
}

// MARK: - The score, when there is not [PRD §7, docs/09 §9.5]

@Test func calibrationSessionsShowProgressAndNoScore() {
    // Sessions 1-5 have no index by design: the fifth establishes the baseline
    // and carries no score itself.
    for count in 1...4 {
        let model = presentation(building(count: count))
        #expect(model.progress == .building(validCount: count, required: 5))
        #expect(model.highlight == nil)
        #expect(model.signals.isEmpty)
    }
}

@Test func theSessionThatEstablishesTheBaselineSaysSo() {
    let model = presentation(building(
        count: 5,
        outcome: .established(.fixture())
    ))

    #expect(model.progress == .building(validCount: 5, required: 5))
    #expect(model.note?.contains("Quick Test baseline is ready") == true)
}

@Test func aRefusedBaselineIsSaidPlainlyRatherThanLeftOnFiveOfFive() {
    // The walk is kept and calibration is not restarted
    // (docs/decisions.md entry 17) — but a screen that only said "Session 5 of
    // 5" forever would never explain why.
    let model = presentation(building(
        count: 5,
        outcome: .refused(reason: .mixedAlgorithmVersions, validCount: 5)
    ))

    #expect(model.progress == .building(validCount: 5, required: 5))
    #expect(model.note != nil)
}

@Test func aValidSessionWithABaselineButNoScoreIsNotShownAsCalibration() {
    // A sixth session whose summary could not be generated has a baseline and
    // no score. "Session 6 of 5" would be nonsense.
    let model = presentation(commit(session: .fixtureValid(score: nil), validCount: 6))
    #expect(model.progress == .notComparable)
    #expect(model.highlight == nil)
}

@Test func theCalibrationCountNeverExceedsTheRequirement() {
    let model = presentation(building(count: 9))
    #expect(model.progress == .building(validCount: 5, required: 5))
}

// MARK: - The building state shows progress, not an absence

@Test func aCalibrationSessionSaysHowManyWalksAreLeft() {
    #expect(
        SessionScorePresentation.calibrationSubtitle(validCount: 1, required: 5)
            == "Baseline in progress. 4 more walks needed to unlock your Stability Score."
    )
}

@Test func theLastWalkBeforeTheBaselineIsSingular() {
    // "1 more walks" on the screen a user sees four times out of five.
    #expect(
        SessionScorePresentation.calibrationSubtitle(validCount: 4, required: 5)
            == "Baseline in progress. 1 more walk needed to unlock your Stability Score."
    )
}

@Test func aCompleteCalibrationStopsAskingForWalks() {
    let line = SessionScorePresentation.calibrationSubtitle(validCount: 5, required: 5)
    #expect(line.contains("more walk") == false)
    #expect(line.contains("0 ") == false)
}

@Test func everyCalibrationSessionCarriesItsSubtitle() {
    for count in 1...4 {
        let model = presentation(building(count: count))
        #expect(model.subtitle == SessionScorePresentation.calibrationSubtitle(
            validCount: count, required: 5
        ))
    }
}

@Test func theSubtitleStandsDownWhenTheNoteIsSayingTheSameThing() {
    // The session that establishes the baseline would otherwise announce it
    // twice, once under the ring and once beneath.
    let model = presentation(building(count: 5, outcome: .established(.fixture())))
    #expect(model.note != nil)
    #expect(model.subtitle == nil)
}

@Test func aScoredSessionHasNoCalibrationSubtitle() {
    let model = presentation(commit(session: .fixtureValid(score: .fixture())))
    #expect(model.subtitle == nil)
}

// MARK: - Raw measurements on the pre-baseline screen [docs/04 §4.9]

@Test func aCalibrationSessionShowsWhatItMeasured() {
    // Without these the screen reads as one where nothing happened. They are
    // the evidence the walk was recorded and analysed.
    let metrics = GaitMetrics.fixture(
        cadenceMean: 108.6,
        stepTimeCV: 0.043,
        stepTimeAsymmetry: 0.061
    )
    let model = presentation(building(
        count: 2,
        session: .fixtureValid(metrics: metrics)
    ))

    #expect(model.measurements.map(\.signal) == [.cadence, .stepTimeVariability, .stepTimeAsymmetry])
    #expect(model.measurements.map(\.detail) == ["109 steps/min", "4%", "6%"])
}

@Test func noRawMeasurementClaimsADirection() {
    // There is no baseline to be above or below, and two of the three carry no
    // sign convention even when there is.
    let model = presentation(building(count: 3))
    #expect(model.measurements.isEmpty == false)
    #expect(model.measurements.allSatisfy { $0.direction == nil })
}

@Test func anAbsentAsymmetryDrawsNoRowRatherThanAnEmptyOne() {
    // Nil is the correct value for a bilateral user [PRD §7, OQ-1]; a
    // permanently empty row on a secondary metric is noise, not transparency.
    let metrics = GaitMetrics.fixture(stepTimeAsymmetry: nil)
    let model = presentation(building(count: 1, session: .fixtureValid(metrics: metrics)))

    #expect(model.measurements.map(\.signal) == [.cadence, .stepTimeVariability])
}

@Test func aScoredSessionShowsItsBreakdownRatherThanRawNumbers() {
    // The breakdown already carries every measurement, in context.
    let model = presentation(commit(session: .fixtureValid(score: .fixture())))
    #expect(model.measurements.isEmpty)
}

@Test func aMeasuredWalkWithNoScoreStillShowsItsNumbers() {
    let model = presentation(commit(session: .fixtureValid(score: nil), validCount: 6))
    #expect(model.progress == .notComparable)
    #expect(model.measurements.isEmpty == false)
}

@Test func theRawMeasurementsAreFramedAsReferenceOnly() {
    // Three bare numbers would invite exactly the comparison the screen cannot
    // yet make.
    #expect(SessionScorePresentation.measurementsCaption
        .localizedCaseInsensitiveContains("reference only"))
}

// MARK: - Signals: never better or worse without a direction

@Test func agreeingMetricsGiveTheSignalADirection() {
    let rows = SessionScorePresentation.rows(from: [
        MetricBreakdown(
            signal: .gaitConsistency,
            components: [component(.stepRegularity, z: 0.8), component(.strideRegularity, z: 0.4)],
            asymmetrySide: nil
        )
    ])

    #expect(rows.count == 1)
    #expect(rows[0].direction == .better)
    #expect(rows[0].detail == "Above your usual")
}

@Test func metricsBelowBaselineReadAsBelow() {
    let rows = SessionScorePresentation.rows(from: [
        MetricBreakdown(
            signal: .trunkMotion,
            components: [component(.trunkMotionML, z: -0.5), component(.trunkMotionVT, z: -1.2)],
            asymmetrySide: nil
        )
    ])

    #expect(rows[0].direction == .worse)
    #expect(rows[0].detail == "Below your usual")
}

@Test func disagreeingMetricsClaimNoDirection() {
    // Combining them would need a weighting, which is the `[OPEN]` composite
    // formula (docs/08 §8.2). Agreement is the rule instead.
    let rows = SessionScorePresentation.rows(from: [
        MetricBreakdown(
            signal: .gaitConsistency,
            components: [component(.stepRegularity, z: 0.9), component(.strideRegularity, z: -0.9)],
            asymmetrySide: nil
        )
    ])

    #expect(rows[0].direction == nil)
    #expect(rows[0].detail == "In your usual range")
}

@Test func cadenceIsShownAsAMeasurementNeverAsProgress() {
    // Cadence carries no decided sign convention (docs/decisions.md entry 3),
    // so it may never be rendered as better or worse.
    let rows = SessionScorePresentation.rows(from: [
        MetricBreakdown(
            signal: .cadence,
            components: [component(.cadenceMean, z: nil, raw: 112.4)],
            asymmetrySide: nil
        )
    ])

    #expect(rows[0].direction == nil)
    #expect(rows[0].detail == "112 steps/min")
}

@Test func asymmetryIsShownAsAMeasurementNeverAsProgress() {
    let rows = SessionScorePresentation.rows(from: [
        MetricBreakdown(
            signal: .stepTimeAsymmetry,
            components: [component(.stepTimeAsymmetry, z: nil, raw: 0.043)],
            asymmetrySide: .left
        )
    ])

    #expect(rows[0].direction == nil)
    #expect(rows[0].detail == "4%")
}

@Test func stepTimeVariabilityReadsAsAPercentageNotARatio() {
    // "4%" is read by more people than "0.04".
    let rows = SessionScorePresentation.rows(from: [
        MetricBreakdown(
            signal: .stepTimeVariability,
            components: [component(.stepTimeCV, z: nil, raw: 0.038, availability: .rawOnly)],
            asymmetrySide: nil
        )
    ])

    #expect(rows[0].detail == "4%")
}

@Test func anUnmeasuredSignalSaysSoRatherThanShowingNothing() {
    let rows = SessionScorePresentation.rows(from: [
        MetricBreakdown(
            signal: .stepTimeVariability,
            components: [component(.stepTimeCV, z: nil, raw: nil, availability: .unmeasured)],
            asymmetrySide: nil
        )
    ])

    #expect(rows[0].detail == "Not measured")
    #expect(rows[0].direction == nil)
}

@Test func anEmptySignalDrawsNoRow() {
    let rows = SessionScorePresentation.rows(from: [
        MetricBreakdown(signal: .cadence, components: [], asymmetrySide: nil)
    ])
    #expect(rows.isEmpty)
}

// MARK: - Signal copy [PRD OQ-1]

@Test func noSignalLabelCallsTheAutocorrelationOutputSymmetry() {
    // The reserved term belongs to the unilateral step-time comparison only.
    for signal in SignalID.allCases where signal != .stepTimeAsymmetry {
        #expect(
            SessionScorePresentation.label(for: signal)
                .localizedCaseInsensitiveContains("symmetr") == false,
            "\(signal.rawValue) must not use the reserved term"
        )
    }
    #expect(SessionScorePresentation.label(for: .gaitConsistency) == "Gait consistency")
}

@Test func theAsymmetryLabelDoesNotClaimALeftRightComparison() {
    // The metric says how unequal two consecutive half-cycles were, never
    // which limb is which (docs/decisions.md entry 13) — so the node's
    // "Left-right balance" would name a comparison the app cannot make.
    let label = SessionScorePresentation.label(for: .stepTimeAsymmetry)
    #expect(label.localizedCaseInsensitiveContains("left") == false)
    #expect(label.localizedCaseInsensitiveContains("right") == false)
}

@Test func everySignalHasALabel() {
    for signal in SignalID.allCases {
        #expect(SessionScorePresentation.label(for: signal).isEmpty == false)
    }
}

// MARK: - The cue line

@Test func aWalkWithNoCueDrawsNoCueLine() {
    #expect(presentation(commit(session: .fixtureValid(audioConfig: .none))).cue == nil)
}

@Test func theCueLineNamesWhatTheWalkRanWith() {
    let step = presentation(commit(session: .fixtureValid(audioConfig: .stepFeedback)))
    #expect(step.cue?.text == "Step Feedback was on")

    let metronome = presentation(commit(
        session: .fixtureValid(audioConfig: .metronome(cue: .fixture()))
    ))
    #expect(metronome.cue?.text == "Metronome Cue was on")
    #expect(metronome.cue?.glyph == "metronome.fill")
}

@Test func aSilencedCueSaysWhereTheSoundStopped() {
    // The session keeps the config it started with; this is what says the rest
    // of the walk was silent.
    let session = GaitSession.valid(
        id: UUID(),
        mode: .quickTest,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_000_120),
        advertisedClockElapsed: .seconds(120),
        validWalkingDuration: .seconds(95),
        metrics: .fixture(),
        audioConfig: .stepFeedback,
        audioSilencedAt: .seconds(75),
        algorithmVersion: "1.0.0",
        appVersion: "1.0",
        deviceModel: "iPhone17,1"
    )

    #expect(presentation(commit(session: session)).cue?.text == "Step Feedback was on until 01:15")
}

// MARK: - The header

@Test func theHeaderWordsTheDayRelatively() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(SessionScorePresentation.completedText(now, now: now).hasPrefix("Completed today at "))

    let yesterday = now.addingTimeInterval(-86_400)
    #expect(
        SessionScorePresentation.completedText(yesterday, now: now)
            .hasPrefix("Completed yesterday at ")
    )

    let lastWeek = now.addingTimeInterval(-7 * 86_400)
    let older = SessionScorePresentation.completedText(lastWeek, now: now)
    #expect(older.hasPrefix("Completed "))
    #expect(older.contains("today") == false)
    #expect(older.contains("yesterday") == false)
}

// MARK: - Score colour (§2.4, §9)

@Test func theScoreScaleBandsTheIndexWithoutAHueChange() {
    #expect(StabilyzColor.score(120) == StabilyzColor.scoreStrong)
    #expect(StabilyzColor.score(115) == StabilyzColor.scoreStrong)
    #expect(StabilyzColor.score(108) == StabilyzColor.scoreGood)
    #expect(StabilyzColor.score(100) == StabilyzColor.scoreNeutral)
    #expect(StabilyzColor.score(90) == StabilyzColor.scoreSoft)
    #expect(StabilyzColor.score(40) == StabilyzColor.scoreLow)
}

@Test func theScoreNumeralIsAlwaysLegibleAgainstTheScreen() {
    // §2.4 already makes this exception for `score-low`; `score-soft` fails the
    // same contrast check and takes the same substitution. Everything at or
    // above the neutral band clears §9's 3:1 floor for large text on its own.
    for index in [40, 84, 90, 94] {
        #expect(StabilyzColor.scoreNumeral(index) == StabilyzColor.ink900, "\(index)")
    }
    #expect(StabilyzColor.scoreNumeral(95) == StabilyzColor.scoreNeutral)
    #expect(StabilyzColor.scoreNumeral(108) == StabilyzColor.scoreGood)
}

// MARK: - Layout contract (§3, §4)

@Test func bothScreensUseTheHeroCapsuleHeight() {
    // Single-decision screens: 55pt, not 50.
    #expect(Controls.heroButtonHeight == 55)
    let hero: [CapsuleButtonStyle] = [.primaryCapsuleHero, .secondaryCapsuleHero]
    for style in hero {
        #expect(style.height == Controls.heroButtonHeight)
    }
}

@Test func theScoreRingMatchesTheNodesBand() {
    // Node 150:3235: an annulus from radius 90 to 100 with a 4pt stroke on both
    // edges — a 14pt band inside a 204pt box.
    #expect(Controls.scoreRingDiameter == 204)
    #expect(Controls.scoreRingWidth == 14)
}
