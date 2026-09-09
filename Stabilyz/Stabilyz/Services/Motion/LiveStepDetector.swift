import Foundation

/// A footfall detected live, for audio feedback only (docs/07 §7.2).
///
/// **Never an input to scoring.** Scoring runs on the frozen batch buffer, and
/// the batch step detection in Task 5.2.4 is a separate, more careful
/// computation. These two must not be conflated: this one trades accuracy for
/// latency, because a tick that arrives late feels disconnected from the step
/// [PRD §7], while a metric that is slightly late costs nothing (docs/10 §10.4).
struct LiveStepEvent: Sendable, Equatable {
    let deviceTimestamp: TimeInterval
    /// 0...1. Only steps at or above the policy threshold should make a sound.
    let confidence: Double
}

/// Tunables for live step detection (docs/10 §10.3).
///
/// Values come from `AlgorithmConfiguration` and are declared nowhere else.
struct LiveStepDetectionPolicy: Sendable, Equatable {
    let confidenceThreshold: Double
    let refractory: Duration
    /// How many standard deviations above the running mean counts as full
    /// confidence. Part of the same unresolved sign/scale question.
    let fullConfidenceSigma: Double

    init(confidenceThreshold: Double, refractory: Duration, fullConfidenceSigma: Double = 3) {
        self.confidenceThreshold = confidenceThreshold
        self.refractory = refractory
        self.fullConfidenceSigma = fullConfidenceSigma
    }
}

/// Detects footfalls sample by sample for audio feedback (docs/07 §7.2, §7.9).
///
/// Pure and framework-free, so it is testable against synthetic footfall
/// signals. It lives under `Services/Motion` per docs/16, but imports nothing
/// from Apple beyond Foundation.
///
/// It works on **acceleration magnitude**, which is orientation-independent.
/// That is deliberate: how axes and phone placement are derived is [OPEN]
/// (docs/08 §8.2), and a sound cue must not depend on an unresolved question.
/// Batch feature extraction handles orientation properly in Task 5.2.1.
///
/// Cost per sample is a handful of arithmetic operations, as required by
/// docs/14 §14.2.
struct LiveStepDetector {
    private let policy: LiveStepDetectionPolicy
    /// Smoothing for the running mean and variance. Larger adapts slower.
    private let smoothing: Double

    private var mean: Double?
    private var variance: Double = 0
    private var previous: Double?
    private var beforePrevious: Double?
    private var previousTimestamp: TimeInterval?
    private var lastEmittedTimestamp: TimeInterval?

    init(policy: LiveStepDetectionPolicy, smoothing: Double = 0.02) {
        self.policy = policy
        self.smoothing = smoothing
    }

    /// Feeds one sample and returns an event when a confident footfall is
    /// detected and the refractory window has passed.
    ///
    /// Returns nil far more often than not; that is the point. A raw spike must
    /// never create an accidental rhythm [PRD §6, OQ-4].
    mutating func process(_ sample: SensorSample) -> LiveStepEvent? {
        let magnitude = sqrt(
            sample.acceleration.x * sample.acceleration.x
                + sample.acceleration.y * sample.acceleration.y
                + sample.acceleration.z * sample.acceleration.z
        )

        defer {
            beforePrevious = previous
            previous = magnitude
            previousTimestamp = sample.deviceTimestamp
        }

        // Running mean and variance, so the detector adapts to how hard this
        // particular user strikes rather than to an absolute threshold.
        let currentMean = mean ?? magnitude
        let deviation = magnitude - currentMean
        mean = currentMean + smoothing * deviation
        variance = (1 - smoothing) * (variance + smoothing * deviation * deviation)

        // A peak is the middle of three rising-then-falling samples, so the
        // event is reported one sample late by construction.
        guard let beforePrevious, let previous, let previousTimestamp else { return nil }
        guard previous > beforePrevious, previous >= magnitude else { return nil }

        let standardDeviation = sqrt(variance)
        guard standardDeviation > 0 else { return nil }

        let prominence = (previous - currentMean) / (policy.fullConfidenceSigma * standardDeviation)
        let confidence = min(max(prominence, 0), 1)
        guard confidence >= policy.confidenceThreshold else { return nil }

        // Refractory gate: one footfall must not produce two or three ticks
        // (docs/10 §10.3).
        if let lastEmittedTimestamp {
            let sinceLast = Duration.seconds(previousTimestamp - lastEmittedTimestamp)
            guard sinceLast >= policy.refractory else { return nil }
        }

        lastEmittedTimestamp = previousTimestamp
        return LiveStepEvent(deviceTimestamp: previousTimestamp, confidence: confidence)
    }

    /// Clears adaptation state between sessions.
    mutating func reset() {
        mean = nil
        variance = 0
        previous = nil
        beforePrevious = nil
        previousTimestamp = nil
        lastEmittedTimestamp = nil
    }
}
