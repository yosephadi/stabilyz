import Foundation

/// What the Recording screen observes while a session runs (docs/07 §7.2).
///
/// These are UI signals only. The authoritative gap and validity data is the
/// frozen `RawSessionBuffer` produced at stop — a missed live event can never
/// change how a session is scored.
enum SessionRecordingEvent: Sendable, Equatable {
    /// Sensors primed and delivering; the start tone follows (docs/07 §7.3).
    case ready
    /// Elapsed session time, emitted once per whole second.
    case elapsed(Duration)
    /// A dropout was noticed live (docs/07 §7.7).
    case gapDetected(SensorGap)
    /// The session was interrupted. Populated by Task 4.2.3.
    case interrupted
    /// A sensor failed mid-session. The session flow surfaces this and ends.
    case sensorError(StabilyzError)
    /// Recording finished and the buffer was frozen.
    case stopped
}
