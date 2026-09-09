import Foundation

/// The in-progress onboarding wizard's saved state (docs/04 §4.3, docs/05 §5.3).
///
/// Non-throwing on purpose. A missing or unreadable draft is not an error
/// condition to surface; it means the wizard starts at the beginning, which is
/// exactly what a first-time user gets anyway.
protocol OnboardingDraftStore: Sendable {
    /// Whether there is something to resume [PRD §6 AC]. The router asks only
    /// this, so routing never depends on what a draft contains.
    func hasDraft() async -> Bool
    func load() async -> OnboardingDraft?
    func save(_ draft: OnboardingDraft) async
    /// Called once the profile exists. A draft that outlived its wizard would
    /// send the next launch back into onboarding.
    func clear() async
}

extension OnboardingDraftStore {
    func hasDraft() async -> Bool { await load() != nil }
}

/// `UserDefaults`-backed, per docs/05 §5.3 — the draft is pre-profile,
/// ephemeral and tiny, so it never enters the SwiftData store.
///
/// `@unchecked Sendable` because `UserDefaults` is documented as thread-safe
/// but is not marked `Sendable`; nothing else here is mutable state.
struct UserDefaultsOnboardingDraftStore: OnboardingDraftStore, @unchecked Sendable {
    /// Namespaced so it cannot collide with anything else the app stores.
    static let key = "com.stabilyz.onboarding.draft"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() async -> OnboardingDraft? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }

        do {
            return try JSONDecoder().decode(OnboardingDraft.self, from: data)
        } catch {
            // A draft written by an older build, or corrupted. Starting the
            // wizard over costs a few taps; showing an error about a file the
            // user never knew existed costs their confidence.
            defaults.removeObject(forKey: Self.key)
            return nil
        }
    }

    func save(_ draft: OnboardingDraft) async {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() async {
        defaults.removeObject(forKey: Self.key)
    }
}

/// The store for previews and for code paths that must not resume anything.
struct EmptyOnboardingDraftStore: OnboardingDraftStore {
    init() {}
    func hasDraft() async -> Bool { false }
    func load() async -> OnboardingDraft? { nil }
    func save(_ draft: OnboardingDraft) async {}
    func clear() async {}
}
