/// Derives a mode's `BaselineState` (docs/09 §9.4).
///
/// Pure and stateless. The valid-session count is **recomputed** from persisted
/// sessions rather than held as a mutable counter, so a failed or rolled-back
/// commit cannot corrupt it [REC — docs/09 §9.4].
///
/// Every entry point takes an explicit `TestMode`. A baseline belonging to a
/// different mode is rejected rather than tolerated: cross-mode mixing is the
/// one thing the PRD forbids outright [PRD OQ-5].
enum BaselineStateMachine {
    enum StateError: Error, Equatable {
        /// A baseline for a different mode was supplied — a caller bug that
        /// would otherwise silently blend the two modes.
        case baselineModeMismatch(expected: TestMode, actual: TestMode)
        case negativeValidSessionCount(Int)
    }

    /// - Parameters:
    ///   - mode: the mode being asked about.
    ///   - validSessionCount: valid sessions of **that mode only**. Invalid
    ///     sessions never advance the counter [PRD §6, §7].
    ///   - baseline: that mode's persisted baseline, if one exists.
    static func state(
        for mode: TestMode,
        validSessionCount: Int,
        baseline: Baseline?
    ) throws -> BaselineState {
        guard validSessionCount >= 0 else {
            throw StateError.negativeValidSessionCount(validSessionCount)
        }
        if let baseline, baseline.mode != mode {
            throw StateError.baselineModeMismatch(expected: mode, actual: baseline.mode)
        }

        if let baseline {
            // Frozen for v1: later sessions never update it [PRD §6].
            return .established(baseline)
        }
        if validSessionCount == 0 {
            return .notStarted
        }
        if validSessionCount >= Baseline.requiredValidSessionCount {
            // Enough walks, and still no baseline: the calculation refused them
            // (docs/decisions.md entry 17). Its own state rather than
            // `building(7)`, which every "X of 5" would print as "7 of 5".
            return .baselineRefused(validCount: validSessionCount)
        }
        return .building(validCount: validSessionCount)
    }

    /// Whether this mode's baseline should be created now — the 5th valid
    /// session has committed but no baseline exists yet (docs/09 §9.4).
    ///
    /// Normally true for exactly one commit. It stays true if that commit was
    /// rolled back, which is why the count is derived rather than stored.
    static func isReadyToEstablish(validSessionCount: Int, baseline: Baseline?) -> Bool {
        baseline == nil && validSessionCount >= Baseline.requiredValidSessionCount
    }
}
