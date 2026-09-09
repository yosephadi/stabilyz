import Foundation
import Testing
@testable import Stabilyz

/// End-to-end regression suite (docs/19 §19.1).
///
/// The stage tests prove each stage in isolation. These prove the assembly: a
/// `RawSessionBuffer` goes in, `GaitScoringAlgorithm` runs, and a
/// `SessionAnalysisOutcome` comes out, compared against a recorded golden.
///
/// **Tolerances.** Two kinds of expected value, with different tolerances and
/// different meanings:
///
/// - *Derived* values follow from the signal parameters — cadence is
///   `120 / stride`, asymmetry is `|Δhalf| / stride`, valid walking follows from
///   the walking content. These are asserted against physics with a tolerance
///   wide enough only for windowing and transient trimming to shift them.
/// - *Recorded* values (Ad1, Ad2, CV, trunk RMS) have no closed form. They are
///   regression anchors, compared with a relative tolerance tight enough to
///   catch a real algorithm change and loose enough to survive floating-point
///   and window-boundary jitter.
private enum Tolerance {
    /// Cadence in steps/min. Windowing shifts the median step slightly.
    static let cadence = 4.0
    /// Asymmetry index. The peak position is quantised to the sample grid, so
    /// at 100 Hz one sample of a ~1.1 s stride is already ~0.009.
    static let asymmetry = 0.03
    /// Valid-walking seconds. Transient trimming and window edges move this by
    /// a second or two, not more.
    static let walkingSeconds = 3.0
    /// Relative tolerance for recorded anchors: 5% catches a genuine change in
    /// behaviour while absorbing numerical jitter.
    static let relative = 0.05
    /// Noise ratio is a filter estimate, not a spectrum, so it moves a little.
    static let noiseRatio = 0.05
}

private func runPipeline(_ golden: GoldenCase) async throws -> (SessionAnalysisResult, SessionQualityReport) {
    let config = AlgorithmConfiguration.v1
    let buffer = GoldenSignal.buffer(for: golden.signal, mode: golden.testMode)

    let processor = SessionProcessor(
        algorithm: GaitAnalysisPipeline(configuration: config),
        logService: SilentGoldenLog()
    )
    let result = try await processor.process(
        buffer: buffer,
        baseline: nil,
        profile: golden.profile.profile
    )

    // The quality report is recomputed for the facts the outcome does not carry.
    let series = Preprocessing.process(buffer.series, configuration: config)
    let segmentation = WalkingSegmentDetector.detect(in: series, configuration: config)
    let quality = SignalQualityValidation.validate(
        series: series, segmentation: segmentation, buffer: buffer, configuration: config
    )
    return (result, quality)
}

private final class SilentGoldenLog: LogService, @unchecked Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func expectClose(_ actual: Double?, _ expected: Double?, relative: Double, _ label: String) {
    guard let expected else {
        #expect(actual == nil, "\(label): expected absent, got \(actual as Any)")
        return
    }
    guard let actual else {
        Issue.record("\(label): expected \(expected), got nil")
        return
    }
    let allowed = max(abs(expected) * relative, 1e-6)
    #expect(abs(actual - expected) <= allowed, "\(label): \(actual) vs golden \(expected)")
}

/// Runs one golden case and compares every field.
private func verify(_ name: String) async throws {
    let golden = try GoldenStore.load(name)
    let (result, quality) = try await runPipeline(golden)

    // Validity and reason first: everything else depends on it.
    #expect(result.outcome.isValid == golden.expected.valid, "\(name): validity")
    #expect(result.outcome.invalidReasonName == golden.expected.invalidReason, "\(name): reason")

    // Derived — asserted against the signal's own parameters.
    #expect(
        abs(seconds(result.outcome.validWalkingDuration) - golden.expected.validWalkingSeconds)
            <= Tolerance.walkingSeconds,
        "\(name): valid walking \(seconds(result.outcome.validWalkingDuration)) vs \(golden.expected.validWalkingSeconds)"
    )
    #expect(quality.exceededNoiseLimit == golden.expected.exceededNoiseLimit, "\(name): noise limit")
    #expect(
        abs(quality.highFrequencyPowerRatio - golden.expected.highFrequencyPowerRatio) <= Tolerance.noiseRatio,
        "\(name): noise ratio"
    )
    #expect(quality.gapInfo.gapCount == golden.expected.gapCount, "\(name): gap count")

    guard case .valid(let metrics, _, _) = result.outcome else {
        #expect(golden.expected.cadenceMean == nil, "\(name): invalid sessions carry no metrics")
        return
    }

    // Derived.
    if let cadence = golden.expected.cadenceMean {
        #expect(abs(metrics.cadenceMean - cadence) <= Tolerance.cadence, "\(name): cadence \(metrics.cadenceMean)")
        // And against the signal itself, not just the recorded value — except
        // where jitter is injected, which genuinely changes the stride
        // durations the signal contains, so the nominal figure no longer
        // describes it.
        if golden.signal.stepJitter == 0 {
            #expect(
                abs(metrics.cadenceMean - golden.signal.expectedCadence) <= Tolerance.cadence,
                "\(name): cadence vs signal"
            )
        }
    }

    // The nil-versus-zero distinction, asserted before any numeric comparison.
    #expect((metrics.stepTimeAsymmetry != nil) == golden.expected.asymmetryReported, "\(name): asymmetry reported")
    if let expectedAsymmetry = golden.expected.stepTimeAsymmetry {
        let actual = try #require(metrics.stepTimeAsymmetry, "\(name): asymmetry present")
        #expect(abs(actual - expectedAsymmetry) <= Tolerance.asymmetry, "\(name): asymmetry \(actual)")
        #expect(
            abs(actual - golden.signal.expectedAsymmetry) <= Tolerance.asymmetry,
            "\(name): asymmetry vs signal \(golden.signal.expectedAsymmetry)"
        )
    } else {
        #expect(metrics.stepTimeAsymmetry == nil, "\(name): asymmetry must be absent, never zero")
    }

    // Recorded anchors.
    expectClose(metrics.stepRegularity, golden.expected.stepRegularity, relative: Tolerance.relative, "\(name): Ad1")
    expectClose(metrics.strideRegularity, golden.expected.strideRegularity, relative: Tolerance.relative, "\(name): Ad2")
    expectClose(metrics.stepTimeCV, golden.expected.stepTimeCV, relative: Tolerance.relative, "\(name): stepTimeCV")
    expectClose(metrics.trunkMotionML, golden.expected.trunkMotionML, relative: Tolerance.relative, "\(name): trunk ML")
    expectClose(metrics.trunkMotionVT, golden.expected.trunkMotionVT, relative: Tolerance.relative, "\(name): trunk VT")
    #expect(metrics.validStrideCount == golden.expected.validStrideCount, "\(name): stride count")
    #expect(metrics.windowCount == golden.expected.windowCount, "\(name): window count")
}

private extension SessionAnalysisOutcome {
    var invalidReasonName: String? {
        if case .invalid(let reason, _) = self { return reason.rawValue }
        return nil
    }
}

// MARK: - The cases

@Test func goldenCleanWalk() async throws { try await verify("clean-walk-quick") }
@Test func goldenJitteredStepTimes() async throws { try await verify("jittered-steps-quick") }
@Test func goldenAmplitudeAsymmetry() async throws { try await verify("amplitude-asymmetry-quick") }
@Test func goldenTimingAsymmetryUnilateral() async throws { try await verify("timing-asymmetry-unilateral-quick") }
@Test func goldenTimingAsymmetryBilateral() async throws { try await verify("timing-asymmetry-bilateral-quick") }
@Test func goldenVibration() async throws { try await verify("vibration-quick") }
@Test func goldenShortSessionQuick() async throws { try await verify("hundred-second-walk-quick") }
@Test func goldenShortSessionFull() async throws { try await verify("hundred-second-walk-full") }
@Test func goldenPausedSession() async throws { try await verify("paused-walk-quick") }
@Test func goldenGappedSession() async throws { try await verify("gapped-walk-quick") }

/// The only golden that exercises scoring, so it runs its own comparison rather
/// than going through `verify`, which assumes no baseline.
@Test func goldenScoredSixthSession() async throws {
    let golden = try GoldenStore.load("scored-sixth-session-quick")
    let calibration = try #require(golden.calibration)
    let config = AlgorithmConfiguration.v1
    let pipeline = GaitAnalysisPipeline(configuration: config)

    let baseline = try await GoldenSignal.baseline(
        from: calibration, mode: golden.testMode,
        profile: golden.profile.profile, configuration: config
    )

    // Derived: a calibration session scored against its own baseline sits at the
    // centre by construction, because every metric equals its own mean.
    let calibrationOutcome = try await pipeline.analyze(
        buffer: GoldenSignal.buffer(for: calibration, mode: golden.testMode),
        baseline: baseline, profile: golden.profile.profile, progress: { _ in }
    )
    guard case .valid(_, _, let calibrationScore) = calibrationOutcome else {
        Issue.record("calibration session should be valid")
        return
    }
    #expect(try #require(calibrationScore).relativeIndex == 100)
    #expect(golden.expected.calibrationRelativeIndex == 100)

    // Recorded: the scored session's index has no closed form at signal level.
    let outcome = try await pipeline.analyze(
        buffer: GoldenSignal.buffer(for: golden.signal, mode: golden.testMode),
        baseline: baseline, profile: golden.profile.profile, progress: { _ in }
    )
    guard case .valid(let metrics, _, let score) = outcome else {
        Issue.record("scored session should be valid")
        return
    }
    let actual = try #require(score)

    #expect(actual.relativeIndex == golden.expected.relativeIndex)
    expectClose(actual.compositeZ, golden.expected.compositeZ, relative: Tolerance.relative, "scored: compositeZ")
    #expect(actual.algorithmVersion == baseline.algorithmVersion)
    // The metrics are still there alongside the score.
    #expect(metrics.validStrideCount > 0)
}

@Test func aPreBaselineSessionCarriesMetricsButNoScore() async throws {
    // [PRD §7] no relative score before the sixth valid session.
    let golden = try GoldenStore.load("clean-walk-quick")
    let (result, _) = try await runPipeline(golden)

    guard case .valid(let metrics, _, let score) = result.outcome else {
        Issue.record("expected a valid session")
        return
    }
    #expect(score == nil)
    #expect(metrics.validStrideCount > 0)
}

// MARK: - Cross-cutting assertions the individual cases cannot make

@Test func theSameWalkPassesQuickAndFailsFull() async throws {
    // [PRD OQ-3] through the whole pipeline, not just the quality stage.
    let quick = try GoldenStore.load("hundred-second-walk-quick")
    let full = try GoldenStore.load("hundred-second-walk-full")

    #expect(quick.signal == full.signal)
    #expect(quick.expected.valid)
    #expect(full.expected.valid == false)
    #expect(full.expected.invalidReason == "insufficientValidWalking")

    let (quickResult, _) = try await runPipeline(quick)
    let (fullResult, _) = try await runPipeline(full)
    #expect(quickResult.outcome.isValid)
    #expect(fullResult.outcome.isValid == false)
}

@Test func theSameSignalDiffersOnlyByProfileForAsymmetry() async throws {
    // The whole pipeline is profile-blind except the one feature [PRD OQ-1].
    let unilateral = try GoldenStore.load("timing-asymmetry-unilateral-quick")
    let bilateral = try GoldenStore.load("timing-asymmetry-bilateral-quick")

    #expect(unilateral.signal == bilateral.signal)
    #expect(unilateral.expected.asymmetryReported)
    #expect(bilateral.expected.asymmetryReported == false)
    #expect(bilateral.expected.stepTimeAsymmetry == nil)
    // Every other recorded value is identical.
    #expect(unilateral.expected.stepRegularity == bilateral.expected.stepRegularity)
    #expect(unilateral.expected.strideRegularity == bilateral.expected.strideRegularity)
    #expect(unilateral.expected.cadenceMean == bilateral.expected.cadenceMean)
}

@Test func everyInvalidGoldenCarriesNoMetrics() async throws {
    // [PRD AC] invalid sessions are never scored.
    for name in ["vibration-quick", "hundred-second-walk-full"] {
        let golden = try GoldenStore.load(name)
        #expect(golden.expected.valid == false)
        #expect(golden.expected.cadenceMean == nil)
        #expect(golden.expected.asymmetryReported == false)

        let (result, _) = try await runPipeline(golden)
        if case .valid = result.outcome {
            Issue.record("\(name) should not be valid")
        }
    }
}

@Test func goldenFilesAreCompleteAndSelfDescribing() throws {
    // A golden nobody can read is not reviewable, which defeats storing them.
    for name in [
        "clean-walk-quick", "jittered-steps-quick", "amplitude-asymmetry-quick",
        "timing-asymmetry-unilateral-quick", "timing-asymmetry-bilateral-quick",
        "vibration-quick", "hundred-second-walk-quick", "hundred-second-walk-full",
        "paused-walk-quick", "gapped-walk-quick", "scored-sixth-session-quick"
    ] {
        let golden = try GoldenStore.load(name)
        #expect(golden.name == name)
        #expect(golden.notes.isEmpty == false, "\(name) has no notes explaining what it pins")
        #expect(golden.signal.seconds > 0)
    }
}
