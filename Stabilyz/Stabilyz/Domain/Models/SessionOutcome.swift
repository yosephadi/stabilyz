/// Why a session could not be scored [PRD §5 noisy path].
///
/// Raw values are persisted (docs/05 §5.2) and recorded on the session record so
/// a tester's "bad session" is self-explanatory in diagnostics (docs/20).
enum InvalidReason: String, Sendable, CaseIterable, Codable {
    /// Valid walking fell below the mode's `SessionPolicy` minimum, even if the
    /// advertised clock length elapsed [PRD OQ-3].
    case insufficientValidWalking
    /// Signal quality failed the noise threshold [threshold value OPEN, docs/08].
    case excessiveNoise
    /// An interruption left the session unrecoverable (docs/07 §7.7).
    case unrecoverableInterruption
    /// The sensor stream failed or delivered nothing (docs/08 stage 1).
    case sensorFailure
}

/// The result of processing a session [PRD §5]. A session is one or the other —
/// never both, never neither (docs/11 §11.3).
enum SessionOutcome: Sendable, Equatable, Codable {
    case valid
    case invalid(reason: InvalidReason)

    var isValid: Bool {
        switch self {
        case .valid: true
        case .invalid: false
        }
    }

    var invalidReason: InvalidReason? {
        switch self {
        case .valid: nil
        case .invalid(let reason): reason
        }
    }
}

/// Which audio opt-in was active for a session, persisted with it for
/// transparency and interpretation [REC — docs/05 §5.1, docs/10 §10.4].
///
/// Modeled as an enum so the tempo cannot be present without the metronome, or
/// absent with it. The metronome case carries a `MetronomeCue` rather than a
/// bare BPM, and a cue cannot be built without that mode's own established
/// baseline — so "the metronome is not offered during sessions 1–5" and "the
/// tempo is this mode's baseline cadence" [PRD §5, §7] are properties of the
/// type, not rules a call site has to remember. Step Feedback's pre-baseline
/// gating remains Session Setup's to enforce; nothing about a tick depends on
/// a value that could be wrong.
enum SessionAudioConfig: Sendable, Equatable, Codable {
    case none
    case stepFeedback
    case metronome(cue: MetronomeCue)
}

/// Sensor gap record, kept to explain noise and validity decisions
/// [REC — docs/05 §5.1, docs/07 §7.7].
struct SessionGapInfo: Sendable, Equatable, Codable {
    let gapCount: Int
    let totalGapDuration: Duration
    let longestGapDuration: Duration

    static let none = SessionGapInfo(gapCount: 0, totalGapDuration: .zero, longestGapDuration: .zero)

    init(gapCount: Int, totalGapDuration: Duration, longestGapDuration: Duration) {
        self.gapCount = gapCount
        self.totalGapDuration = totalGapDuration
        self.longestGapDuration = longestGapDuration
    }
}
