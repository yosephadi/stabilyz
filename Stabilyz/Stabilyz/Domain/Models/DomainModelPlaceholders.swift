import Foundation

// MARK: - Placeholders for EPIC 2 domain models
//
// The service-protocol skeleton (Task 1.2.1, docs/22 Phase 1) has to name the
// domain types the repositories store, but those types are defined in EPIC 2
// (docs/23-engineering-task-breakdown.md Tasks 2.1.1–2.1.5, spec in
// docs/05-domain-data-model.md).
//
// These are deliberately minimal stand-ins so the protocol signatures compile.
// They carry ONLY the identity fields the repository APIs need. Do not add
// product fields here — fill them in via the owning task below.

/// Placeholder — full definition in Task 2.1.1 (docs/05 §5.1).
/// Only the two PRD-locked cases are declared here; `advertisedDuration`,
/// `minimumValidWalkingDuration` and the versioned `SessionPolicy` belong to 2.1.1.
nonisolated enum TestMode: String, Sendable, CaseIterable, Codable {
    case quickTest
    case fullTest
}

/// Placeholder — full definition in Task 2.1.5 (docs/05 §5.1).
nonisolated struct UserProfile: Sendable, Equatable, Identifiable {
    let id: UUID

    init(id: UUID) {
        self.id = id
    }
}

/// Placeholder — full definition in Task 2.1.2 (docs/05 §5.1).
nonisolated struct GaitSession: Sendable, Equatable, Identifiable {
    let id: UUID
    let mode: TestMode

    init(id: UUID, mode: TestMode) {
        self.id = id
        self.mode = mode
    }
}

/// Placeholder — full definition in Task 2.1.4 (docs/05 §5.1).
/// `mode` is PRD-locked on Baseline [PRD OQ-5] and is therefore present already.
nonisolated struct Baseline: Sendable, Equatable, Identifiable {
    let id: UUID
    let mode: TestMode

    init(id: UUID, mode: TestMode) {
        self.id = id
        self.mode = mode
    }
}
