import Foundation

/// When a spacing between samples counts as a gap rather than jitter.
///
/// The multiplier is supplied by `AlgorithmConfiguration` and declared nowhere
/// else. It is applied to the **observed median interval**, not the nominal
/// sample rate: thermal throttling and background pressure make real delivery
/// slower than requested, and measuring against the nominal rate would then
/// report ordinary spacing as a stream of dropouts.
struct GapDetectionPolicy: Sendable, Equatable {
    let toleranceMultiplier: Double

    init(toleranceMultiplier: Double) {
        self.toleranceMultiplier = toleranceMultiplier
    }

    /// Spacing above which a jump counts as a gap.
    func gapThreshold(medianInterval: TimeInterval) -> TimeInterval {
        toleranceMultiplier * medianInterval
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
        policy: GapDetectionPolicy
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

        // Measure against what the sensor actually delivered.
        //
        // Below three intervals there is no median worth the name — with one
        // interval the median *is* that interval, so nothing could ever exceed
        // a multiple of itself and a lone dropout would go unreported. In that
        // case the requested rate is the only reference available.
        let intervals = zip(deduplicated, deduplicated.dropFirst())
            .map { $1.deviceTimestamp - $0.deviceTimestamp }
            .sorted()
        let medianInterval = intervals.count < 3 ? 1 / sampleRateHz : intervals[intervals.count / 2]
        let threshold = policy.gapThreshold(medianInterval: medianInterval)
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
