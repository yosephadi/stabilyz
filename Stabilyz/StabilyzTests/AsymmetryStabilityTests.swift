import Foundation
import Testing
@testable import Stabilyz

/// Step-time asymmetry must not depend on where the recording started
/// (docs/decisions.md entry 41, [PRD §7, OQ-1]).
///
/// The lead-in trim did not create the defect this suite pins; it exposed it.
/// Before the prominence floor moved to 0.3, the `jittered-steps-quick` fixture
/// — symmetric by construction — reported 0.000, 0.143 or 0.286 depending only
/// on the trim offset, and the golden happened to be recorded at an offset that
/// gave 0.000. A single-offset golden cannot catch that, which is why this
/// sweeps.

/// `.v1` with a different lead-in, which is the only thing these vary.
private func configuration(leadInMilliseconds: Int) -> AlgorithmConfiguration {
    let base = AlgorithmConfiguration.v1
    let preprocessing = PreprocessingPolicy(
        targetSampleRateHz: base.preprocessing.targetSampleRateHz,
        highPassCutoffHz: base.preprocessing.highPassCutoffHz,
        lowPassCutoffHz: base.preprocessing.lowPassCutoffHz,
        gravityEstimationCutoffHz: base.preprocessing.gravityEstimationCutoffHz,
        minimumSegmentDuration: base.preprocessing.minimumSegmentDuration,
        leadInTrim: .milliseconds(leadInMilliseconds),
        filterEdgePaddingCycles: base.preprocessing.filterEdgePaddingCycles,
        zeroPhaseFiltering: base.preprocessing.zeroPhaseFiltering
    )
    return AlgorithmConfiguration(
        version: base.version, motionAcquisition: base.motionAcquisition,
        gapDetection: base.gapDetection, preprocessing: preprocessing,
        walkingDetection: base.walkingDetection, featureExtraction: base.featureExtraction,
        baseline: base.baseline, summary: base.summary, orientation: base.orientation,
        noise: base.noise, trunkProxy: base.trunkProxy, asymmetry: base.asymmetry,
        normalization: base.normalization, composite: base.composite,
        intrinsic: base.intrinsic, quality: base.quality,
        liveStepFeedback: base.liveStepFeedback, metricDirections: base.metricDirections
    )
}

/// The asymmetry each trim offset produces. Nil entries are the estimator
/// declining, which is a result rather than a gap.
private func asymmetrySweep(_ name: String) async throws -> [(trim: Int, value: Double?)] {
    let golden = try GoldenStore.load(name)
    var readings: [(trim: Int, value: Double?)] = []

    for trim in stride(from: 0, through: 5000, by: 500) {
        let configuration = configuration(leadInMilliseconds: trim)
        let outcome = try await GaitAnalysisPipeline(configuration: configuration).analyze(
            buffer: GoldenSignal.buffer(for: golden.signal, mode: golden.testMode),
            baseline: nil,
            profile: golden.profile.profile,
            progress: { _ in }
        )
        guard case .valid(let metrics, _, _, _) = outcome else {
            Issue.record("\(name) at trim \(trim)ms should be valid")
            continue
        }
        readings.append((trim, metrics.stepTimeAsymmetry))
    }
    return readings
}

// MARK: - A symmetric walk never reports an asymmetry

@Test func aJitteredSymmetricWalkNeverReportsASpuriousAsymmetry() async throws {
    // Half-cycles of 0.55 s and 0.55 s with 100 ms of jitter: symmetric by
    // construction, however ragged. Any value it reports must be zero, and the
    // readings that used to appear here — 0.143 and 0.286 — must appear at no
    // offset at all.
    for reading in try await asymmetrySweep("jittered-steps-quick") {
        guard let value = reading.value else { continue }
        #expect(abs(value) <= 0.03, "trim \(reading.trim)ms reported \(value)")
    }
}

@Test func aCleanWalkReadsTheSameAtEveryOffset() async throws {
    // The control. A walk with real peak structure was never offset-sensitive,
    // and must stay that way — the fix must not have bought stability by
    // silencing everything.
    let readings = try await asymmetrySweep("clean-walk-quick")
    let reported = readings.compactMap(\.value)

    #expect(reported.count == readings.count, "a clean walk should report at every offset")
    for value in reported {
        #expect(abs(value) <= 0.03)
    }
}

@Test func aRealAsymmetryIsStillDetectedAtEveryOffset() async throws {
    // The other half of the guard: the floor that rejects the aperiodic walk
    // must not reject the case this feature exists for. Half-cycles of 0.50 s
    // and 0.60 s — an analytic 0.091.
    let readings = try await asymmetrySweep("timing-asymmetry-unilateral-quick")

    for reading in readings {
        let value = try #require(
            reading.value,
            "trim \(reading.trim)ms lost a real asymmetry"
        )
        #expect(abs(value - 0.091) <= 0.03, "trim \(reading.trim)ms read \(value)")
    }
}

// MARK: - Why the floor sits where it does

@Test func theProminenceFloorRejectsAWalkWithNoPeakStructure() {
    // Raised from 0.2 (entry 41). The jittered fixture's Ad1 is 0.27 and its
    // Ad2 0.23, so at 0.2 its half-stride "peaks" cleared the bar and the
    // estimator paired noise. The floor has to sit above that structure.
    #expect(AlgorithmConfiguration.v1.asymmetry.minimumPeakProminence == 0.3)
    #expect(AlgorithmConfiguration.v1.asymmetry.requiresBothPeaksProminent)
}

@Test func anAbsentAsymmetryIsNotRecordedAsZero() {
    // Zero is a claim: "the step durations really were equal". A walk that
    // supports no claim either way must carry nil (entry 13, [PRD §7]).
    let golden = try? GoldenStore.load("jittered-steps-quick")
    #expect(golden?.expected.asymmetryReported == false)
    #expect(golden?.expected.stepTimeAsymmetry == nil)
}
