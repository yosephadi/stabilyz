import Foundation

/// The T-0 admission rule for raw sensor samples [PRD OQ-6, docs/07 §7.3].
///
/// A session begins at **Go** — the final countdown tick — not when Start Test
/// was tapped. Sensors are primed during the countdown so that delivery is
/// already established at Go, which means samples exist *before* the session
/// does. This type is the single expression of where the line falls:
///
/// > the first admitted sample of a recorded walk is the first sample at or
/// > after T-0.
///
/// **Dropped at admission, never downstream.** The countdown window is outside
/// the session entirely, not a segment that is recorded and later filtered. A
/// pre-T-0 sample must never reach the buffer, the gap detector, live step
/// detection, or `RawSessionBuffer` — so there is nothing for a later stage to
/// mistake for walking, and `WalkingSegmentDetector` (docs/08 stage 3) is left
/// owning only what it should: non-walking *after* T-0.
///
/// Lives in Domain because the rule is a property of the measurement, not of
/// CoreMotion or of any one buffer. Both enforcement points — `SessionRecorder`
/// and `SessionSampleBuffer` — consult this type rather than restating the
/// comparison, so the rule cannot drift between them.
struct SampleAdmission: Sendable, Equatable {
    /// The session origin on the monotonic device timebase — `TimeAnchor.uptime`.
    ///
    /// Device uptime, never wall clock: durations and ordering come from the
    /// monotonic timebase alone (docs/07 §7.4), so a clock change mid-countdown
    /// cannot move the boundary.
    let t0: TimeInterval

    init(t0: TimeInterval) {
        self.t0 = t0
    }

    /// The session's own anchor is the origin, which is what makes T-0 and
    /// `startedAt` the same instant by construction.
    init(anchor: TimeAnchor) {
        self.init(t0: anchor.uptime)
    }

    /// Whether this sample belongs to the session.
    ///
    /// At-or-after, not strictly after: a sample landing exactly on T-0 is the
    /// first sample of the walk, not the last of the countdown. The boundary is
    /// closed on the session's side so that an exact hit is admitted
    /// deterministically rather than depending on float comparison luck.
    func admits(_ sample: SensorSample) -> Bool {
        sample.deviceTimestamp >= t0
    }

    /// The admitted subsequence, in the order given.
    ///
    /// Order-preserving by construction. Ordering and de-duplication belong to
    /// pipeline stage 1 (`SampleIngestion`, docs/08); doing either here would
    /// create a second source of truth for the same property.
    func admitting(_ samples: [SensorSample]) -> [SensorSample] {
        samples.filter(admits)
    }
}
