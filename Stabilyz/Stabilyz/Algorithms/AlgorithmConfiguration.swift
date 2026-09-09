import Foundation

// The single home for every tunable in the gait pipeline (docs/07 §7.5,
// docs/08 §8.2). Nothing else in the app declares one of these values.
//
// EVERY VALUE HERE IS PROVISIONAL — pending device validation (Phase 12).
// The design docs mark most of them [OPEN]; they are decided here so the
// pipeline can be built and measured, not because they are settled. Changing
// one is a configuration edit and a version bump, never a code change at a
// call site. See docs/decisions.md.

/// How the signal's axes are derived (docs/08 §8.2).
struct OrientationPolicy: Sendable, Equatable {
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Vertical comes from the device-motion gravity vector rather than an
    /// assumed phone orientation, so pocket, waistband and hand carry alike.
    let verticalFromGravity: Bool
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Mediolateral and anteroposterior are separated by the dominant variance
    /// direction in the horizontal plane: walking varies more side-to-side than
    /// fore-aft at the trunk, so the dominant direction identifies ML.
    let horizontalSplitByDominantVariance: Bool
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Recomputed per session, so a different carry position between sessions
    /// does not silently reinterpret the axes.
    let computedPerSession: Bool
}

/// Filtering, resampling and orientation for pipeline stage 2 (docs/08).
struct PreprocessingPolicy: Sendable, Equatable {
    /// PROVISIONAL — pending device validation (Phase 12).
    /// The uniform grid every later stage assumes. Matching the acquisition
    /// rate keeps resampling to interpolation between neighbours rather than a
    /// rate change.
    let targetSampleRateHz: Double
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Removes drift and any residual gravity. Below a slow walk's stride
    /// frequency, so nothing gait-related is attenuated.
    let highPassCutoffHz: Double
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Removes energy above gait harmonics. Sits above the noise metric's 8 Hz
    /// cutoff so the two measure different things: this one cleans the signal,
    /// that one judges it.
    let lowPassCutoffHz: Double
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Used only when a capture has no gravity vector: gravity is then whatever
    /// survives below this frequency.
    let gravityEstimationCutoffHz: Double
    /// PROVISIONAL — pending device validation (Phase 12).
    /// A fragment shorter than this between two dropouts carries no usable
    /// gait and would only add filter edge artefacts.
    let minimumSegmentDuration: Duration

    /// PROVISIONAL — pending device validation (Phase 12).
    /// Cycles of the high-pass cutoff to reflect-pad each end with before
    /// filtering. An IIR filter starts from rest, so without padding the first
    /// samples carry a start-up transient rather than signal — and with
    /// zero-phase filtering that artefact appears at both ends.
    let filterEdgePaddingCycles: Double

    /// Whether the band-pass is applied forward and then backward.
    ///
    /// Zero phase matters here: step times are measured off this signal, and a
    /// one-sided filter shifts every peak by the same delay — harmless for
    /// intervals, but it would misplace peaks against the pedometer and the
    /// gap record, which are on the untouched timeline.
    let zeroPhaseFiltering: Bool
}

/// Which stretches of a session count as walking (docs/08 stage 3).
struct WalkingDetectionPolicy: Sendable, Equatable {
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Window for the moving RMS that separates movement from stillness. About
    /// two strides, so a single footfall cannot open a bout and a single quiet
    /// moment between steps cannot close one.
    let activityWindow: Duration
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Vertical RMS, in g, above which the trunk is moving like walking rather
    /// than standing. Standing still registers near zero after the band-pass;
    /// trunk acceleration while walking is an order of magnitude larger.
    let verticalRMSThreshold: Double
    /// PROVISIONAL — pending device validation (Phase 12).
    /// A dip shorter than this does not end a bout — hesitating at a kerb is
    /// not two walks.
    let maximumBridgedPause: Duration
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Gait initiation is not steady-state gait: the first strides accelerate
    /// from rest and are more variable than the walk they lead into. Excluded
    /// per the Tura note [PRD OQ-1].
    let initiationTrim: Duration
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Gait termination, likewise — decelerating to a stop.
    let terminationTrim: Duration
    /// PROVISIONAL — pending device validation (Phase 12).
    /// What remains after trimming must be at least this long to be steady-state
    /// walking worth measuring.
    let minimumBoutDuration: Duration
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Steps per minute that a human walk can plausibly produce. Used only to
    /// judge whether the pedometer agrees with what the accelerometer found —
    /// never to override it.
    let plausibleCadenceRange: ClosedRange<Double>
}

/// Step detection and autocorrelation for pipeline stage 5 (docs/08).
struct FeatureExtractionPolicy: Sendable, Equatable {
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Analysis window. Long enough to hold well over the ~3.5 strides Tura
    /// reports as sufficient for Ad2 once transients are excluded [PRD OQ-1],
    /// short enough that several windows fit inside a Quick Test.
    let analysisWindowDuration: Duration
    /// PROVISIONAL — pending device validation (Phase 12).
    /// A trailing window shorter than the full length is still analysed if it
    /// reaches this, rather than discarding the end of every walk.
    let minimumAnalysisWindowDuration: Duration
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Standard deviations above the window mean a sample must reach to be a
    /// footfall. Low enough not to miss the weaker side of an asymmetric gait,
    /// high enough to ignore ripple between steps.
    let stepPeakProminenceSDs: Double
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Fractional window around an expected lag when reading an autocorrelation
    /// peak. The search is always anchored: a free search over all lags is what
    /// lets a stride peak be mistaken for a step peak.
    let lagSearchTolerance: Double
}

/// How noise is measured and where the acceptable limit sits
/// (docs/08 stage 4, PRD: "define threshold").
struct NoisePolicy: Sendable, Equatable {
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Noise is the share of signal power above this frequency, measured on
    /// acceleration magnitude. Walking energy sits well below it, so a high
    /// ratio means the signal is dominated by something that is not gait.
    let highFrequencyCutoffHz: Double
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Sessions above this ratio are invalid with `excessiveNoise`.
    let maximumHighFrequencyPowerRatio: Double

    /// Whether a measured ratio fails the quality gate.
    func isTooNoisy(highFrequencyPowerRatio ratio: Double) -> Bool {
        ratio > maximumHighFrequencyPowerRatio
    }
}

/// The trunk-motion proxy's formulation (docs/05 §5.1, docs/08 §8.2).
struct TrunkProxyPolicy: Sendable, Equatable {
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Per-axis RMS over steady-state walking, kept as two values rather than
    /// combined, so ML and VT stay separately inspectable in the breakdown.
    let perAxisRMS: Bool
}

/// Whether the secondary asymmetry feature can be computed for a session
/// (docs/08 §8.2, [PRD §7, OQ-1]).
struct AsymmetryPolicy: Sendable, Equatable {
    /// PROVISIONAL — pending device validation (Phase 12).
    /// (P1 − P2) / (P1 + P2) over the two autocorrelation half-stride peaks.
    /// A signed, bounded ratio, so left- and right-dominant asymmetry are
    /// distinguishable and the magnitude is comparable between users.
    let usesHalfStridePeakRatio: Bool
    /// Unilateral profiles only. Never fabricated for bilateral users
    /// [PRD §7, OQ-1] — this is a PRD rule, not a tunable.
    let requiresUnilateralProfile: Bool
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Both half-stride peaks must be prominent before a value is reported.
    let requiresBothPeaksProminent: Bool
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Normalised autocorrelation both peaks must reach. Below this the walk is
    /// not periodic enough for the contrast between the peaks to mean anything,
    /// and the honest answer is no value at all rather than a number.
    let minimumPeakProminence: Double
    /// The affected side comes from the user's profile, not from guessing at
    /// the signal [PRD §7].
    let sideFromProfile: Bool
}

/// Per-metric standardisation against a baseline (docs/08 stage 7).
struct NormalizationPolicy: Sendable, Equatable {
    /// PROVISIONAL — pending device validation (Phase 12).
    /// The floor is a fraction of the metric's own baseline mean, so it scales
    /// with metrics of very different magnitudes.
    let relativeFloorFraction: Double
    /// PROVISIONAL — pending device validation (Phase 12).
    /// A last-resort floor per metric, for a baseline mean near zero where the
    /// relative floor would vanish.
    let absoluteFloors: [MetricID: Double]

    /// The standard deviation to divide by.
    ///
    /// The minimum-SD floor is **PRD-required** [PRD §7 AC]: without it, a
    /// metric that happened to be near-identical across the five calibration
    /// sessions produces a tiny SD and then wildly exaggerated z-scores.
    func flooredSD(for metric: MetricID, observedSD: Double, baselineMean: Double) -> Double {
        max(
            observedSD,
            max(relativeFloorFraction * abs(baselineMean), absoluteFloors[metric] ?? 0)
        )
    }

    /// Whether the floor replaced the observed SD, recorded on the stat.
    func floorApplied(for metric: MetricID, observedSD: Double, baselineMean: Double) -> Bool {
        flooredSD(for: metric, observedSD: observedSD, baselineMean: baselineMean) > observedSD
    }
}

/// The terms the composite score is built from (docs/08 stage 8).
///
/// **`stepTimeAsymmetry` is deliberately absent.** It is computed, stored and
/// displayed on its own, never merged into the composite — see docs/decisions.md
/// for why the narrower [PRD §7] reading was chosen over the [PRD §4] one.
enum CompositeTerm: String, Sendable, CaseIterable, Codable {
    case stepRegularity
    case strideRegularity
    case stepTimeCV
    /// The ML and VT z-scores, averaged into one term.
    case trunkProxy
}

/// How standardised metrics combine into a single index (docs/08 stage 8).
struct CompositePolicy: Sendable, Equatable {
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Equal quarters. Gait consistency contributes half the score through Ad1
    /// and Ad2 but can never be the sole basis of it [PRD §7], because the
    /// other half comes from variability and trunk motion.
    let weights: [CompositeTerm: Double]
    /// Terms where a lower raw value is the better result, so their z-score is
    /// inverted before weighting.
    let invertedTerms: Set<CompositeTerm>

    /// PROVISIONAL — pending device validation (Phase 12).
    /// Baseline sits at 100 and one standard deviation is 100 points, so the
    /// PRD's example of 112 is a modest improvement rather than a percentage
    /// claim [PRD §7].
    let indexCenter: Double
    /// PROVISIONAL — pending device validation (Phase 12).
    let indexScalePerSD: Double
    /// PROVISIONAL — pending device validation (Phase 12).
    /// Clamped so a single wild session cannot render a trend chart unreadable.
    let indexRange: ClosedRange<Int>

    func weight(for term: CompositeTerm) -> Double { weights[term] ?? 0 }

    func isInverted(_ term: CompositeTerm) -> Bool { invertedTerms.contains(term) }

    /// Maps a composite z-score onto the relative index shown to the user.
    func relativeIndex(forCompositeZ compositeZ: Double) -> Int {
        let raw = (indexCenter + indexScalePerSD * compositeZ).rounded()
        let clamped = min(max(raw, Double(indexRange.lowerBound)), Double(indexRange.upperBound))
        return Int(clamped)
    }
}

/// The go/no-go gate before a session is scored (docs/08 stage 4, docs/07 §7.5).
struct DataQualityPolicy: Sendable, Equatable {
    /// Mode minimums, which are [PRD OQ-3] product thresholds rather than
    /// algorithm tunables, so they stay in `SessionPolicy`.
    let sessionPolicy: SessionPolicy
    let noise: NoisePolicy
    /// PROVISIONAL — pending device validation (Phase 12).
    /// docs/08 stage 5 cites 15-20 strides as a tuning reference, not a spec.
    let minimumValidStrides: Int

    func minimumValidWalkingDuration(for mode: TestMode) -> Duration {
        sessionPolicy.minimumValidWalkingDuration(for: mode)
    }

    /// The reason a session fails the gate, or nil when it passes.
    ///
    /// Order matters for the message the user sees: too little walking is a
    /// plainer explanation than a noise measurement, so it is reported first.
    /// - Parameter validStrideCount: nil at stage 4, which runs before step
    ///   detection. Stride sufficiency is stage 5's gate (docs/08).
    func invalidReason(
        mode: TestMode,
        validWalkingDuration: Duration,
        validStrideCount: Int? = nil,
        highFrequencyPowerRatio: Double
    ) -> InvalidReason? {
        if validWalkingDuration < minimumValidWalkingDuration(for: mode) {
            return .insufficientValidWalking
        }
        if let validStrideCount, validStrideCount < minimumValidStrides {
            return .insufficientValidWalking
        }
        if noise.isTooNoisy(highFrequencyPowerRatio: highFrequencyPowerRatio) {
            return .excessiveNoise
        }
        return nil
    }
}

/// Every tunable in the pipeline, versioned as one value (docs/08 §8.2).
///
/// A v2 algorithm is a new configuration plus a new `version`; sessions and
/// baselines record the version they were computed under, so the two coexist
/// without a schema migration (docs/09 §9.6).
struct AlgorithmConfiguration: Sendable, Equatable {
    let version: String
    let motionAcquisition: MotionAcquisitionPolicy
    let gapDetection: GapDetectionPolicy
    let preprocessing: PreprocessingPolicy
    let walkingDetection: WalkingDetectionPolicy
    let featureExtraction: FeatureExtractionPolicy
    let orientation: OrientationPolicy
    let noise: NoisePolicy
    let trunkProxy: TrunkProxyPolicy
    let asymmetry: AsymmetryPolicy
    let normalization: NormalizationPolicy
    let composite: CompositePolicy
    let quality: DataQualityPolicy
    let liveStepFeedback: LiveStepDetectionPolicy
    /// The sign convention per metric, which docs/05 §5.1 requires the model to
    /// carry and configuration to supply.
    let metricDirections: MetricDirections

    /// The shipping configuration.
    ///
    /// **Every value is PROVISIONAL — pending device validation (Phase 12).**
    static let v1 = AlgorithmConfiguration(
        version: "1.0.0-provisional",
        motionAcquisition: MotionAcquisitionPolicy(
            // PROVISIONAL — pending device validation (Phase 12).
            // Enough for autocorrelation at walking cadences and pedometer-grade
            // step peaks, cheap on battery (docs/07 §7.2).
            sampleRateHz: 100,
            // Device motion supplies the gravity vector the orientation policy needs.
            deviceMotionEnabled: true
        ),
        gapDetection: GapDetectionPolicy(
            // PROVISIONAL — pending device validation (Phase 12).
            // Three times the observed median interval: at least two consecutive
            // samples must be missing before anything counts as a dropout.
            toleranceMultiplier: 3
        ),
        preprocessing: PreprocessingPolicy(
            // PROVISIONAL — pending device validation (Phase 12).
            targetSampleRateHz: 100,
            // PROVISIONAL — pending device validation (Phase 12).
            highPassCutoffHz: 0.5,
            // PROVISIONAL — pending device validation (Phase 12).
            lowPassCutoffHz: 20,
            // PROVISIONAL — pending device validation (Phase 12).
            gravityEstimationCutoffHz: 0.5,
            // PROVISIONAL — pending device validation (Phase 12).
            minimumSegmentDuration: .seconds(2),
            // PROVISIONAL — pending device validation (Phase 12).
            filterEdgePaddingCycles: 3,
            zeroPhaseFiltering: true
        ),
        walkingDetection: WalkingDetectionPolicy(
            // PROVISIONAL — pending device validation (Phase 12).
            activityWindow: .milliseconds(1000),
            // PROVISIONAL — pending device validation (Phase 12).
            verticalRMSThreshold: 0.05,
            // PROVISIONAL — pending device validation (Phase 12).
            maximumBridgedPause: .milliseconds(500),
            // PROVISIONAL — pending device validation (Phase 12).
            initiationTrim: .seconds(1),
            // PROVISIONAL — pending device validation (Phase 12).
            terminationTrim: .seconds(1),
            // PROVISIONAL — pending device validation (Phase 12).
            minimumBoutDuration: .seconds(3),
            // PROVISIONAL — pending device validation (Phase 12).
            plausibleCadenceRange: 30...200
        ),
        featureExtraction: FeatureExtractionPolicy(
            // PROVISIONAL — pending device validation (Phase 12).
            analysisWindowDuration: .seconds(10),
            // PROVISIONAL — pending device validation (Phase 12).
            minimumAnalysisWindowDuration: .seconds(5),
            // PROVISIONAL — pending device validation (Phase 12).
            stepPeakProminenceSDs: 0.5,
            // PROVISIONAL — pending device validation (Phase 12).
            lagSearchTolerance: 0.15
        ),
        orientation: OrientationPolicy(
            verticalFromGravity: true,
            horizontalSplitByDominantVariance: true,
            computedPerSession: true
        ),
        noise: NoisePolicy(
            highFrequencyCutoffHz: 8,
            maximumHighFrequencyPowerRatio: 0.35
        ),
        trunkProxy: TrunkProxyPolicy(perAxisRMS: true),
        asymmetry: AsymmetryPolicy(
            usesHalfStridePeakRatio: true,
            requiresUnilateralProfile: true,
            requiresBothPeaksProminent: true,
            // PROVISIONAL — pending device validation (Phase 12).
            minimumPeakProminence: 0.2,
            sideFromProfile: true
        ),
        normalization: NormalizationPolicy(
            // PROVISIONAL — pending device validation (Phase 12).
            relativeFloorFraction: 0.05,
            // PROVISIONAL — pending device validation (Phase 12).
            absoluteFloors: [
                .stepRegularity: 0.02,
                .strideRegularity: 0.02,
                .cadenceMean: 2.0,
                .stepTimeCV: 0.01,
                .trunkMotionML: 0.05,
                .trunkMotionVT: 0.05,
                .stepTimeAsymmetry: 0.02
            ]
        ),
        composite: CompositePolicy(
            // PROVISIONAL — pending device validation (Phase 12).
            weights: [
                .stepRegularity: 0.25,
                .strideRegularity: 0.25,
                .stepTimeCV: 0.25,
                .trunkProxy: 0.25
            ],
            invertedTerms: [.stepTimeCV, .trunkProxy],
            indexCenter: 100,
            indexScalePerSD: 100,
            indexRange: 0...200
        ),
        quality: DataQualityPolicy(
            sessionPolicy: .v1,
            noise: NoisePolicy(highFrequencyCutoffHz: 8, maximumHighFrequencyPowerRatio: 0.35),
            // PROVISIONAL — pending device validation (Phase 12).
            minimumValidStrides: 15
        ),
        liveStepFeedback: LiveStepDetectionPolicy(
            // PROVISIONAL — pending device validation (Phase 12).
            confidenceThreshold: 0.5,
            // PROVISIONAL — pending device validation (Phase 12).
            refractory: .milliseconds(300)
        ),
        // PROVISIONAL — pending device validation (Phase 12).
        // Only the metrics that carry a decided sign convention appear here.
        // cadenceMean and stepTimeAsymmetry are standardised for display but
        // contribute no direction to the score, so neither is listed — see
        // docs/decisions.md.
        metricDirections: MetricDirections([
            .stepRegularity: .higherIsBetter,
            .strideRegularity: .higherIsBetter,
            .stepTimeCV: .lowerIsBetter,
            .trunkMotionML: .lowerIsBetter,
            .trunkMotionVT: .lowerIsBetter
        ])
    )
}
