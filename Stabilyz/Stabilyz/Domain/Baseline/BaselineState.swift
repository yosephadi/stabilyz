/// A mode's calibration progress, derived from the persisted valid-session
/// count rather than stored as a mutable field (docs/05 §5.1, docs/09 §9.4).
///
/// One source of truth for the Score screen, audio selector, Home and the
/// Clinician Summary [PRD §5, §7]. Derivation lives in `BaselineStateMachine`
/// (Task 2.2.1).
enum BaselineState: Sendable, Equatable {
    /// No valid sessions in this mode yet.
    case notStarted
    /// Between 1 and 4 valid sessions — the "Session X of 5" state [PRD §5].
    case building(validCount: Int)
    /// Five valid sessions committed; frozen for v1, no recalibration [PRD §6].
    case established(Baseline)

    var baseline: Baseline? {
        switch self {
        case .established(let baseline): baseline
        case .notStarted, .building: nil
        }
    }

    var isEstablished: Bool { baseline != nil }

    /// Valid same-mode sessions counted so far, capped at the requirement.
    var validCount: Int {
        switch self {
        case .notStarted: 0
        case .building(let count): count
        case .established: Baseline.requiredValidSessionCount
        }
    }

    /// Whether the Metronome may be offered, which requires this mode's
    /// baseline to exist [PRD §5, docs/10 §10.3].
    var allowsMetronome: Bool { isEstablished }

    /// Whether Step Feedback may be offered — pre-baseline only [PRD §5].
    var allowsStepFeedback: Bool { !isEstablished }
}
