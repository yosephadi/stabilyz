import Foundation

/// A stretch of steady-state walking (docs/08 stage 3).
///
/// Indices address the owning `PreprocessedSegment`; timestamps stay on the
/// untouched session timeline so findings can be placed against the gap record
/// and the pedometer.
struct WalkingInterval: Sendable, Equatable {
    /// Index into `PreprocessedSeries.segments`.
    let segmentIndex: Int
    /// First sample of the interval, within that segment.
    let startIndex: Int
    /// One past the last sample.
    let endIndex: Int
    let startTimestamp: TimeInterval
    let sampleRateHz: Double

    var count: Int { endIndex - startIndex }
    var duration: Duration { .seconds(Double(count) / sampleRateHz) }
    var endTimestamp: TimeInterval { startTimestamp + Double(count) / sampleRateHz }
}

/// Whether the pedometer's view lines up with what the accelerometer found.
///
/// Recorded, never enforced. The accelerometer is the measurement; the pedometer
/// is a cross-check hint (docs/08 stage 3). Disagreement is information about the
/// session, not an error — a pocket carry can under-count steps while the trunk
/// signal is perfectly good.
struct PedometerAgreement: Sendable, Equatable {
    let pedometerSteps: Int
    /// Steps per minute the pedometer implies over the walking that was found.
    let impliedCadence: Double
    /// Whether that cadence is physically plausible for walking.
    let isPlausible: Bool
    /// The pedometer counted steps where no walking was detected, or vice versa.
    let disagreesOnWalkingPresence: Bool
}

/// The output of pipeline stage 3.
struct WalkingSegmentation: Sendable, Equatable {
    let intervals: [WalkingInterval]
    /// What counts toward the mode minimum [PRD OQ-3]. Pauses, standing and
    /// setup time are excluded and never counted.
    let walkingDuration: Duration
    /// Clean signal that was not walking — standing, pausing, setup.
    let excludedDuration: Duration
    /// Trimmed from bout ends as gait initiation and termination [PRD OQ-1].
    let transientDuration: Duration
    /// Bouts dropped for being too short once trimmed.
    let discardedBoutCount: Int
    /// Carried forward from stage 2, so the quality view sees the whole picture
    /// of how fragmented a session was.
    let discardedSegmentCount: Int
    let pedometerAgreement: PedometerAgreement?

    /// docs/08 stage 3: zero walking intervals is a failure condition.
    var foundNoWalking: Bool { intervals.isEmpty }
}

/// Pipeline stage 3: finds the steady-state walking in a session (docs/08).
///
/// Pure. The accelerometer decides; pedometer data only annotates the result.
enum WalkingSegmentDetector {
    static func detect(
        in series: PreprocessedSeries,
        pedometerEvents: [PedometerEvent] = [],
        configuration: AlgorithmConfiguration
    ) -> WalkingSegmentation {
        let policy = configuration.walkingDetection
        let rate = series.sampleRateHz

        var intervals: [WalkingInterval] = []
        var discardedBouts = 0
        var transientSamples = 0
        var totalSamples = 0

        for (segmentIndex, segment) in series.segments.enumerated() {
            totalSamples += segment.count

            let activity = movingRMS(segment.vertical, window: samples(of: policy.activityWindow, at: rate))
            let bouts = bridge(
                runs(where: activity.map { $0 >= policy.verticalRMSThreshold }),
                maximumSeparation: samples(of: policy.maximumBridgedPause, at: rate)
            )

            for bout in bouts {
                // Gait initiation and termination are not steady-state gait.
                let leading = samples(of: policy.initiationTrim, at: rate)
                let trailing = samples(of: policy.terminationTrim, at: rate)
                let start = bout.lowerBound + leading
                let end = bout.upperBound - trailing

                guard start < end else {
                    // The whole bout was transient.
                    transientSamples += bout.count
                    discardedBouts += 1
                    continue
                }

                let trimmed = start..<end
                guard Duration.seconds(Double(trimmed.count) / rate) >= policy.minimumBoutDuration else {
                    transientSamples += bout.count - trimmed.count
                    discardedBouts += 1
                    continue
                }

                transientSamples += bout.count - trimmed.count
                intervals.append(
                    WalkingInterval(
                        segmentIndex: segmentIndex,
                        startIndex: trimmed.lowerBound,
                        endIndex: trimmed.upperBound,
                        startTimestamp: segment.timestamp(at: trimmed.lowerBound),
                        sampleRateHz: rate
                    )
                )
            }
        }

        let walkingSamples = intervals.reduce(0) { $0 + $1.count }
        let walkingDuration = Duration.seconds(Double(walkingSamples) / rate)

        return WalkingSegmentation(
            intervals: intervals,
            walkingDuration: walkingDuration,
            excludedDuration: .seconds(Double(totalSamples - walkingSamples - transientSamples) / rate),
            transientDuration: .seconds(Double(transientSamples) / rate),
            discardedBoutCount: discardedBouts,
            discardedSegmentCount: series.discardedSegmentCount,
            pedometerAgreement: agreement(
                pedometerEvents: pedometerEvents,
                walkingDuration: walkingDuration,
                configuration: configuration
            )
        )
    }

    // MARK: - Activity

    /// Centred moving RMS. Short signals return their own overall RMS rather
    /// than nothing, so a brief segment is still judged.
    static func movingRMS(_ signal: [Double], window: Int) -> [Double] {
        guard !signal.isEmpty else { return [] }
        let window = max(1, min(window, signal.count))
        let half = window / 2

        // Prefix sums of squares, so the window cost does not grow with its size.
        var prefix = [Double](repeating: 0, count: signal.count + 1)
        for (index, value) in signal.enumerated() {
            prefix[index + 1] = prefix[index] + value * value
        }

        return signal.indices.map { index in
            let start = max(0, index - half)
            let end = min(signal.count, index + half + 1)
            let sum = prefix[end] - prefix[start]
            return (sum / Double(end - start)).squareRoot()
        }
    }

    /// Contiguous ranges where the flag is true.
    static func runs(where flags: [Bool]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?

        for (index, flag) in flags.enumerated() {
            if flag, start == nil { start = index }
            if !flag, let openStart = start {
                result.append(openStart..<index)
                start = nil
            }
        }
        if let openStart = start { result.append(openStart..<flags.count) }
        return result
    }

    /// Joins runs separated by less than `maximumSeparation`.
    static func bridge(_ ranges: [Range<Int>], maximumSeparation: Int) -> [Range<Int>] {
        guard var current = ranges.first else { return [] }
        var result: [Range<Int>] = []

        for range in ranges.dropFirst() {
            if range.lowerBound - current.upperBound <= maximumSeparation {
                current = current.lowerBound..<range.upperBound
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }

    // MARK: - Pedometer cross-check

    /// Annotates the result with whether the pedometer agrees. Never overrides.
    private static func agreement(
        pedometerEvents: [PedometerEvent],
        walkingDuration: Duration,
        configuration: AlgorithmConfiguration
    ) -> PedometerAgreement? {
        guard let steps = pedometerEvents.map(\.steps).max() else { return nil }

        let minutes = Double(walkingDuration.components.seconds) / 60
            + Double(walkingDuration.components.attoseconds) / 60e18
        let impliedCadence = minutes > 0 ? Double(steps) / minutes : 0

        // Steps counted but nothing detected, or walking detected with no steps
        // counted: worth recording either way.
        let disagrees = (steps > 0 && walkingDuration == .zero)
            || (steps == 0 && walkingDuration > .zero)

        return PedometerAgreement(
            pedometerSteps: steps,
            impliedCadence: impliedCadence,
            isPlausible: configuration.walkingDetection.plausibleCadenceRange.contains(impliedCadence),
            disagreesOnWalkingPresence: disagrees
        )
    }

    private static func samples(of duration: Duration, at rate: Double) -> Int {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return Int((seconds * rate).rounded())
    }
}
