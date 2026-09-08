import Foundation

/// Session storage with the mode- and validity-filtered queries History, the
/// trend chart and baseline counting rely on (docs/06 §6.2, docs/05 §5.2).
///
/// Every query takes an explicit `TestMode` — the segregation key [PRD OQ-5].
/// Invalid sessions are retained locally for diagnostics but are excluded from
/// History, baseline counting and export; callers opt into them explicitly.
nonisolated protocol GaitSessionRepository: Sendable {
    func save(_ session: GaitSession) async throws

    func session(id: UUID) async throws -> GaitSession?

    /// Date-ordered, newest first. `includeInvalid` defaults to false at the call
    /// site so the History/export paths cannot pick up invalid sessions by accident.
    func sessions(mode: TestMode, includeInvalid: Bool, limit: Int?) async throws -> [GaitSession]

    /// Drives the "X of 5" building state and the baseline commit trigger
    /// (docs/05 §5.1 `BaselineState`). Counts valid sessions only.
    func validSessionCount(mode: TestMode) async throws -> Int
}
