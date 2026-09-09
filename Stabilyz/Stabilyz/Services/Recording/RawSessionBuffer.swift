import Foundation

/// The frozen, immutable output of a recording (docs/07 §7.2).
///
/// A value type: once `stop()` hands this to the processing subsystem, nothing
/// can mutate it. That is what makes it "mathematically impossible" for the
/// audio layer to influence scoring (docs/10 §10.4) — scoring runs on this
/// snapshot alone.
///
/// It carries the aligned series rather than raw samples, so the gap metadata
/// the recorder produced is the single source of truth for validity
/// (docs/07 §7.8).
///
/// Task 4.2.4 adds the bounded in-memory ring and the temp scratch file that
/// back this during a long session; the contract handed downstream is this type
/// either way.
struct RawSessionBuffer: Sendable, Equatable {
    let mode: TestMode
    let audioConfig: SessionAudioConfig
    /// The single time reference for the session (docs/07 §7.4).
    let anchor: TimeAnchor
    /// Ordered, de-duplicated samples with gaps identified (docs/08 stage 1).
    let series: AlignedSampleSeries
    /// Pedometer updates on the same timeline (docs/07 §7.4).
    let pedometerEvents: [PedometerEvent]
    let startedAt: Date
    let endedAt: Date
    /// What the clock ran, from the monotonic timebase — not what counted
    /// [PRD OQ-3].
    let advertisedClockElapsed: Duration
    /// Populated by interruption observation in Task 4.2.3.
    let interruptionCount: Int
    /// False when the pedometer cross-check was not available for this session.
    /// Segmentation and step detection use pedometer data as a cross-check
    /// (docs/08 stage 3), so later analysis needs to know it was missing rather
    /// than inferring it from an absent event list.
    let pedometerAvailable: Bool

    var samples: [SensorSample] { series.samples }
    var gapInfo: SessionGapInfo { series.gapInfo }

    /// True when the sensor delivered nothing at all. docs/08 stage 1 maps this
    /// to `SessionOutcome.invalid(.sensorFailure)`.
    var isEmpty: Bool { series.samples.isEmpty }
}
