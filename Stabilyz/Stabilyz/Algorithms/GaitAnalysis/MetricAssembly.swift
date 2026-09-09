import Foundation

/// Pipeline stage 6: per-window features become one session's `GaitMetrics`
/// (docs/08, docs/05 §5.1).
///
/// **This is where the user profile enters the pipeline, and the only place it
/// does.** Stage 5 is profile-blind by construction so gait consistency is
/// computed identically for every user [PRD OQ-1]; the unilateral/bilateral
/// distinction is legitimate here, because whether a sound-vs-prosthetic
/// comparison is even meaningful depends on the user having a sound side.
enum MetricAssembly {
    /// Aggregates features into session metrics.
    ///
    /// - Parameter profile: nil when no profile is available. Asymmetry is then
    ///   absent, never zero — the same rule as for bilateral users.
    /// - Returns: nil when there is nothing to assemble. Too few strides is a
    ///   separate check (`FeatureExtraction.strideShortfallReason`); metrics are
    ///   never produced from too little data.
    static func assemble(
        features: ExtractedFeatures,
        segmentation: WalkingSegmentation,
        buffer: RawSessionBuffer,
        profile: UserProfile?,
        configuration: AlgorithmConfiguration
    ) -> GaitMetrics? {
        guard !features.windows.isEmpty else { return nil }
        let windows = features.windows

        // Median across windows throughout. A window that caught a turn, a kerb
        // or a stumble is an outlier, not a correction — averaging lets one such
        // window drag a whole session's number.
        guard let ad1 = median(windows.map(\.ad1)),
              let ad2 = median(windows.map(\.ad2)),
              let trunkML = median(windows.map(\.trunkRMSMediolateral)),
              let trunkVT = median(windows.map(\.trunkRMSVertical)) else { return nil }

        let allStepTimes = windows.flatMap(\.stepTimes)
        guard let medianStepTime = median(allStepTimes), medianStepTime > 0 else { return nil }

        let asymmetry = stepTimeAsymmetry(
            windows: windows,
            profile: profile,
            configuration: configuration
        )

        return GaitMetrics(
            stepRegularity: ad1,
            strideRegularity: ad2,
            // Cadence from the median step time, not the mean: the metronome
            // takes its tempo from this, and a handful of long steps at a turn
            // must not slow the pace the user is later asked to walk to.
            cadenceMean: 60 / medianStepTime,
            // CV is computed inside each window, where it means short-term
            // variability, then summarised across windows by median.
            stepTimeCV: median(windows.compactMap(coefficientOfVariation)) ?? 0,
            trunkMotionML: trunkML,
            trunkMotionVT: trunkVT,
            stepTimeAsymmetry: asymmetry.value,
            steps: buffer.pedometerEvents.map(\.steps).max(),
            distance: buffer.pedometerEvents.compactMap(\.distance).max(),
            validStrideCount: features.strideCount,
            windowCount: windows.count,
            observedStepPeriod: median(windows.map(\.stepLag)),
            observedStrideLag: median(windows.map(\.strideLag)),
            asymmetryAffectedSide: asymmetry.side
        )
    }

    // MARK: - Asymmetry [PRD §7, OQ-1]

    /// The secondary sound-vs-prosthetic feature, or absence.
    ///
    /// **Absence is a result, not a gap.** For bilateral users, for sessions
    /// with no profile, and for walks whose autocorrelation peaks are not
    /// prominent enough to contrast, the answer is nil. Zero would claim perfect
    /// symmetry was measured, which is exactly the fabrication [PRD §7] forbids.
    ///
    /// Formula per docs/decisions.md entry 2: `(P1 − P2) / (P1 + P2)` over the
    /// two half-stride autocorrelation peaks — P1 at one half-stride (the step
    /// lag) and P2 at two (the stride lag). Symmetric gait repeats equally well
    /// over a step and a stride, giving zero; an asymmetric gait repeats better
    /// over the full stride, giving a negative value whose magnitude grows with
    /// the asymmetry.
    static func stepTimeAsymmetry(
        windows: [WindowFeatures],
        profile: UserProfile?,
        configuration: AlgorithmConfiguration
    ) -> (value: Double?, side: AmputationSide?) {
        let policy = configuration.asymmetry

        // Unilateral profiles only. Never fabricated for bilateral users.
        guard let profile, !policy.requiresUnilateralProfile || profile.supportsStepTimeAsymmetry else {
            return (nil, nil)
        }

        let perWindow = windows.compactMap { window -> Double? in
            let p1 = window.ad1
            let p2 = window.ad2
            if policy.requiresBothPeaksProminent {
                guard p1 >= policy.minimumPeakProminence,
                      p2 >= policy.minimumPeakProminence else { return nil }
            }
            let total = p1 + p2
            guard total > 0 else { return nil }
            return (p1 - p2) / total
        }

        // Not enough clean windows to contrast: absence, not zero.
        guard let value = median(perWindow) else { return (nil, nil) }

        // The label comes from the profile, never from guessing at the signal.
        return (value, policy.sideFromProfile ? profile.side : nil)
    }

    // MARK: - Statistics

    /// Coefficient of variation of one window's step times.
    ///
    /// Nil for a window with too few steps to have a spread — one step time has
    /// no variability, and reporting zero would say it was perfectly even.
    static func coefficientOfVariation(_ window: WindowFeatures) -> Double? {
        let times = window.stepTimes
        guard times.count >= 2 else { return nil }

        let mean = times.reduce(0, +) / Double(times.count)
        guard mean > 0 else { return nil }

        let variance = times.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(times.count)
        return variance.squareRoot() / mean
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        // Even counts average the two central values, so a two-window session
        // is not silently biased toward the later one.
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
