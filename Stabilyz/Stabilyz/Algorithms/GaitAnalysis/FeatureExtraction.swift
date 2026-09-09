import Foundation

/// Features from one analysis window (docs/08 stage 5).
///
/// Per-window, not per-session: aggregating these into `GaitMetrics` is stage
/// 6's job (Task 5.2.5). Keeping the boundary means variability across windows
/// stays measurable, which a single whole-signal number would destroy.
struct WindowFeatures: Sendable, Equatable {
    /// Index into `WalkingSegmentation.intervals`.
    let intervalIndex: Int
    let startTimestamp: TimeInterval
    let duration: Duration

    /// Intervals between consecutive detected footfalls, in seconds.
    let stepTimes: [Double]
    /// Step regularity — autocorrelation at the step lag, normalised.
    let ad1: Double
    /// Stride regularity — autocorrelation at the stride lag, normalised.
    let ad2: Double
    /// The lag Ad1 was read at, in seconds. Recorded so a swapped anchor is
    /// visible rather than silently producing plausible-looking numbers.
    let stepLag: Double
    /// The lag Ad2 was read at, in seconds. Always about twice `stepLag`.
    let strideLag: Double
    /// RMS of mediolateral acceleration over the window (`TrunkProxyPolicy`).
    let trunkRMSMediolateral: Double
    /// RMS of vertical acceleration over the window.
    let trunkRMSVertical: Double

    var stepCount: Int { stepTimes.count + 1 }
    /// Two steps to a stride.
    var strideCount: Int { stepCount / 2 }
}

/// The output of pipeline stage 5.
struct ExtractedFeatures: Sendable, Equatable {
    let windows: [WindowFeatures]
    /// Strides across the whole session.
    let strideCount: Int
    /// Windows skipped for being too short or yielding too few footfalls to
    /// anchor an autocorrelation lag. A fact for the quality view, in the same
    /// spirit as stage 3's discarded bouts.
    let discardedWindowCount: Int

    var isEmpty: Bool { windows.isEmpty }
}

/// Pipeline stage 5: step peaks, step times, Ad1/Ad2, and the trunk proxy
/// (docs/08).
///
/// **Profile-blind by construction.** Nothing here takes a `UserProfile`, and
/// nothing branches on amputation level or side: gait consistency is computed
/// identically for every user because it reads the walking signal's own
/// repeating structure and never needs to know which leg is which
/// [PRD OQ-1, §7 AC]. The one profile-dependent feature — sound-vs-prosthetic
/// step-time asymmetry — belongs to stage 6.
enum FeatureExtraction {
    static func extract(
        series: PreprocessedSeries,
        segmentation: WalkingSegmentation,
        configuration: AlgorithmConfiguration
    ) -> ExtractedFeatures {
        let policy = configuration.featureExtraction
        let rate = series.sampleRateHz

        var windows: [WindowFeatures] = []
        var discarded = 0

        for (intervalIndex, interval) in segmentation.intervals.enumerated() {
            let segment = series.segments[interval.segmentIndex]

            for range in windowRanges(for: interval, policy: policy, rate: rate) {
                let upperVertical = min(range.upperBound, segment.vertical.count)
                guard range.lowerBound < upperVertical else {
                    discarded += 1
                    continue
                }

                let vertical = Array(segment.vertical[range.lowerBound..<upperVertical])
                let mediolateral = Array(
                    segment.mediolateral[range.lowerBound..<min(range.upperBound, segment.mediolateral.count)]
                )

                guard let features = features(
                    vertical: vertical,
                    mediolateral: mediolateral,
                    intervalIndex: intervalIndex,
                    startTimestamp: segment.timestamp(at: range.lowerBound),
                    rate: rate,
                    configuration: configuration
                ) else {
                    discarded += 1
                    continue
                }
                windows.append(features)
            }
        }

        return ExtractedFeatures(
            windows: windows,
            strideCount: windows.reduce(0) { $0 + $1.strideCount },
            discardedWindowCount: discarded
        )
    }

    /// Whether enough strides were found to compute metrics at all.
    ///
    /// Below the minimum, the session routes to the quality path rather than
    /// producing metrics from too little data (docs/08 stage 5). The shortfall
    /// is reported as insufficient valid walking, which is what it is from the
    /// user's point of view.
    static func strideShortfallReason(
        _ features: ExtractedFeatures,
        configuration: AlgorithmConfiguration
    ) -> InvalidReason? {
        features.strideCount < configuration.quality.minimumValidStrides
            ? .insufficientValidWalking
            : nil
    }

    // MARK: - Windowing

    static func windowRanges(
        for interval: WalkingInterval,
        policy: FeatureExtractionPolicy,
        rate: Double
    ) -> [Range<Int>] {
        let full = samples(of: policy.analysisWindowDuration, at: rate)
        let minimum = samples(of: policy.minimumAnalysisWindowDuration, at: rate)
        guard full > 0 else { return [] }

        var ranges: [Range<Int>] = []
        var start = interval.startIndex

        while start < interval.endIndex {
            let end = min(start + full, interval.endIndex)
            let length = end - start
            // Non-overlapping, so a stride is never counted twice.
            if length >= full || length >= minimum {
                ranges.append(start..<end)
            }
            start = end
        }
        return ranges
    }

    // MARK: - Per-window features

    static func features(
        vertical: [Double],
        mediolateral: [Double],
        intervalIndex: Int,
        startTimestamp: TimeInterval,
        rate: Double,
        configuration: AlgorithmConfiguration
    ) -> WindowFeatures? {
        let policy = configuration.featureExtraction
        let cadence = configuration.walkingDetection.plausibleCadenceRange

        let peaks = stepPeaks(vertical, rate: rate, configuration: configuration)
        guard peaks.count >= 2 else { return nil }

        let stepTimes = zip(peaks, peaks.dropFirst()).map { Double($1 - $0) / rate }

        // The step period comes from the detected footfalls, not from the
        // strongest autocorrelation peak. In an asymmetric gait the stride peak
        // can be the stronger of the two, so anchoring on "whichever is biggest"
        // is exactly how Ad1 and Ad2 end up swapped.
        guard let stepLagSeconds = median(stepTimes) else { return nil }
        let minStepLag = 60 / cadence.upperBound
        let maxStepLag = 60 / cadence.lowerBound
        guard stepLagSeconds >= minStepLag, stepLagSeconds <= maxStepLag else { return nil }

        let stepLag = Int((stepLagSeconds * rate).rounded())
        let strideLag = stepLag * 2
        guard strideLag < vertical.count else { return nil }

        let correlation = biasedAutocorrelation(vertical, maximumLag: min(strideLag * 2, vertical.count - 1))
        guard let zeroLag = correlation.first, zeroLag > 0 else { return nil }

        let ad1 = peakValue(in: correlation, around: stepLag, tolerance: policy.lagSearchTolerance)
        let ad2 = peakValue(in: correlation, around: strideLag, tolerance: policy.lagSearchTolerance)

        return WindowFeatures(
            intervalIndex: intervalIndex,
            startTimestamp: startTimestamp,
            duration: .seconds(Double(vertical.count) / rate),
            stepTimes: stepTimes,
            ad1: normalise(ad1.value, by: zeroLag),
            ad2: normalise(ad2.value, by: zeroLag),
            stepLag: Double(ad1.lag) / rate,
            strideLag: Double(ad2.lag) / rate,
            // TrunkProxyPolicy: per-axis RMS over steady walking. Transients are
            // already excluded by stage 3, so the window is steady-state.
            trunkRMSMediolateral: rms(mediolateral),
            trunkRMSVertical: rms(vertical)
        )
    }

    // MARK: - Step peaks

    /// Local maxima that stand far enough above the window's own level, spaced
    /// no closer than the fastest plausible step.
    static func stepPeaks(
        _ signal: [Double],
        rate: Double,
        configuration: AlgorithmConfiguration
    ) -> [Int] {
        guard signal.count > 2 else { return [] }

        let mean = signal.reduce(0, +) / Double(signal.count)
        let variance = signal.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(signal.count)
        let threshold = mean + configuration.featureExtraction.stepPeakProminenceSDs * variance.squareRoot()

        // The fastest plausible cadence sets the closest two footfalls can be.
        let refractory = Int(60 / configuration.walkingDetection.plausibleCadenceRange.upperBound * rate)

        var peaks: [Int] = []
        for index in 1..<(signal.count - 1) {
            guard signal[index] >= threshold,
                  signal[index] > signal[index - 1],
                  signal[index] >= signal[index + 1] else { continue }

            if let last = peaks.last, index - last < refractory {
                // Keep whichever of the two is the stronger footfall.
                if signal[index] > signal[last] { peaks[peaks.count - 1] = index }
                continue
            }
            peaks.append(index)
        }
        return peaks
    }

    // MARK: - Autocorrelation

    /// Biased autocorrelation — divided by the full length, not the overlap.
    ///
    /// docs/decisions.md entry 10: the unbiased estimator leaves a periodic
    /// signal's fundamental and its harmonics tied, so a subharmonic can win.
    /// Here the anchoring makes that less critical, but the same estimator is
    /// used throughout so Ad1 and Ad2 are on one consistent scale.
    static func biasedAutocorrelation(_ signal: [Double], maximumLag: Int) -> [Double] {
        guard !signal.isEmpty, maximumLag >= 0 else { return [] }
        let mean = signal.reduce(0, +) / Double(signal.count)
        let centred = signal.map { $0 - mean }
        let length = Double(centred.count)

        return (0...maximumLag).map { lag in
            var sum = 0.0
            for index in 0..<(centred.count - lag) {
                sum += centred[index] * centred[index + lag]
            }
            return sum / length
        }
    }

    /// The strongest correlation within a fractional window around an expected
    /// lag, and where it was found.
    static func peakValue(
        in correlation: [Double],
        around expectedLag: Int,
        tolerance: Double
    ) -> (value: Double, lag: Int) {
        let spread = max(1, Int((Double(expectedLag) * tolerance).rounded()))
        let lower = max(1, expectedLag - spread)
        let upper = min(correlation.count - 1, expectedLag + spread)
        guard lower <= upper else { return (0, expectedLag) }

        var bestLag = lower
        var bestValue = correlation[lower]
        for lag in lower...upper where correlation[lag] > bestValue {
            bestValue = correlation[lag]
            bestLag = lag
        }
        return (bestValue, bestLag)
    }

    // MARK: - Helpers

    /// Ad values are bounded to [0, 1]: a negative correlation means the pattern
    /// does not repeat at that lag, which is zero regularity, not a negative
    /// amount of it.
    private static func normalise(_ value: Double, by zeroLag: Double) -> Double {
        min(max(value / zeroLag, 0), 1)
    }

    static func rms(_ signal: [Double]) -> Double {
        guard !signal.isEmpty else { return 0 }
        return (signal.reduce(0) { $0 + $1 * $1 } / Double(signal.count)).squareRoot()
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func samples(of duration: Duration, at rate: Double) -> Int {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return Int((seconds * rate).rounded())
    }
}
