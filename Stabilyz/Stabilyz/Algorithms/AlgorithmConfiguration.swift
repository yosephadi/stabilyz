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
    /// Both half-stride peaks must be prominent before a value is reported;
    /// what counts as prominent is the feature stage's own peak criterion
    /// (Task 5.2.4), not a separate threshold declared here.
    let requiresBothPeaksProminent: Bool
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
    func invalidReason(
        mode: TestMode,
        validWalkingDuration: Duration,
        validStrideCount: Int,
        highFrequencyPowerRatio: Double
    ) -> InvalidReason? {
        if validWalkingDuration < minimumValidWalkingDuration(for: mode) {
            return .insufficientValidWalking
        }
        if validStrideCount < minimumValidStrides {
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
