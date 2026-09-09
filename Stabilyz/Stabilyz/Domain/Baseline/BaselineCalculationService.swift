import Foundation

/// Builds a mode's `Baseline` from its first five valid sessions
/// (docs/09 §9.2).
///
/// A **pure domain service**: metrics in, baseline out. It has no persistence
/// knowledge, does not read a clock, and does not decide *when* a baseline
/// should be established — that is the state machine's job (Task 2.2.1) and the
/// commit flow's (Task 6.1.2).
///
/// **Create-only, structurally.** There is no update, merge or recalculate
/// entry point, and `Baseline`'s properties are all `let`. Freezing a baseline
/// in v1 [PRD §6] is therefore not a rule someone has to remember — there is no
/// API that could break it.
enum BaselineCalculationService {
    /// Why a set of sessions cannot produce a baseline.
    ///
    /// Every case is a caller bug rather than a user-facing condition. They are
    /// checked anyway: a baseline built from the wrong sessions is silently
    /// wrong forever afterwards, since every later score is measured against it
    /// and v1 never recalibrates. Same defence-in-depth stance as
    /// `SessionProcessor`'s baseline-mode check [PRD OQ-5].
    enum CalculationError: Error, Equatable {
        case wrongSessionCount(expected: Int, actual: Int)
        /// A session from another mode. The one thing [PRD OQ-5] forbids
        /// outright.
        case mixedModes(expected: TestMode, found: TestMode)
        /// An invalid session. Invalid sessions never count toward a baseline
        /// [PRD §6, §7].
        case invalidSessionIncluded(id: UUID)
        /// A valid session with no metrics — impossible through the domain
        /// constructors, so it means the data came from somewhere else.
        case missingMetrics(id: UUID)
        /// Sessions were not in chronological order. The baseline records the
        /// *first* five, so order carries meaning.
        case sessionsOutOfOrder
        case duplicateSessions
        /// Sessions computed under different algorithm versions. A baseline is
        /// only comparable under the version that produced its inputs
        /// (docs/09 §9.6).
        case mixedAlgorithmVersions
    }

    /// - Parameters:
    ///   - sessions: exactly the first five valid sessions of `mode`, oldest
    ///     first.
    ///   - establishedAt: supplied by the caller; a pure service reads no clock.
    static func calculate(
        from sessions: [GaitSession],
        mode: TestMode,
        establishedAt: Date,
        id: UUID = UUID(),
        configuration: AlgorithmConfiguration
    ) throws -> Baseline {
        try validate(sessions, mode: mode)

        // Safe after validation: every session is valid and carries metrics.
        let metrics = sessions.compactMap(\.metrics)
        let stats = try statistics(for: metrics, configuration: configuration)

        return try Baseline(
            id: id,
            mode: mode,
            stats: stats,
            // docs/09 §9.2 [REC]: the mean of the five session cadence values.
            // An arithmetic mean is right here where a median was right within a
            // session — these five are already robust per-session summaries
            // (docs/decisions.md entry 14), so there are no outlier samples left
            // to defend against, and five values have no stable median anyway.
            cadenceBPM: mean(metrics.map(\.cadenceMean)),
            // Stamped from the sessions, not from the current configuration: a
            // baseline is only comparable under the version that produced its
            // inputs (docs/09 §9.6).
            algorithmVersion: sessions[0].algorithmVersion,
            establishedAt: establishedAt,
            sourceSessionIDs: sessions.map(\.id)
        )
    }

    // MARK: - Validation

    private static func validate(_ sessions: [GaitSession], mode: TestMode) throws {
        guard sessions.count == Baseline.requiredValidSessionCount else {
            throw CalculationError.wrongSessionCount(
                expected: Baseline.requiredValidSessionCount,
                actual: sessions.count
            )
        }

        for session in sessions {
            guard session.mode == mode else {
                throw CalculationError.mixedModes(expected: mode, found: session.mode)
            }
            guard session.isValid else {
                throw CalculationError.invalidSessionIncluded(id: session.id)
            }
            guard session.metrics != nil else {
                throw CalculationError.missingMetrics(id: session.id)
            }
        }

        guard Set(sessions.map(\.id)).count == sessions.count else {
            throw CalculationError.duplicateSessions
        }
        guard zip(sessions, sessions.dropFirst()).allSatisfy({ $0.startedAt < $1.startedAt }) else {
            throw CalculationError.sessionsOutOfOrder
        }
        guard Set(sessions.map(\.algorithmVersion)).count == 1 else {
            throw CalculationError.mixedAlgorithmVersions
        }
    }

    // MARK: - Statistics

    /// One stat per registry metric the sessions actually carry.
    static func statistics(
        for metrics: [GaitMetrics],
        configuration: AlgorithmConfiguration
    ) throws -> [BaselineMetricStat] {
        MetricID.allCases.compactMap { metric in
            let values = metrics.compactMap { $0.value(for: metric) }

            // Asymmetry is the only metric that can legitimately be missing from
            // some sessions: a walk whose peaks were not clean enough, or whose
            // mediolateral polarity did not alternate, reports absence rather
            // than a number (docs/decisions.md entry 13).
            //
            // PROVISIONAL: at least three of the five must carry it. Fewer is
            // too thin a sample to describe a user's normal asymmetry, and a
            // stat computed from one or two sessions would look identical to a
            // well-supported one at every later comparison. `n` records how many
            // actually contributed, so the thinness is visible rather than
            // implied. Below the minimum the stat is **absent** — not zero, and
            // not a mean of whatever happened to be there.
            if metric == .stepTimeAsymmetry {
                guard values.count >= configuration.baseline.minimumAsymmetrySessions else { return nil }
            } else {
                // Every other metric is present in every valid session.
                guard values.count == metrics.count, !values.isEmpty else { return nil }
            }

            return stat(for: metric, values: values, configuration: configuration)
        }
    }

    private static func stat(
        for metric: MetricID,
        values: [Double],
        configuration: AlgorithmConfiguration
    ) -> BaselineMetricStat {
        let average = mean(values)
        let observed = sampleStandardDeviation(values, mean: average)

        // The floor is applied **here**, once, and the floored value is what the
        // baseline stores — see docs/decisions.md entry 16 for why not at
        // scoring time.
        let floored = configuration.normalization.flooredSD(
            for: metric,
            observedSD: observed,
            baselineMean: average
        )

        return BaselineMetricStat(
            metricID: metric,
            mean: average,
            sd: floored,
            n: values.count,
            sdFloorApplied: floored > observed
        )
    }

    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Sample standard deviation, dividing by `n − 1`.
    ///
    /// These five sessions are a *sample* of how this user walks, not the whole
    /// of it. The Bessel-corrected estimator is the unbiased one for the
    /// underlying spread, and with n = 5 the difference from the population form
    /// is large — about 12% — so the choice materially changes every later
    /// z-score.
    static func sampleStandardDeviation(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let sumOfSquares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sumOfSquares / Double(values.count - 1)).squareRoot()
    }
}
