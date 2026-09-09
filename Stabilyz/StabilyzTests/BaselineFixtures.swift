import Foundation
@testable import Stabilyz

extension Baseline {
    /// A well-formed baseline for tests that do not care about the statistics.
    static func fixture(
        mode: TestMode = .quickTest,
        id: UUID = UUID(),
        cadenceBPM: Double = 104,
        algorithmVersion: String = "1.0.0",
        establishedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        stats: [BaselineMetricStat] = [
            BaselineMetricStat(metricID: .stepRegularity, mean: 0.80, sd: 0.05, n: 5, sdFloorApplied: false),
            BaselineMetricStat(metricID: .stepTimeCV, mean: 0.04, sd: 0.01, n: 5, sdFloorApplied: true)
        ]
    ) -> Baseline {
        // The fixture is fixed and valid, so a throw here is a programming error.
        try! Baseline(
            id: id,
            mode: mode,
            stats: stats,
            cadenceBPM: cadenceBPM,
            algorithmVersion: algorithmVersion,
            establishedAt: establishedAt,
            sourceSessionIDs: (0..<Baseline.requiredValidSessionCount).map { _ in UUID() }
        )
    }
}

extension MetronomeCue {
    /// A cue for tests, built through the real gate rather than around it.
    ///
    /// There is deliberately no way to make one from a bare BPM, here or
    /// anywhere else: a cue requires that mode's established baseline, which is
    /// the whole point of the type (docs/audits/epic-7.md finding 3).
    static func fixture(bpm: Double = 104, mode: TestMode = .quickTest) -> MetronomeCue {
        // The fixture baseline is valid and same-mode, so nil is a programming
        // error rather than a case to handle.
        MetronomeCue(baseline: .fixture(mode: mode, cadenceBPM: bpm), mode: mode)!
    }
}
