import Foundation

/// The single entry contract into the gait pipeline (docs/08 §8.1).
///
/// "Raw buffer + baseline (optional) → outcome", stamped with a version. The
/// implementation is the stage-composable pipeline in `Algorithms/GaitAnalysis`;
/// `SessionProcessor` is its only caller, and view models never see the
/// internals [PRD Rule 12].
///
/// A v2 algorithm is a new conformance plus a new `version` string — sessions
/// and baselines record the version they were computed under, so the two can
/// coexist without a schema migration (docs/08 §8.2, docs/09 §9.6).
protocol GaitScoringAlgorithm: Sendable {
    /// Stamped onto every result and persisted with the session [PRD].
    var version: String { get }

    /// Analyses a frozen recording.
    ///
    /// - Parameters:
    ///   - buffer: the frozen recording. Its `mode` is the segregation key.
    ///   - baseline: the **same mode's** baseline, or nil before one exists.
    ///     A session is only ever compared with its own mode's baseline
    ///     [PRD OQ-5]; `SessionProcessor` enforces that before calling.
    ///   - profile: the user, or nil. Needed only for the secondary asymmetry
    ///     feature, which is unilateral-only and never fabricated
    ///     (docs/decisions.md entry 13). Gait consistency is computed
    ///     identically for every user regardless of this [PRD OQ-1].
    ///   - progress: called as stages complete, for the Processing screen.
    /// - Returns: a valid or invalid outcome — never both, never neither.
    func analyze(
        buffer: RawSessionBuffer,
        baseline: Baseline?,
        profile: UserProfile?,
        progress: @Sendable (ProcessingProgress) -> Void
    ) async throws -> SessionAnalysisOutcome
}
