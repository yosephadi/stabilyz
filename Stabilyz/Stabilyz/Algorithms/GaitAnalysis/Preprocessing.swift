import Foundation

/// A contiguous run of clean, uniformly sampled signal.
///
/// Segments exist because a dropout ends one and starts another: nothing is
/// ever interpolated across a gap, so a suspended session cannot be made to
/// look like continuous walking [PRD §6].
struct PreprocessedSegment: Sendable, Equatable {
    /// Device timestamp of the first sample, on the untouched session timeline.
    let startTimestamp: TimeInterval
    let sampleRateHz: Double
    /// Along the gravity direction.
    let vertical: [Double]
    /// The dominant horizontal variance direction (docs/08 §8.2 orientation).
    let mediolateral: [Double]
    /// Perpendicular to both.
    let anteroposterior: [Double]

    var count: Int { vertical.count }
    var duration: Duration { .seconds(Double(count) / sampleRateHz) }

    /// Device timestamp of sample `index`, for placing findings back on the
    /// session timeline.
    func timestamp(at index: Int) -> TimeInterval {
        startTimestamp + Double(index) / sampleRateHz
    }
}

/// The output of pipeline stage 2 (docs/08).
struct PreprocessedSeries: Sendable, Equatable {
    let segments: [PreprocessedSegment]
    let sampleRateHz: Double
    /// The unit vertical axis this session was projected onto.
    let verticalAxis: Vector3
    /// The unit mediolateral axis.
    let mediolateralAxis: Vector3
    /// Segments discarded for being shorter than the configured minimum, kept
    /// as a count so the quality stage can see how fragmented a session was.
    let discardedSegmentCount: Int

    var isEmpty: Bool { segments.isEmpty }

    /// Total clean signal, gaps and discarded fragments excluded.
    var totalDuration: Duration {
        segments.reduce(.zero) { $0 + $1.duration }
    }
}

/// Pipeline stage 2: filtering, uniform resampling and orientation (docs/08).
///
/// Pure. Runs inside `SessionProcessor`, never on the main actor.
///
/// Order is deliberate: resample first so the filter sees a uniform grid,
/// project onto anatomical axes while gravity is still present, then band-pass.
/// Filtering before projection would strip the gravity the orientation estimate
/// depends on.
enum Preprocessing {
    static func process(
        _ series: AlignedSampleSeries,
        configuration: AlgorithmConfiguration
    ) -> PreprocessedSeries {
        let policy = configuration.preprocessing
        let rate = policy.targetSampleRateHz

        let axes = orientationAxes(for: series.samples, configuration: configuration)

        var segments: [PreprocessedSegment] = []
        var discarded = 0

        for run in contiguousRuns(of: series) {
            guard let resampled = resample(run, toRateHz: rate) else {
                discarded += 1
                continue
            }
            guard Duration.seconds(Double(resampled.samples.count) / rate) >= policy.minimumSegmentDuration else {
                discarded += 1
                continue
            }

            let projected = project(resampled.samples, axes: axes)
            segments.append(
                PreprocessedSegment(
                    startTimestamp: resampled.startTimestamp,
                    sampleRateHz: rate,
                    vertical: bandPass(projected.vertical, policy: policy, rate: rate),
                    mediolateral: bandPass(projected.mediolateral, policy: policy, rate: rate),
                    anteroposterior: bandPass(projected.anteroposterior, policy: policy, rate: rate)
                )
            )
        }

        return PreprocessedSeries(
            segments: segments,
            sampleRateHz: rate,
            verticalAxis: axes.vertical,
            mediolateralAxis: axes.mediolateral,
            discardedSegmentCount: discarded
        )
    }

    // MARK: - Segmentation at gaps

    /// Splits the series into runs of uninterrupted delivery.
    static func contiguousRuns(of series: AlignedSampleSeries) -> [[SensorSample]] {
        guard !series.samples.isEmpty else { return [] }
        guard !series.gaps.isEmpty else { return [series.samples] }

        let boundaries = Set(series.gaps.map(\.start))
        var runs: [[SensorSample]] = []
        var current: [SensorSample] = []

        for sample in series.samples {
            current.append(sample)
            if boundaries.contains(sample.deviceTimestamp) {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    // MARK: - Resampling

    /// Linear interpolation onto a uniform grid.
    ///
    /// Only ever between neighbouring real samples: a run contains no gaps by
    /// construction, so nothing is invented across missing time.
    static func resample(
        _ samples: [SensorSample],
        toRateHz rate: Double
    ) -> (startTimestamp: TimeInterval, samples: [SensorSample])? {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else { return nil }

        let step = 1 / rate
        let span = last.deviceTimestamp - first.deviceTimestamp
        let count = Int(span / step) + 1
        guard count >= 2 else { return nil }

        var output: [SensorSample] = []
        output.reserveCapacity(count)
        var sourceIndex = 0

        for index in 0..<count {
            let t = first.deviceTimestamp + Double(index) * step

            while sourceIndex + 2 < samples.count && samples[sourceIndex + 1].deviceTimestamp < t {
                sourceIndex += 1
            }
            let left = samples[sourceIndex]
            let right = samples[min(sourceIndex + 1, samples.count - 1)]

            let spanLR = right.deviceTimestamp - left.deviceTimestamp
            let fraction = spanLR > 0 ? (t - left.deviceTimestamp) / spanLR : 0

            output.append(
                SensorSample(
                    deviceTimestamp: t,
                    anchor: left.anchor,
                    acceleration: interpolate(left.acceleration, right.acceleration, fraction),
                    gravity: interpolate(left.gravity, right.gravity, fraction)
                )
            )
        }

        return (first.deviceTimestamp, output)
    }

    // MARK: - Orientation (docs/08 §8.2)

    struct OrientationAxes: Sendable, Equatable {
        let vertical: Vector3
        let mediolateral: Vector3
        let anteroposterior: Vector3
    }

    /// Derives anatomical axes for the session.
    ///
    /// Vertical comes from the gravity vector, so no phone placement is
    /// assumed. The horizontal plane is then split by dominant variance:
    /// at the trunk, walking sways side-to-side more than it surges fore-aft,
    /// so the dominant direction is mediolateral.
    static func orientationAxes(
        for samples: [SensorSample],
        configuration: AlgorithmConfiguration
    ) -> OrientationAxes {
        let fallback = OrientationAxes(
            vertical: Vector3(x: 0, y: 0, z: -1),
            mediolateral: Vector3(x: 1, y: 0, z: 0),
            anteroposterior: Vector3(x: 0, y: 1, z: 0)
        )
        guard !samples.isEmpty else { return fallback }

        // Gravity when the capture has it; otherwise whatever survives below
        // the gravity-estimation cutoff, which at these frequencies is gravity.
        let gravitySamples = samples.compactMap(\.gravity)
        let verticalSource = gravitySamples.count == samples.count
            ? mean(gravitySamples)
            : mean(samples.map(\.acceleration))

        guard let vertical = normalized(verticalSource) else { return fallback }

        // Any vector not parallel to vertical gives a starting horizontal basis.
        // This is a numerical-stability guard, not a tunable: the basis is
        // rotated to the data by the PCA below, so the choice of seed cannot
        // change the result — it only has to avoid being parallel to vertical.
        let parallelGuard = 0.9
        let seed = abs(vertical.x) < parallelGuard
            ? Vector3(x: 1, y: 0, z: 0)
            : Vector3(x: 0, y: 1, z: 0)
        guard let u = normalized(subtract(seed, scale(vertical, dot(seed, vertical)))) else { return fallback }
        let v = cross(vertical, u)

        // 2×2 covariance of the horizontal residual, then its dominant
        // eigenvector — the direction the signal varies along most.
        var sumUU = 0.0, sumUV = 0.0, sumVV = 0.0
        var meanU = 0.0, meanV = 0.0
        let horizontal: [(Double, Double)] = samples.map { sample in
            let residual = subtract(sample.acceleration, scale(vertical, dot(sample.acceleration, vertical)))
            return (dot(residual, u), dot(residual, v))
        }
        for (a, b) in horizontal { meanU += a; meanV += b }
        meanU /= Double(horizontal.count)
        meanV /= Double(horizontal.count)
        for (a, b) in horizontal {
            let da = a - meanU, db = b - meanV
            sumUU += da * da; sumUV += da * db; sumVV += db * db
        }

        let theta = 0.5 * atan2(2 * sumUV, sumUU - sumVV)
        let mediolateral = normalized(add(scale(u, cos(theta)), scale(v, sin(theta)))) ?? u
        let anteroposterior = cross(vertical, mediolateral)

        return OrientationAxes(
            vertical: vertical,
            mediolateral: mediolateral,
            anteroposterior: anteroposterior
        )
    }

    private static func project(
        _ samples: [SensorSample],
        axes: OrientationAxes
    ) -> (vertical: [Double], mediolateral: [Double], anteroposterior: [Double]) {
        (
            samples.map { dot($0.acceleration, axes.vertical) },
            samples.map { dot($0.acceleration, axes.mediolateral) },
            samples.map { dot($0.acceleration, axes.anteroposterior) }
        )
    }

    // MARK: - Filtering

    private static func bandPass(_ signal: [Double], policy: PreprocessingPolicy, rate: Double) -> [Double] {
        guard signal.count > 2 else { return signal }

        // Remove the constant first. The high-pass is there to take out slow
        // drift, not to fight a large DC offset: handing it one makes the
        // filter start from a step and ring for the first second of the signal.
        let mean = signal.reduce(0, +) / Double(signal.count)
        let centred = signal.map { $0 - mean }

        // Reflect-pad both ends, so the filter's start-up transient lands in
        // padding that gets thrown away rather than in real gait data.
        let padding = min(
            Int(policy.filterEdgePaddingCycles * rate / policy.highPassCutoffHz),
            centred.count - 1
        )
        let padded = reflectPad(centred, by: padding)

        let high = Biquad.highPass(cutoffHz: policy.highPassCutoffHz, sampleRateHz: rate)
        let low = Biquad.lowPass(cutoffHz: policy.lowPassCutoffHz, sampleRateHz: rate)

        let filtered = policy.zeroPhaseFiltering
            ? low.filtfilt(high.filtfilt(padded))
            : low.filter(high.filter(padded))

        return Array(filtered[padding..<(padding + centred.count)])
    }

    /// Mirrors `count` samples at each end, reflected about the endpoint so the
    /// padding continues the signal's trend rather than introducing a step.
    private static func reflectPad(_ signal: [Double], by count: Int) -> [Double] {
        guard count > 0, let first = signal.first, let last = signal.last else { return signal }

        let head = (1...count).reversed().map { index -> Double in
            2 * first - signal[min(index, signal.count - 1)]
        }
        let tail = (1...count).map { index -> Double in
            2 * last - signal[max(signal.count - 1 - index, 0)]
        }
        return head + signal + tail
    }

    // MARK: - Vector helpers

    private static func interpolate(_ a: Vector3, _ b: Vector3, _ f: Double) -> Vector3 {
        Vector3(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, z: a.z + (b.z - a.z) * f)
    }

    private static func interpolate(_ a: Vector3?, _ b: Vector3?, _ f: Double) -> Vector3? {
        guard let a else { return nil }
        guard let b else { return a }
        return interpolate(a, b, f)
    }

    private static func mean(_ vectors: [Vector3]) -> Vector3 {
        let count = Double(vectors.count)
        return vectors.reduce(Vector3(x: 0, y: 0, z: 0)) {
            Vector3(x: $0.x + $1.x / count, y: $0.y + $1.y / count, z: $0.z + $1.z / count)
        }
    }

    private static func dot(_ a: Vector3, _ b: Vector3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func add(_ a: Vector3, _ b: Vector3) -> Vector3 { Vector3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    private static func subtract(_ a: Vector3, _ b: Vector3) -> Vector3 { Vector3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    private static func scale(_ a: Vector3, _ f: Double) -> Vector3 { Vector3(x: a.x * f, y: a.y * f, z: a.z * f) }

    private static func cross(_ a: Vector3, _ b: Vector3) -> Vector3 {
        Vector3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }

    private static func normalized(_ a: Vector3) -> Vector3? {
        let length = sqrt(dot(a, a))
        guard length > 1e-12 else { return nil }
        return scale(a, 1 / length)
    }
}
