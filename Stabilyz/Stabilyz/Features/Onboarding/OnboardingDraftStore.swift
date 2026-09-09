import Foundation

/// The in-progress onboarding wizard's saved state (docs/04 §4.3, docs/05 §5.3).
///
/// Task 8.1.2 owns the draft itself — its fields, its persistence to
/// `UserDefaults`, and resuming the wizard from it. The router needs only one
/// thing from it, and asking for only that keeps 8.1.1 from deciding what a
/// draft contains: **does one exist to resume?** [PRD §6 AC — the wizard
/// resumes mid-flow, including on the final disclaimer screen pre-tick.]
///
/// Non-throwing on purpose. A missing or unreadable draft is not an error
/// condition to surface; it means the wizard starts at the beginning, which is
/// exactly what a first-time user gets anyway.
protocol OnboardingDraftStore: Sendable {
    func hasDraft() async -> Bool
}

/// The store until Task 8.1.2 builds one.
///
/// Not a stand-in guess: nothing in the app writes a draft yet, so "there is no
/// draft to resume" is the literal truth rather than a placeholder answer. It
/// stays correct until the wizard exists to contradict it.
struct EmptyOnboardingDraftStore: OnboardingDraftStore {
    init() {}
    func hasDraft() async -> Bool { false }
}
