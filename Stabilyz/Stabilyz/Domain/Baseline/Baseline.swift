import Foundation

/// A mode's personal reference, established once and frozen (docs/05 §5.1,
/// docs/09 §9.1).
///
/// `mode` is PRD-locked onto this type [PRD OQ-5]: a Quick Test result is only
/// ever compared against the Quick Test baseline. Uniqueness per mode is
/// enforced at the store and repository level (docs/09 §9.7).
///
/// Deliberately **not** `Codable`: synthesized decoding would bypass the
/// initializer's invariant check. Export DTOs (Task 10.1.3) convert explicitly.
struct Baseline: Sendable, Equatable, Identifiable {
    /// Valid same-mode sessions required before a baseline is established
    /// [PRD OQ-5 — locked in].
    static let requiredValidSessionCount = 5

    /// What an established baseline scores, by construction [PRD §7].
    ///
    /// Every relative index is read against this: a session at 112 is 12 above
    /// the user's own normal, not 12% better at anything. Named here rather
    /// than typed into the screens that show it, so the reference point and the
    /// scoring that produces it cannot drift apart.
    static let referenceIndex = 100

    enum ValidationError: Error, Equatable {
        /// A baseline must be derived from exactly five valid same-mode sessions.
        case wrongSourceSessionCount(expected: Int, actual: Int)
        /// The five source sessions must be distinct.
        case duplicateSourceSessions
    }

    let id: UUID
    let mode: TestMode
    /// One entry per standardizable metric. The asymmetry stat is present only
    /// for unilateral users where the feature is available [PRD §7, OQ-1].
    let stats: [BaselineMetricStat]
    /// Metronome tempo source [PRD §5]. Derived by `BaselineCalculationService`
    /// (Task 6.1.1) as the mean of the five session cadence means [REC].
    let cadenceBPM: Double
    /// A baseline is only comparable under the algorithm version that produced
    /// it (docs/09 §9.6).
    let algorithmVersion: String
    let establishedAt: Date
    /// Audit trail — exactly five, in chronological order.
    let sourceSessionIDs: [UUID]

    init(
        id: UUID,
        mode: TestMode,
        stats: [BaselineMetricStat],
        cadenceBPM: Double,
        algorithmVersion: String,
        establishedAt: Date,
        sourceSessionIDs: [UUID]
    ) throws {
        guard sourceSessionIDs.count == Self.requiredValidSessionCount else {
            throw ValidationError.wrongSourceSessionCount(
                expected: Self.requiredValidSessionCount,
                actual: sourceSessionIDs.count
            )
        }
        guard Set(sourceSessionIDs).count == sourceSessionIDs.count else {
            throw ValidationError.duplicateSourceSessions
        }

        self.id = id
        self.mode = mode
        self.stats = stats
        self.cadenceBPM = cadenceBPM
        self.algorithmVersion = algorithmVersion
        self.establishedAt = establishedAt
        self.sourceSessionIDs = sourceSessionIDs
    }

    func stat(for metric: MetricID) -> BaselineMetricStat? {
        stats.first { $0.metricID == metric }
    }

    var standardizedMetrics: Set<MetricID> { Set(stats.map(\.metricID)) }
}
