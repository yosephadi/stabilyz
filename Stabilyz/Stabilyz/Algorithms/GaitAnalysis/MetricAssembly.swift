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

        // Cadence comes from the stride period, not from step times.
        //
        // A stride contains exactly two steps by definition, so this is
        // parity-free. Pooling step times and taking their median is not: when
        // step durations alternate — which is the asymmetric gait this app
        // exists to measure — the pooled median lands on the shorter duration,
        // the longer one, or their average depending only on how many steps
        // happened to be detected. A golden case caught it reporting 120 spm
        // for a walk that is analytically 109.09 (docs/decisions.md entry 14).
        guard let medianStrideLag = median(windows.map(\.strideLag)), medianStrideLag > 0 else { return nil }

        let asymmetry = stepTimeAsymmetry(
            windows: windows,
            profile: profile,
            configuration: configuration
        )

        return GaitMetrics(
            stepRegularity: ad1,
            strideRegularity: ad2,
            // Two steps per stride. The metronome takes its tempo from this,
            // so it has to be right for asymmetric walkers too.
            cadenceMean: 120 / medianStrideLag,
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

    /// Why a session carries no asymmetry value.
    ///
    /// Absence is a result with a cause, not a blank. The cause is recorded so
    /// the clinician summary can say *why* rather than showing nothing.
    enum AsymmetryUnavailability: String, Sendable, Equatable {
        /// Bilateral amputation: there is no sound side to compare against.
        case bilateralProfile
        /// No profile was available for the session.
        case noProfile
        /// The walk was not periodic enough for the half-stride peak positions
        /// to mean anything.
        case peaksNotProminent
        /// Mediolateral polarity did not alternate consistently across
        /// footfalls, so the two half-cycles are not distinguishable limbs —
        /// the provisional reading of "side reliably identifiable".
        case sideNotReliablyIdentifiable
    }

    struct AsymmetryResult: Sendable, Equatable {
        let value: Double?
        /// Profile side, carried as **context only** — not an attribution of the
        /// measurement to a limb (docs/decisions.md entry 13).
        let side: AmputationSide?
        let unavailability: AsymmetryUnavailability?
    }

    /// Step-time asymmetry: `(τ2 − τ1) / (τ1 + τ2)` over the positions of the
    /// two autocorrelation peaks flanking the nominal half-stride, τ1 < τ2.
    ///
    /// This is a **timing** comparison, which is what [PRD OQ-1] reserves the
    /// name "step time asymmetry" for, and it is measured independently of the
    /// regularity metrics rather than derived from them
    /// (docs/decisions.md entry 13).
    ///
    /// The result is non-negative by construction: τ2 is the longer half-cycle.
    /// It says how unequal the two step durations are, **not which limb is
    /// which** — see entry 13 for why absolute limb attribution is not currently
    /// possible.
    ///
    /// **Absence is a result, not a gap.** Bilateral users, sessions without a
    /// profile, walks whose peaks are not prominent, and walks whose
    /// mediolateral polarity does not alternate all yield nil with a reason.
    /// Zero would claim equal step durations were measured [PRD §7].
    static func stepTimeAsymmetry(
        windows: [WindowFeatures],
        profile: UserProfile?,
        configuration: AlgorithmConfiguration
    ) -> AsymmetryResult {
        let policy = configuration.asymmetry

        guard let profile else {
            return AsymmetryResult(value: nil, side: nil, unavailability: .noProfile)
        }
        // Never fabricated for bilateral users [PRD §7, OQ-1].
        if policy.requiresUnilateralProfile && !profile.supportsStepTimeAsymmetry {
            return AsymmetryResult(value: nil, side: nil, unavailability: .bilateralProfile)
        }

        let side = policy.sideFromProfile ? profile.side : nil

        // "Side reliably identifiable", provisionally: consecutive footfalls
        // lean opposite ways, so the two half-cycles belong to limbs that can be
        // told apart at all.
        let alternating = windows.filter(\.mediolateralPolarityAlternates)
        guard !alternating.isEmpty else {
            return AsymmetryResult(value: nil, side: side, unavailability: .sideNotReliablyIdentifiable)
        }

        let perWindow = alternating.compactMap { window -> Double? in
            guard let first = window.firstHalfStrideLag,
                  let second = window.secondHalfStrideLag else { return nil }
            let total = first + second
            guard total > 0 else { return nil }
            // An unsplit peak gives first == second, so this is exactly zero:
            // symmetric step timing, measured.
            return (second - first) / total
        }

        guard let value = median(perWindow) else {
            return AsymmetryResult(value: nil, side: side, unavailability: .peaksNotProminent)
        }
        return AsymmetryResult(value: value, side: side, unavailability: nil)
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
