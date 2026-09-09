import Foundation

/// Everything behind a validity verdict (docs/08 stage 4).
///
/// The noisy screen has to explain itself in plain language [PRD §5], so the
/// report carries the evidence, not just the conclusion: how much walking there
/// was against how much was needed, how noisy it was against the limit, how
/// fragmented the session was, and what the pedometer made of it.
///
/// **No verdict without its explanation behind it.**
struct SessionQualityReport: Sendable, Equatable {
    let mode: TestMode

    // Walking against the requirement [PRD OQ-3]
    /// Steady-state walking found, excluding pauses, standing and setup.
    let validWalkingDuration: Duration
    /// What this mode needs.
    let requiredWalkingDuration: Duration

    // Noise, measured before cleaning (docs/decisions.md entry 8)
    /// Share of signal power above the noise cutoff.
    let highFrequencyPowerRatio: Double
    /// The limit it was judged against.
    let noiseThreshold: Double

    // How fragmented the session was
    let gapInfo: SessionGapInfo
    /// Fragments too short to preprocess (stage 2).
    let discardedSegmentCount: Int
    /// Bouts too short to measure once transients were trimmed (stage 3).
    let discardedBoutCount: Int
    /// Clean signal that was not walking.
    let excludedDuration: Duration
    /// Trimmed as gait initiation and termination.
    let transientDuration: Duration
    let walkingIntervalCount: Int
    let interruptionCount: Int

    // Diagnostics
    /// Dominant frequency of each walking interval, in Hz.
    ///
    /// Recorded, never a gate. Entry 9 defers spectral walking validation; this
    /// is the evidence Phase 12 needs to decide whether that revisit ever
    /// happens — a session of vehicle vibration and a session of walking look
    /// different here even when both clear the amplitude threshold.
    let dominantFrequencies: [Double]
    /// Cross-check context, never authority (docs/08 stage 3).
    let pedometerAgreement: PedometerAgreement?
    /// False when the pedometer cross-check was unavailable for this session.
    let pedometerAvailable: Bool

    /// Nil when the session passes.
    let invalidReason: InvalidReason?

    var isValid: Bool { invalidReason == nil }

    /// How short the session fell, when it fell short. Zero otherwise.
    var walkingShortfall: Duration {
        validWalkingDuration < requiredWalkingDuration
            ? requiredWalkingDuration - validWalkingDuration
            : .zero
    }

    /// Whether the noise limit was exceeded, independently of which reason was
    /// reported. Both facts are available even when only one is the verdict.
    var exceededNoiseLimit: Bool { highFrequencyPowerRatio > noiseThreshold }

    /// Whether any walking was found at all — docs/08 stage 3's failure case.
    var foundNoWalking: Bool { walkingIntervalCount == 0 }
}

/// Pipeline stage 4: the go/no-go gate before a session can be scored
/// (docs/08).
///
/// Invalid sessions are **never scored** [PRD AC]; this stage is where that is
/// decided, and it decides on evidence it also records.
enum SignalQualityValidation {
    /// - Parameters:
    ///   - series: stage 2 output, carrying the pre-filter channel.
    ///   - segmentation: stage 3 output.
    ///   - buffer: the frozen recording, for gap and interruption context.
    static func validate(
        series: PreprocessedSeries,
        segmentation: WalkingSegmentation,
        buffer: RawSessionBuffer,
        configuration: AlgorithmConfiguration
    ) -> SessionQualityReport {
        let quality = configuration.quality

        // ORDERING IS BINDING (docs/decisions.md entry 8): the ratio is computed
        // from `preFilterMagnitude`, which is resample-only. Judging noise on
        // the cleaned channels would measure a signal whose noise the 20 Hz
        // low-pass has already removed.
        let noiseRatio = highFrequencyPowerRatio(
            series: series,
            segmentation: segmentation,
            configuration: configuration
        )

        let reason = quality.invalidReason(
            mode: buffer.mode,
            validWalkingDuration: segmentation.walkingDuration,
            highFrequencyPowerRatio: noiseRatio
        )

        return SessionQualityReport(
            mode: buffer.mode,
            validWalkingDuration: segmentation.walkingDuration,
            requiredWalkingDuration: quality.minimumValidWalkingDuration(for: buffer.mode),
            highFrequencyPowerRatio: noiseRatio,
            noiseThreshold: quality.noise.maximumHighFrequencyPowerRatio,
            gapInfo: buffer.gapInfo,
            discardedSegmentCount: segmentation.discardedSegmentCount,
            discardedBoutCount: segmentation.discardedBoutCount,
            excludedDuration: segmentation.excludedDuration,
            transientDuration: segmentation.transientDuration,
            walkingIntervalCount: segmentation.intervals.count,
            interruptionCount: buffer.interruptionCount,
            dominantFrequencies: dominantFrequencies(
                series: series,
                segmentation: segmentation,
                configuration: configuration
            ),
            pedometerAgreement: segmentation.pedometerAgreement,
            pedometerAvailable: buffer.pedometerAvailable,
            invalidReason: reason
        )
    }

    // MARK: - Noise

    /// Share of power above the noise cutoff, on the pre-filter signal.
    ///
    /// Implemented as `variance(highPass(x)) / variance(x)` rather than by
    /// spectrum: the two express the same quantity, and a filter is O(n) where a
    /// transform is not. The high-pass is not a brick wall, so the ratio is an
    /// estimate — which is all a threshold comparison needs.
    ///
    /// Measured over the **walking intervals** where possible. Noise during a
    /// pause says nothing about whether the walking can be scored; if no walking
    /// was found, the whole clean signal is used so the report still has a value.
    static func highFrequencyPowerRatio(
        series: PreprocessedSeries,
        segmentation: WalkingSegmentation,
        configuration: AlgorithmConfiguration
    ) -> Double {
        let signal = noiseSourceSignal(series: series, segmentation: segmentation)
        guard signal.count > 2 else { return 0 }

        let cutoff = configuration.noise.highFrequencyCutoffHz
        let highPass = Biquad.highPass(cutoffHz: cutoff, sampleRateHz: series.sampleRateHz)
        let high = highPass.filtfilt(signal)

        let totalPower = meanSquare(signal)
        guard totalPower > 0 else { return 0 }
        return min(meanSquare(high) / totalPower, 1)
    }

    private static func noiseSourceSignal(
        series: PreprocessedSeries,
        segmentation: WalkingSegmentation
    ) -> [Double] {
        guard !segmentation.intervals.isEmpty else {
            return series.segments.flatMap(\.preFilterMagnitude)
        }
        return segmentation.intervals.flatMap { interval -> [Double] in
            let segment = series.segments[interval.segmentIndex]
            let upper = min(interval.endIndex, segment.preFilterMagnitude.count)
            guard interval.startIndex < upper else { return [] }
            return Array(segment.preFilterMagnitude[interval.startIndex..<upper])
        }
    }

    private static func meanSquare(_ signal: [Double]) -> Double {
        guard !signal.isEmpty else { return 0 }
        return signal.reduce(0) { $0 + $1 * $1 } / Double(signal.count)
    }

    // MARK: - Dominant frequency diagnostic

    /// Dominant frequency of each walking interval, by autocorrelation peak.
    ///
    /// The search band is derived from the configured plausible cadence range,
    /// so it introduces no tunable of its own. A diagnostic only: nothing gates
    /// on it (docs/decisions.md entry 9).
    static func dominantFrequencies(
        series: PreprocessedSeries,
        segmentation: WalkingSegmentation,
        configuration: AlgorithmConfiguration
    ) -> [Double] {
        let cadence = configuration.walkingDetection.plausibleCadenceRange
        let lowHz = cadence.lowerBound / 60
        let highHz = cadence.upperBound / 60

        return segmentation.intervals.compactMap { interval in
            let segment = series.segments[interval.segmentIndex]
            let upper = min(interval.endIndex, segment.vertical.count)
            guard interval.startIndex < upper else { return nil }
            let window = Array(segment.vertical[interval.startIndex..<upper])
            return dominantFrequency(window, sampleRateHz: series.sampleRateHz, lowHz: lowHz, highHz: highHz)
        }
    }

    /// Autocorrelation peak within the search band, converted to Hz.
    static func dominantFrequency(
        _ signal: [Double],
        sampleRateHz: Double,
        lowHz: Double,
        highHz: Double
    ) -> Double? {
        guard highHz > 0, lowHz > 0, signal.count > 4 else { return nil }

        let minLag = max(1, Int(sampleRateHz / highHz))
        let maxLag = min(signal.count - 1, Int(sampleRateHz / lowHz))
        guard minLag < maxLag else { return nil }

        let mean = signal.reduce(0, +) / Double(signal.count)
        let centred = signal.map { $0 - mean }

        // Biased normalisation — divide by the full length, not the overlap.
        // A periodic signal correlates just as well at twice its period, so the
        // unbiased estimator leaves the fundamental and its harmonics tied and
        // lets a subharmonic win, reporting half the real frequency. Dividing by
        // the full length makes the estimate decay with lag, so the first true
        // peak is the largest and the fundamental is selected.
        var bestLag = 0
        var bestValue = -Double.infinity
        for lag in minLag...maxLag {
            var sum = 0.0
            for index in 0..<(centred.count - lag) {
                sum += centred[index] * centred[index + lag]
            }
            let value = sum / Double(centred.count)
            if value > bestValue {
                bestValue = value
                bestLag = lag
            }
        }

        guard bestLag > 0, bestValue > 0 else { return nil }
        return sampleRateHz / Double(bestLag)
    }
}
