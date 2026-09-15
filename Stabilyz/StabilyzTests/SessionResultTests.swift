import Foundation
import SwiftUI
import Testing
@testable import Stabilyz

/// The completion gate and the Score screen (Task 8.2.5, docs/11 §11.3,
/// [PRD §5, §7]).

// MARK: - Helpers

/// WCAG relative luminance and contrast, for §9's stated checks. A local copy:
/// `DesignSystemTests` keeps its own private one, and sharing it would make one
/// suite's helpers another suite's dependency.
private func luminance(_ color: Color, dark: Bool) -> Double {
    let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
    let resolved = UIColor(color).resolvedColor(with: traits)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
    func channel(_ value: CGFloat) -> Double {
        let v = Double(value)
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
}

private func contrastRatio(_ a: Color, _ b: Color, dark: Bool) -> Double {
    let la = luminance(a, dark: dark)
    let lb = luminance(b, dark: dark)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

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
    session: GaitSession? = nil,
    provisional: ProvisionalStabilityScore? = .fixture()
) -> SessionCommitResult {
    commit(
        session: session ?? .fixtureValid(mode: mode, provisionalScore: provisional),
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
        let model = presentation(building(count: count, provisional: nil))
        #expect(model.progress == .building(validCount: count, required: 5, provisional: nil))
        #expect(model.highlight == nil)
        #expect(model.signals.isEmpty)
    }
}

@Test func theSessionThatEstablishesTheBaselineSaysSo() {
    let model = presentation(building(
        count: 5,
        outcome: .established(.fixture())
    ))

    #expect(model.progress == .building(validCount: 5, required: 5, provisional: 76))
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

    #expect(model.progress == .building(validCount: 5, required: 5, provisional: 76))
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
    #expect(model.progress == .building(validCount: 5, required: 5, provisional: 76))
}

// MARK: - The building state shows progress, not an absence

@Test func theProgressHeaderCountsSessionsDone() {
    let progress = SessionScorePresentation.baselineProgress(
        completed: 1, required: 5, mode: .quickTest
    )
    #expect(progress?.header == "1 of 5 sessions complete")
    #expect(progress?.completed == 1)
    #expect(progress?.required == 5)
}

@Test func theHelperCopySpellsTheRemainingWalksAndNamesTheMode() {
    #expect(
        SessionScorePresentation.baselineProgress(completed: 1, required: 5, mode: .quickTest)?.helper
            == "Complete four more valid Quick Tests to set your personal baseline."
    )
    #expect(
        SessionScorePresentation.baselineProgress(completed: 2, required: 5, mode: .fullTest)?.helper
            == "Complete three more valid Full Tests to set your personal baseline."
    )
}

@Test func theLastRemainingWalkIsSingular() {
    // "one more valid Quick Tests" on the screen a user sees four times in five.
    #expect(
        SessionScorePresentation.baselineProgress(completed: 4, required: 5, mode: .quickTest)?.helper
            == "Complete one more valid Quick Test to set your personal baseline."
    )
}

@Test func aCompleteCalibrationDrawsNoProgressBlock() {
    // "Complete zero more walks" is not a sentence.
    #expect(SessionScorePresentation.baselineProgress(completed: 5, required: 5, mode: .quickTest) == nil)
}

@Test func theDotsAreDrawnFromTheCountsNotFromTheCopy() {
    // The view fills dot `i` when `i < completed`, so these two numbers are the
    // whole indicator. A block that carried only a sentence would leave the
    // view parsing it.
    for count in 1...4 {
        let model = presentation(building(count: count))
        let progress = model.baselineProgress
        #expect(progress?.completed == count)
        #expect(progress?.required == 5)
        #expect(progress?.remaining == 5 - count)
    }
}

@Test func everyCalibrationSessionCarriesItsProgressBlock() {
    for count in 1...4 {
        let model = presentation(building(count: count))
        #expect(model.baselineProgress == SessionScorePresentation.baselineProgress(
            completed: count, required: 5, mode: .quickTest
        ))
    }
}

@Test func theProgressBlockStandsDownWhenTheNoteIsSayingTheSameThing() {
    // The session that establishes the baseline would otherwise announce it
    // twice, once under the ring and once beneath.
    let model = presentation(building(count: 5, outcome: .established(.fixture())))
    #expect(model.note != nil)
    #expect(model.baselineProgress == nil)
}

@Test func aScoredSessionHasNoProgressBlock() {
    let model = presentation(commit(session: .fixtureValid(score: .fixture())))
    #expect(model.baselineProgress == nil)
}

// MARK: - Raw measurements on the pre-baseline screen [docs/04 §4.9]

@Test func sessionsOneThroughFiveCarryAProvisionalScore() {
    // The point of the whole pre-baseline scale: a number from the very first
    // walk, on its own placeholder scale, never a relative index.
    for count in 1...5 {
        let model = presentation(building(count: count, provisional: .fixture(value: 71)))
        #expect(model.progress == .building(validCount: count, required: 5, provisional: 71))
    }
}

@Test func aProvisionalScoreIsNeverPresentedAsAComparison() {
    // "vs. baseline" belongs to the relative index and begins at the sixth
    // valid session [PRD §7]. A delta here would put two scales on one axis.
    let model = presentation(building(count: 2))
    guard case .scored = model.progress else { return }
    Issue.record("a calibration session must never reach the scored case")
}

@Test func aCalibrationSessionExplainsItsScoreFromTheSignalsBehindIt() {
    // [PRD] requires a summary generated from real measurement, not a static
    // string. Pre-baseline that means the walk's own signals, since there is
    // nothing to compare against yet.
    let model = presentation(building(
        count: 1,
        provisional: .fixture(gaitConsistency: 0.9, stepTimeVariability: 0.5, trunkMotion: 0.7)
    ))

    guard let highlight = model.highlight else {
        Issue.record("a pre-baseline walk with measured signals produced no highlight")
        return
    }
    #expect(highlight.contains("gait consistency"))
    #expect(highlight.contains("step rhythm"))
}

@Test func aCalibrationSessionWithNoProvisionalScoreHasNoHighlight() {
    // A sentence naming signals the score was not built from would be exactly
    // the static string [PRD] rules out.
    #expect(presentation(building(count: 1, provisional: nil)).highlight == nil)
}

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
        session: .fixtureValid(metrics: metrics, provisionalScore: .fixture())
    ))

    #expect(model.measurements.map(\.signal) == [.cadence, .stepTimeVariability, .stepTimeAsymmetry])
    #expect(model.measurements.map(\.detail) == ["109 steps/min", "4%", "6%"])
}

@Test func aMeasuredZeroAsymmetryIsShownAsZeroNotAsUndetected() {
    // "A measured zero means the step durations really were equal" — that is a
    // result, and collapsing it into "Not detected" would lose it.
    let model = presentation(building(
        count: 1,
        session: .fixtureValid(
            metrics: .fixture(stepTimeAsymmetry: 0),
            provisionalScore: .fixture()
        )
    ))
    #expect(model.measurements.last?.detail == "0%")
}

@Test func noRawMeasurementClaimsADirection() {
    // There is no baseline to be above or below, and two of the three carry no
    // sign convention even when there is.
    let model = presentation(building(count: 3))
    #expect(model.measurements.isEmpty == false)
    #expect(model.measurements.allSatisfy { $0.direction == nil })
}

@Test func anAbsentAsymmetryStillDrawsItsRow() {
    // Nil is a real result — a bilateral user, no profile, peaks not prominent
    // [PRD §7, OQ-1]. The row stays so the section keeps its shape from one
    // walk to the next; what it must never show is a zero, which would claim a
    // measured equality.
    let metrics = GaitMetrics.fixture(stepTimeAsymmetry: nil)
    let model = presentation(building(
        count: 1,
        session: .fixtureValid(metrics: metrics, provisionalScore: .fixture())
    ))

    #expect(model.measurements.map(\.signal) == [.cadence, .stepTimeVariability, .stepTimeAsymmetry])
    #expect(model.measurements.last?.detail == SessionScorePresentation.undetectedMeasurement)
    #expect(model.measurements.last?.detail.contains("0") == false)
}

@Test func theMeasuredSectionIsAlwaysTheSameThreeRows() {
    // Whatever the walk produced, the section has one shape.
    for asymmetry in [nil, 0.0, 0.061] as [Double?] {
        let model = presentation(building(
            count: 3,
            session: .fixtureValid(
                metrics: .fixture(stepTimeAsymmetry: asymmetry),
                provisionalScore: .fixture()
            )
        ))
        #expect(model.measurements.map(\.signal) == [
            .cadence, .stepTimeVariability, .stepTimeAsymmetry
        ])
    }
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

// MARK: - The ring encodes the score, not the session count

@Test func theRingFillIsTheScoreOverOneHundred() {
    // 41 fills 41% of the circumference. The fill used to come from the
    // calibration count, which put "how good the walk was" and "how many walks
    // there have been" on the same shape.
    for score in [0, 41, 76, 100] {
        #expect(SessionScoreView.ringFill(forProvisional: score) == Double(score) / 100)
    }
}

@Test func theRingFillIgnoresTheSessionCount() {
    // The same score on session 1 and session 4 draws the same arc.
    #expect(
        SessionScoreView.ringFill(forProvisional: 41)
            == SessionScoreView.ringFill(forProvisional: 41)
    )
    #expect(SessionScoreView.ringFill(forProvisional: 41) != 1.0 / 5)
    #expect(SessionScoreView.ringFill(forProvisional: 41) != 4.0 / 5)
}

@Test func theRingFillIsClampedAndEmptyWithoutAScore() {
    #expect(SessionScoreView.ringFill(forProvisional: nil) == 0)
    #expect(SessionScoreView.ringFill(forProvisional: -10) == 0)
    #expect(SessionScoreView.ringFill(forProvisional: 140) == 1)
}

// MARK: - Contrast inside the ring (§9)

@Test func theScoreLabelClearsTheContrastFloorInBothModes() {
    // It sits on `bg-base`, which is near-white in one mode and near-black in
    // the other, so a single-value navy cannot serve both. 3:1 is §9's floor
    // for text at this size.
    for dark in [false, true] {
        let ratio = contrastRatio(StabilyzColor.ink600, StabilyzColor.bgBase, dark: dark)
        #expect(ratio >= 3, "score label contrast \(ratio) in \(dark ? "dark" : "light")")
    }
}

@Test func theNavyItReplacedWouldHaveFailedInDarkMode() {
    // Why the token moved: `primary900` carries no dark-mode pair, so in dark
    // mode it is near-black ink on a near-black page.
    #expect(contrastRatio(StabilyzColor.primary900, StabilyzColor.bgBase, dark: true) < 3)
}

@Test func theProgressDotsAreNotTheOnlyChannel() {
    // §9: never encode by colour alone. The header states the same count in
    // words directly above the dots.
    let progress = SessionScorePresentation.baselineProgress(
        completed: 3, required: 5, mode: .quickTest
    )
    #expect(progress?.header.contains("3") == true)
    #expect(progress?.header.contains("5") == true)
}

@Test func theProgressDotIsSizedAsDrawn() {
    #expect(Controls.progressDotDiameter == 10)
}

// MARK: - A stored session, read back from History (Task 9.1.1)

private func stored(_ session: GaitSession, walk: Int, validCount: Int) -> SessionScorePresentation {
    SessionScorePresentation(stored: session, walk: walk, validSessionCount: validCount, baselineIndex: 100)
}

@Test func aStoredScoredSessionReadsTheSameAsWhenItWasCommitted() {
    let session = GaitSession.fixtureValid(score: .fixture(relativeIndex: 108))
    #expect(stored(session, walk: 7, validCount: 9) == presentation(commit(session: session)))
}

@Test func aStoredCalibrationWalkIsNumberedByItsOwnPosition() {
    let model = stored(.fixtureValid(provisionalScore: .fixture(value: 71)), walk: 3, validCount: 4)
    #expect(model.progress == .building(validCount: 3, required: 5, provisional: 71))
    #expect(model.baselineProgress?.header == "Walk 3 of 5")
    #expect(model.baselineProgress?.completed == 3)
}

@Test func aStoredCalibrationWalkCountsDownFromWhereTheModeIsNow() {
    // Walk 2, but four walks exist by the time it is looked at: what is left
    // is one, not three.
    let model = stored(.fixtureValid(), walk: 2, validCount: 4)
    #expect(model.baselineProgress?.helper == "Complete one more valid Quick Test to set your personal baseline.")
}

@Test func aCalibrationWalkLookedBackOnAfterCalibrationAsksForNothing() {
    let model = stored(.fixtureValid(mode: .fullTest), walk: 2, validCount: 8)
    #expect(model.baselineProgress?.helper == "Your personal baseline is set from your first five valid Full Tests.")
}

@Test func aStoredSessionNeverRepeatsTheCommitTimeNote() {
    // "Your baseline is ready" was news on the day. Read back from History it
    // would announce, again, something that happened weeks ago.
    let model = stored(.fixtureValid(), walk: 5, validCount: 5)
    #expect(model.note == nil)
    #expect(model.baselineProgress?.header == "Walk 5 of 5")
}

@Test func aStoredWalkPastCalibrationWithNoScoreIsNotComparable() {
    let model = stored(.fixtureValid(provisionalScore: .fixture()), walk: 6, validCount: 6)
    #expect(model.progress == .notComparable)
    #expect(model.baselineProgress == nil)
}

@Test func aStoredCalibrationWalkStillExplainsItsProvisionalScore() {
    let model = stored(.fixtureValid(provisionalScore: .fixture()), walk: 1, validCount: 1)
    #expect(model.highlight != nil)
    #expect(model.signals.isEmpty)
    #expect(model.measurements.count == 3)
}
