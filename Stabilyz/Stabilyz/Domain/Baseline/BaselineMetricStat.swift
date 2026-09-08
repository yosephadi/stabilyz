/// Per-metric baseline statistics (docs/05 §5.1, docs/09 §9.1).
///
/// Persisted as part of the `BaselineEntity` JSON blob (docs/05 §5.2).
nonisolated struct BaselineMetricStat: Sendable, Equatable, Codable {
    let metricID: MetricID
    let mean: Double
    /// Standard deviation, after the minimum-SD floor has been considered.
    let sd: Double
    /// Number of sessions the statistic was computed from.
    let n: Int
    /// Whether the minimum-SD floor replaced the observed SD.
    ///
    /// The floor itself is **PRD-required** [PRD §7 AC] — it stops a metric that
    /// happened to be near-identical across the five calibration sessions from
    /// exploding later z-scores. The floor *value* is [OPEN] and comes from the
    /// versioned `AlgorithmConfiguration` (Task 5.1.2), not from this type.
    let sdFloorApplied: Bool

    init(metricID: MetricID, mean: Double, sd: Double, n: Int, sdFloorApplied: Bool) {
        self.metricID = metricID
        self.mean = mean
        self.sd = sd
        self.n = n
        self.sdFloorApplied = sdFloorApplied
    }
}
