import Foundation
import Testing
@testable import Stabilyz

/// Regenerates the golden files. **Never runs by default.**
///
/// See Goldens/README.md. Guarded by `STABILYZ_REGENERATE_GOLDENS=1`, so a
/// failing golden can never be made to pass by re-running the suite — the only
/// ways past it are fixing a regression or deliberately regenerating with
/// approval and a ledger entry.
@Suite(.serialized)
struct GoldenRegeneration {
    /// The case definitions. Expected values are filled in by running the
    /// pipeline; everything else is hand-written and reviewable.
    static let definitions: [GoldenCase] = [
        GoldenCase(
            name: "clean-walk-quick",
            notes: "Steady 1.1 s stride, equal halves and amplitudes. Pins cadence and high regularity for an unremarkable good session.",
            mode: "quickTest", profile: .unilateral,
            signal: GoldenSignalSpec(seconds: 120),
            expected: .placeholder
        ),
        GoldenCase(
            name: "jittered-steps-quick",
            notes: "Same walk with step times wobbling by 100 ms. Pins that variability rises and step regularity falls.",
            mode: "quickTest", profile: .unilateral,
            signal: GoldenSignalSpec(seconds: 120, stepJitter: 0.1),
            expected: .placeholder
        ),
        GoldenCase(
            name: "amplitude-asymmetry-quick",
            notes: "One footfall lands harder. Pins Ad2 above Ad1 while step-time asymmetry stays near zero — the two features are distinct (entry 13).",
            mode: "quickTest", profile: .unilateral,
            signal: GoldenSignalSpec(seconds: 120, firstAmplitude: 1.0, secondAmplitude: 0.45),
            expected: .placeholder
        ),
        GoldenCase(
            name: "timing-asymmetry-unilateral-quick",
            notes: "Half-cycles of 0.50 s and 0.60 s with alternating trunk lean. Pins asymmetry near the analytic 0.091.",
            mode: "quickTest", profile: .unilateral,
            signal: GoldenSignalSpec(seconds: 120, firstHalf: 0.50, secondHalf: 0.60),
            expected: .placeholder
        ),
        GoldenCase(
            name: "timing-asymmetry-bilateral-quick",
            notes: "The identical signal under a bilateral profile. Pins that asymmetry is absent, never zero [PRD §7].",
            mode: "quickTest", profile: .bilateral,
            signal: GoldenSignalSpec(seconds: 120, firstHalf: 0.50, secondHalf: 0.60),
            expected: .placeholder
        ),
        GoldenCase(
            name: "vibration-quick",
            notes: "Good walking under heavy 35 Hz vibration. Pins that noise is judged before the cleaning low-pass (entry 8) — the channels look fine, the session does not.",
            mode: "quickTest", profile: .unilateral,
            signal: GoldenSignalSpec(seconds: 120, vibrationAmplitude: 2.0),
            expected: .placeholder
        ),
        GoldenCase(
            name: "hundred-second-walk-quick",
            notes: "105 s of clean walking judged as a Quick Test. Passes [PRD OQ-3].",
            mode: "quickTest", profile: .unilateral,
            signal: GoldenSignalSpec(seconds: 105),
            expected: .placeholder
        ),
        GoldenCase(
            name: "hundred-second-walk-full",
            notes: "The identical walk judged as a Full Test. Fails: 240 s required.",
            mode: "fullTest", profile: .unilateral,
            signal: GoldenSignalSpec(seconds: 105),
            expected: .placeholder
        ),
        GoldenCase(
            name: "paused-walk-quick",
            notes: "Walk, 40 s standing still, walk. Pins that the pause is excluded from valid walking even though the clock ran [PRD §6].",
            mode: "quickTest", profile: .unilateral,
            signal: GoldenSignalSpec(seconds: 200, walkBeforePause: 80, pauseSeconds: 40),
            expected: .placeholder
        ),
        GoldenCase(
            name: "gapped-walk-quick",
            notes: "Walk with a 20 s sensor dropout. Pins that the gap is detected and not bridged, and the walking either side still counts.",
            mode: "quickTest", profile: .unilateral,
            signal: GoldenSignalSpec(seconds: 200, walkBeforeGap: 80, gapSeconds: 20),
            expected: .placeholder
        )
    ]

    @Test func regenerateGoldensWhenExplicitlyRequested() async throws {
        guard GoldenStore.isRegenerating else { return }

        for definition in Self.definitions {
            let config = AlgorithmConfiguration.v1
            let buffer = GoldenSignal.buffer(for: definition.signal, mode: definition.testMode)

            let pipeline = GaitAnalysisPipeline(configuration: config)
            let outcome = try await pipeline.analyze(
                buffer: buffer,
                baseline: nil,
                profile: definition.profile.profile,
                progress: { _ in }
            )

            let series = Preprocessing.process(buffer.series, configuration: config)
            let segmentation = WalkingSegmentDetector.detect(in: series, configuration: config)
            let quality = SignalQualityValidation.validate(
                series: series, segmentation: segmentation, buffer: buffer, configuration: config
            )

            var expected = GoldenExpectation(
                valid: outcome.isValid,
                invalidReason: nil,
                validWalkingSeconds: durationSeconds(outcome.validWalkingDuration),
                cadenceMean: nil,
                stepTimeAsymmetry: nil,
                asymmetryReported: false,
                stepRegularity: nil, strideRegularity: nil, stepTimeCV: nil,
                trunkMotionML: nil, trunkMotionVT: nil,
                validStrideCount: nil, windowCount: nil,
                exceededNoiseLimit: quality.exceededNoiseLimit,
                highFrequencyPowerRatio: quality.highFrequencyPowerRatio,
                gapCount: quality.gapInfo.gapCount
            )

            switch outcome {
            case .invalid(let reason, _):
                expected.invalidReason = reason.rawValue
            case .valid(let metrics, _, _):
                expected.cadenceMean = metrics.cadenceMean
                expected.stepTimeAsymmetry = metrics.stepTimeAsymmetry
                expected.asymmetryReported = metrics.stepTimeAsymmetry != nil
                expected.stepRegularity = metrics.stepRegularity
                expected.strideRegularity = metrics.strideRegularity
                expected.stepTimeCV = metrics.stepTimeCV
                expected.trunkMotionML = metrics.trunkMotionML
                expected.trunkMotionVT = metrics.trunkMotionVT
                expected.validStrideCount = metrics.validStrideCount
                expected.windowCount = metrics.windowCount
            }

            var golden = definition
            golden.expected = expected
            try GoldenStore.write(golden)
        }
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

private extension GoldenExpectation {
    /// Filled in by regeneration; never committed in this state.
    static let placeholder = GoldenExpectation(
        valid: false, invalidReason: nil, validWalkingSeconds: 0,
        cadenceMean: nil, stepTimeAsymmetry: nil, asymmetryReported: false,
        stepRegularity: nil, strideRegularity: nil, stepTimeCV: nil,
        trunkMotionML: nil, trunkMotionVT: nil,
        validStrideCount: nil, windowCount: nil,
        exceededNoiseLimit: false, highFrequencyPowerRatio: 0, gapCount: 0
    )
}
