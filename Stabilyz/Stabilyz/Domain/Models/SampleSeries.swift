import Foundation

// Pure value types on the boundary between the recorder and the pipeline.
// They live in Domain because the `GaitScoringAlgorithm` contract names them,
// and docs/03 forbids Domain depending on any Service.

/// A stretch of time where the sensor delivered nothing (docs/07 §7.7).
struct SensorGap: Sendable, Equatable {
    /// Device timestamp of the last sample before the gap.
    let start: TimeInterval
    /// Device timestamp of the first sample after the gap.
    let end: TimeInterval

    var duration: Duration { .seconds(end - start) }

    init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// The output of pipeline stage 1 — a time-aligned sample series with the gaps
/// made explicit (docs/08 stage 1).
struct AlignedSampleSeries: Sendable, Equatable {
    /// Ordered by device timestamp, duplicates removed.
    let samples: [SensorSample]
    let gaps: [SensorGap]

    /// Wall-clock span from first to last sample, gaps included. This is
    /// elapsed clock time, not the walking that counted.
    var recordedSpan: Duration {
        guard let first = samples.first, let last = samples.last else { return .zero }
        return .seconds(last.deviceTimestamp - first.deviceTimestamp)
    }

    /// Span with gap time removed — the time the sensor was actually
    /// delivering. Still not "valid walking": stages 3 and 4 decide that.
    var coveredDuration: Duration {
        gaps.reduce(recordedSpan) { $0 - $1.duration }
    }

    /// Rolled up for the session record (docs/05 §5.1).
    var gapInfo: SessionGapInfo {
        SessionGapInfo(
            gapCount: gaps.count,
            totalGapDuration: gaps.reduce(Duration.zero) { $0 + $1.duration },
            longestGapDuration: gaps.map(\.duration).max() ?? .zero
        )
    }
}
