/// Stable identifiers for the metrics that can be standardized against a
/// baseline (docs/05 §5.1).
///
/// Raw values are persisted inside `BaselineMetricStat` and `MetricBreakdown`
/// blobs, so **these strings must not change**.
///
/// Internal naming follows [PRD OQ-1]: *step regularity* / *stride regularity*
/// for the autocorrelation outputs. User-facing copy calls those
/// **gait consistency** and must never call them "symmetry" or "asymmetry" —
/// that term is reserved for `stepTimeAsymmetry`, the unilateral step-time
/// comparison.
enum MetricID: String, Sendable, CaseIterable, Codable {
    /// Ad1 — autocorrelation-derived step regularity. Computed identically for
    /// every user regardless of amputation type [PRD OQ-1].
    case stepRegularity
    /// Ad2 — autocorrelation-derived stride regularity [PRD OQ-1].
    case strideRegularity
    /// Cadence over valid walking, steps/min. Also the metronome source.
    ///
    /// Computed as `60 / median` step time, not the arithmetic mean: the
    /// metronome takes its tempo from this, and a few long steps at a turn must
    /// not slow the pace the user is later asked to walk to. The name is the
    /// docs/05 §5.1 field name and is unchanged (docs/decisions.md entry 12).
    case cadenceMean
    /// Step-time/cadence variability — an independent signal, never derived
    /// from the regularity metrics [PRD §7].
    case stepTimeCV
    /// Mediolateral component of the trunk-motion proxy.
    case trunkMotionML
    /// Vertical component of the trunk-motion proxy.
    case trunkMotionVT
    /// Sound-vs-prosthetic step-time asymmetry — secondary, unilateral only,
    /// and never merged into the composite as a hidden term [PRD §7, OQ-1].
    case stepTimeAsymmetry

    /// Whether a higher raw value is a better result.
    ///
    /// [OPEN] The sign convention per metric is part of the unwritten algorithm
    /// spec (docs/05 §5.1, docs/08 §8.2). It is deliberately **not** resolved
    /// here. The data model carries direction; the values are supplied by the
    /// versioned `AlgorithmConfiguration` (Task 5.1.2) via `MetricDirections`.
    enum Direction: String, Sendable, CaseIterable, Codable {
        case higherIsBetter
        case lowerIsBetter
    }
}

/// The per-metric sign convention, supplied by configuration rather than baked
/// into the model.
///
/// **[OPEN — do not add a default.]** docs/05 §5.1 and docs/08 §8.2 both flag the
/// sign convention as unresolved. Shipping a "provisional" default here would
/// silently resolve it and could invert a metric's contribution to the score
/// without anyone noticing. Task 5.1.2 supplies the real mapping; until then
/// callers must state one explicitly.
struct MetricDirections: Sendable, Equatable {
    private let directions: [MetricID: MetricID.Direction]

    init(_ directions: [MetricID: MetricID.Direction]) {
        self.directions = directions
    }

    /// Nil when this configuration does not standardize that metric.
    func direction(for metric: MetricID) -> MetricID.Direction? {
        directions[metric]
    }

    var standardizedMetrics: Set<MetricID> { Set(directions.keys) }
}
