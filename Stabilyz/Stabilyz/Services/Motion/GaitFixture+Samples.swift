import Foundation

/// Small built-in captures.
///
/// These exist so previews and smoke tests have something to replay without a
/// bundled resource file. The rigorous synthetic corpus — signals with known
/// Ad1/Ad2, injected pauses and noise sweeps for golden regression — is
/// Task 5.3.1 and lives with the algorithm tests.
extension GaitFixture {
    /// Roughly two seconds of steady walking at 100 Hz, 108 steps/min.
    ///
    /// Vertical acceleration carries the footfall rhythm; the mediolateral axis
    /// carries a half-rate sway, which is the stride-vs-step distinction the
    /// autocorrelation stage relies on (docs/08 stage 5).
    static var steadyWalk: GaitFixture {
        makeWalk(name: "steady-walk-108bpm", cadenceBPM: 108, seconds: 2, noise: 0.01)
    }

    /// The same walk with a two-second sensor gap in the middle, as a
    /// suspension produces (docs/07 §7.7).
    static var walkWithSensorGap: GaitFixture {
        let walk = makeWalk(name: "walk-with-gap", cadenceBPM: 108, seconds: 4, noise: 0.01)
        // Drop the middle two seconds: the gap is the absence of samples.
        let kept = walk.samples.filter { $0.t < 1.0 || $0.t > 3.0 }

        return GaitFixture(
            metadata: Metadata(
                name: "walk-with-gap",
                sampleRateHz: walk.metadata.sampleRateHz,
                deviceMotionIncluded: walk.metadata.deviceMotionIncluded,
                cadenceBPM: 108,
                signalToNoiseRatio: walk.metadata.signalToNoiseRatio,
                notes: "Two-second sensor gap between t=1.0 and t=3.0, as a suspension produces."
            ),
            samples: kept,
            pedometerScript: walk.pedometerScript
        )
    }

    /// Builds a simple periodic walking signal.
    ///
    /// Deliberately basic — enough to exercise plumbing, not a model of
    /// prosthetic gait. Realistic captures come from device recordings
    /// (docs/07 §7.9) and the Task 5.3.1 corpus.
    static func makeWalk(
        name: String,
        cadenceBPM: Double,
        seconds: Double,
        sampleRateHz: Double = 100,
        noise: Double = 0
    ) -> GaitFixture {
        let stepsPerSecond = cadenceBPM / 60
        let sampleCount = Int(seconds * sampleRateHz)
        // Deterministic pseudo-noise: fixtures must replay identically.
        var seed = 0x5EED

        let samples = (0..<sampleCount).map { index -> Sample in
            let t = Double(index) / sampleRateHz
            seed = (seed &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
            let jitter = noise * (Double(seed % 1000) / 500 - 1)

            let vertical = sin(2 * .pi * stepsPerSecond * t) + jitter
            // Sway completes one cycle per stride, i.e. every two steps.
            let mediolateral = 0.4 * sin(.pi * stepsPerSecond * t) + jitter

            return Sample(
                t: t,
                ax: mediolateral,
                ay: 0.05 * jitter,
                az: vertical,
                gx: 0, gy: 0, gz: -1
            )
        }

        let script = stride(from: 1.0, through: max(seconds, 1.0), by: 1.0).map { second in
            PedometerScriptEntry(
                t: second,
                steps: Int(stepsPerSecond * second),
                cadence: stepsPerSecond,
                pace: 0.8,
                distance: 1.2 * second
            )
        }

        return GaitFixture(
            metadata: Metadata(
                name: name,
                sampleRateHz: sampleRateHz,
                deviceMotionIncluded: true,
                cadenceBPM: cadenceBPM,
                signalToNoiseRatio: noise == 0 ? nil : 1 / noise,
                notes: "Synthetic periodic walk for plumbing tests and previews."
            ),
            samples: samples,
            pedometerScript: script
        )
    }
}
