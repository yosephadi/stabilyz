import Foundation

/// One metric standardized against its baseline stat (docs/08 stage 7).
///
/// Carries the ingredients Task 6.2.2's composite and the `MetricBreakdown`
/// behind the Score screen's tap-to-expand both need: the raw value the user
/// produced, what their own normal is, the spread it is judged against, and the
/// standardized result.
struct MetricStandardization: Sendable, Equatable {
    let metricID: MetricID
    /// What this session measured.
    let rawValue: Double
    /// The user's own normal for this metric, from the frozen baseline.
    let baselineMean: Double
    /// The **stored, already-floored** SD (docs/decisions.md entry 16). Divided
    /// by directly; the floor is never re-applied here.
    let baselineSD: Double
    /// Whether that SD was raised by the floor when the baseline was built.
    /// Carried through so a breakdown can say the comparison rests on a
    /// floored spread rather than an observed one.
    let sdFloorApplied: Bool
    /// `(raw − mean) / sd`. Signed by the metric's natural direction, not by
    /// better or worse.
    let z: Double
    /// The configured sign convention, or nil for a metric with none.
    let direction: MetricID.Direction?
    /// `z` oriented so that positive is better.
    ///
    /// **Nil for metrics with no decided direction** — cadence and asymmetry
    /// (docs/decisions.md entry 3). They get a plain deviation and no
    /// better/worse reading; asserting one would let the UI label a faster
    /// cadence an improvement on a judgement nobody has made.
    let directionAdjustedZ: Double?
}

/// A metric this session measured that the baseline has no stat for.
///
/// Shown raw, never standardized. The usual cause is the asymmetry stat failing
/// the three-of-five rule (docs/decisions.md entry 16) while this session did
/// produce a value.
struct RawOnlyMetric: Sendable, Equatable {
    let metricID: MetricID
    let rawValue: Double
}

/// The output of pipeline stage 7.
struct SessionStandardization: Sendable, Equatable {
    let mode: TestMode
    /// The version the baseline was built under; a comparison is only valid
    /// within one version (docs/09 §9.6).
    let algorithmVersion: String
    let standardized: [MetricStandardization]
    /// Measured, but with no baseline stat to compare against.
    let rawOnly: [RawOnlyMetric]
    /// The baseline has a stat, but this session did not measure the metric —
    /// asymmetry whose reliability gate failed (entry 13). Recorded so a
    /// breakdown can show absence rather than silently omitting a row.
    let unmeasured: [MetricID]

    func standardization(for metric: MetricID) -> MetricStandardization? {
        standardized.first { $0.metricID == metric }
    }
}

/// Pipeline stage 7: baseline normalization (docs/08, docs/09 §9.5).
///
/// Pure. Compares a session against **the baseline it is handed** — there is no
/// lookup here and therefore no way to reach the wrong mode's baseline. The mode
/// is passed explicitly and checked anyway, as defence in depth behind
/// `SessionProcessor`'s own refusal [PRD OQ-5].
enum BaselineNormalization {
    /// - Parameter baseline: the same mode's baseline, or nil.
    /// - Returns: nil before a baseline exists. Pre-baseline sessions are shown
    ///   as raw metrics, "reference only" [PRD §5] — there is nothing to
    ///   standardize against, and inventing a comparison would be worse than
    ///   showing none.
    static func standardize(
        metrics: GaitMetrics,
        mode: TestMode,
        against baseline: Baseline?,
        configuration: AlgorithmConfiguration
    ) throws -> SessionStandardization? {
        guard let baseline else { return nil }
        guard baseline.mode == mode else {
            throw StabilyzError.processing(.baselineModeMismatch)
        }

        var standardized: [MetricStandardization] = []
        var rawOnly: [RawOnlyMetric] = []
        var unmeasured: [MetricID] = []

        for metric in MetricID.allCases {
            let measured = metrics.value(for: metric)
            let stat = baseline.stat(for: metric)

            switch (measured, stat) {
            case (nil, .some):
                // The baseline knows this metric; this session did not measure
                // it. Absence, never zero (entry 13).
                unmeasured.append(metric)

            case (.some(let value), nil):
                // Measured, but the baseline has no stat to compare against.
                rawOnly.append(RawOnlyMetric(metricID: metric, rawValue: value))

            case (.some(let value), .some(let stat)):
                // A zero or negative spread cannot divide. The floor should make
                // this unreachable; showing the value raw beats producing an
                // infinity.
                guard stat.sd > 0 else {
                    rawOnly.append(RawOnlyMetric(metricID: metric, rawValue: value))
                    continue
                }

                let z = (value - stat.mean) / stat.sd
                let direction = configuration.metricDirections.direction(for: metric)

                standardized.append(
                    MetricStandardization(
                        metricID: metric,
                        rawValue: value,
                        baselineMean: stat.mean,
                        baselineSD: stat.sd,
                        sdFloorApplied: stat.sdFloorApplied,
                        z: z,
                        direction: direction,
                        directionAdjustedZ: direction.map { adjust(z, for: $0) }
                    )
                )

            case (nil, nil):
                continue
            }
        }

        return SessionStandardization(
            mode: mode,
            algorithmVersion: baseline.algorithmVersion,
            standardized: standardized,
            rawOnly: rawOnly,
            unmeasured: unmeasured
        )
    }

    /// Orients a z-score so positive is better.
    ///
    /// Only ever called for a metric that has a decided direction, so this
    /// cannot silently assign a meaning to cadence or asymmetry.
    static func adjust(_ z: Double, for direction: MetricID.Direction) -> Double {
        switch direction {
        case .higherIsBetter: z
        case .lowerIsBetter: -z
        }
    }
}
