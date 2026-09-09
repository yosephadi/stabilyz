import Foundation

/// Baseline storage, keyed by mode (docs/06 §6.3, docs/05 §5.1).
///
/// Uniqueness invariant: at most one baseline per `TestMode`, enforced by a
/// store-level constraint and a repository-level assertion — a structural
/// guarantee of [PRD OQ-5]. Baselines are frozen once established in v1.
protocol BaselineRepository: Sendable {
    func baseline(mode: TestMode) async throws -> Baseline?

    /// Throws if a baseline already exists for that mode.
    func save(_ baseline: Baseline) async throws

    /// Both modes' baselines, for the clinician summary and export.
    func allBaselines() async throws -> [Baseline]
}
