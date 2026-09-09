import Foundation

/// When a spacing between samples counts as a gap rather than jitter.
///
/// [REC — tunable, not a PRD value.] Sensor delivery jitters by a fraction of
/// the sample interval under normal load, so a small multiple avoids counting
/// ordinary scheduling noise as a dropout. `toleranceMultiplier` of 3 means a
/// gap is only recorded once at least two consecutive samples are missing.
///
/// The real value must be validated on device against thermal throttling and
/// backgrounding behaviour (docs/21); it moves into the versioned
/// `AlgorithmConfiguration` in Task 5.1.2.
struct GapDetectionPolicy: Sendable, Equatable {
    let toleranceMultiplier: Double

    init(toleranceMultiplier: Double) {
        self.toleranceMultiplier = toleranceMultiplier
    }

    static let recommendedDefault = GapDetectionPolicy(toleranceMultiplier: 3)

    /// Spacing above which a jump counts as a gap, for a given sample rate.
    func gapThreshold(sampleRateHz: Double) -> TimeInterval {
        toleranceMultiplier / sampleRateHz
    }
}

/// Pipeline stage 1: ingestion and synchronisation (docs/08).
///
/// De-duplicates, orders, and exposes gap intervals. Pure — it is the recorder
/// that calls this, but none of the logic depends on CoreMotion.
///
/// It deliberately does **not** interpolate across a gap. Manufacturing samples
/// would let a suspended session look like clean walking, which is exactly what
/// [PRD §6] forbids: "must not silently produce a corrupted clean score".
enum SampleIngestion {
    /// - Parameter sampleRateHz: the acquisition rate the samples were
    ///   requested at, which sets the expected spacing.
    static func align(
        _ samples: [SensorSample],
        sampleRateHz: Double,
        policy: GapDetectionPolicy = .recommendedDefault
    ) -> AlignedSampleSeries {
        guard !samples.isEmpty else {
            return AlignedSampleSeries(samples: [], gaps: [])
        }

        // Order first: a late delivery must not read as a backwards jump.
        let ordered = samples.sorted { $0.deviceTimestamp < $1.deviceTimestamp }

        // De-duplicate on timestamp. A repeated timestamp is a redelivery, not
        // a second measurement.
        var deduplicated: [SensorSample] = []
        deduplicated.reserveCapacity(ordered.count)
        for sample in ordered where deduplicated.last?.deviceTimestamp != sample.deviceTimestamp {
            deduplicated.append(sample)
        }

        let threshold = policy.gapThreshold(sampleRateHz: sampleRateHz)
        var gaps: [SensorGap] = []
        for (previous, current) in zip(deduplicated, deduplicated.dropFirst())
        where current.deviceTimestamp - previous.deviceTimestamp > threshold {
            gaps.append(SensorGap(start: previous.deviceTimestamp, end: current.deviceTimestamp))
        }

        return AlignedSampleSeries(samples: deduplicated, gaps: gaps)
    }

    /// Places pedometer events on the device timebase so both streams share one
    /// timeline (docs/07 §7.4, docs/08 stage 1).
    static func deviceTimestamps(
        for events: [PedometerEvent],
        anchor: TimeAnchor
    ) -> [(event: PedometerEvent, deviceTimestamp: TimeInterval)] {
        events
            .map { ($0, anchor.deviceTimestamp(forWallClock: $0.timestamp)) }
            .sorted { $0.1 < $1.1 }
    }
}
