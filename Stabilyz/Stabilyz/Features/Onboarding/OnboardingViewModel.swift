import Foundation

/// Drives the onboarding wizard (docs/04 §4.3, docs/11 §11.1).
///
/// Every rule the PRD attaches to onboarding lives here rather than in a view,
/// so all of it is testable without rendering (docs/11 §11.5): the hard
/// disclaimer gate, resuming where the user quit, which fields may be left
/// blank, and the level/side consistency that would otherwise let the wizard
/// build a profile `UserProfile` refuses to construct.
@MainActor
@Observable
final class OnboardingViewModel {
    private(set) var draft: OnboardingDraft

    /// The disclaimer tick. Deliberately **not** part of the draft, so it is
    /// never persisted and never restored [PRD AC — resume lands on this screen
    /// with the box unticked].
    var disclaimerAccepted = false

    /// Set when the profile could not be saved. The wizard stays where it is;
    /// nothing is lost.
    private(set) var saveFailure: StabilyzError?

    private let store: OnboardingDraftStore
    private let profiles: UserProfileRepository
    private let clock: Clock
    private let logService: LogService
    /// What to do once the profile exists — in the app, re-resolve the router,
    /// which lands on Home because a profile now exists.
    private let onCompleted: @MainActor () async -> Void

    init(
        store: OnboardingDraftStore,
        profiles: UserProfileRepository,
        clock: Clock,
        logService: LogService,
        onCompleted: @escaping @MainActor () async -> Void
    ) {
        self.store = store
        self.profiles = profiles
        self.clock = clock
        self.logService = logService
        self.onCompleted = onCompleted
        self.draft = OnboardingDraft()
    }

    // MARK: - Lifecycle

    /// Picks up where the user left off, or starts at the first field
    /// [PRD §6 edge case: force-quit mid-flow].
    func start() async {
        if let saved = await store.load() {
            draft = saved
            logService.log(.info, .app, "onboarding resumed at \(saved.step.rawValue)")
        }
    }

    // MARK: - Position

    var step: OnboardingStep { draft.step }

    /// The screens this draft will actually visit.
    ///
    /// Choosing bilateral answers the side question, so that screen never
    /// appears [PRD §7 AC — bilateral is fully supported, not a dead end]. It
    /// drops out of movement *and* out of the progress indicator: a user who
    /// sees five screens must not be told there are six, or watch the count
    /// jump from one to three.
    ///
    /// The current step is always kept in the list even when it would otherwise
    /// be filtered out. A draft saved on the side screen and resumed after
    /// bilateral was chosen still has a position, so movement stays defined
    /// instead of reading an unknown step as "finished".
    var applicableSteps: [OnboardingStep] {
        guard draft.amputationLevel == .bilateral else { return OnboardingStep.allCases }
        return OnboardingStep.allCases.filter { $0 != .side || $0 == draft.step }
    }

    /// One-based position and total, for the visible progress indicator
    /// [PRD §7 AC].
    var progress: (step: Int, of: Int) {
        let steps = applicableSteps
        return ((steps.firstIndex(of: draft.step) ?? 0) + 1, steps.count)
    }

    var progressFraction: Double {
        Double(progress.step) / Double(progress.of)
    }

    var canGoBack: Bool { draft.step != applicableSteps.first }

    // MARK: - Answers

    /// Choosing a level fixes what a side may be.
    ///
    /// Bilateral records `both` immediately; switching away from bilateral
    /// clears it, because `both` is not a legal answer for a single-limb
    /// amputation and a stale value would silently produce a profile
    /// `UserProfile` throws on.
    func select(level: AmputationLevel) {
        draft.amputationLevel = level
        switch level {
        case .bilateral:
            draft.side = .both
        case .transtibial, .transfemoral:
            if draft.side == .both { draft.side = nil }
        }
        persist()
    }

    func select(side: AmputationSide) {
        guard allowedSides.contains(side) else { return }
        draft.side = side
        persist()
    }

    /// Months since amputation. Zero is a real answer — someone two weeks
    /// post-amputation is zero months — so this screen has no invalid state.
    func setTimeSinceAmputation(months: Int) {
        draft.timeSinceAmputationMonths = max(0, months)
        persist()
    }

    /// Optional [PRD AC]. Blank stays blank rather than becoming an empty
    /// string, so "not answered" reads the same in the store as it does here.
    func setProsthesisType(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.prosthesisType = trimmed.isEmpty ? nil : trimmed
        persist()
    }

    /// Optional [PRD AC].
    func setKLevel(_ level: KLevel?) {
        draft.kLevel = level
        persist()
    }

    var allowedSides: [AmputationSide] {
        OnboardingDraft.allowedSides(for: draft.amputationLevel)
    }

    // MARK: - Gating

    /// Whether the primary button does anything on this screen.
    var canContinue: Bool {
        switch draft.step {
        case .amputationLevel: draft.amputationLevel != nil
        case .side: draft.side != nil
        // Zero months is an answer, and both of these are optional [PRD AC]:
        // none of the three can block completion.
        case .timeSinceAmputation, .prosthesisType, .kLevel: true
        case .disclaimer: disclaimerAccepted
        }
    }

    /// Why the button is unavailable, in the user's words.
    ///
    /// [PRD §6] A checkbox that fails silently or a Continue button that simply
    /// does not respond is the failure mode this exists to prevent: whenever
    /// `canContinue` is false, this is non-nil and on screen.
    var blockedExplanation: String? {
        guard !canContinue else { return nil }

        return switch draft.step {
        case .amputationLevel:
            "Choose the option that matches your amputation to continue."
        case .side:
            "Choose which side to continue."
        case .disclaimer:
            DisclaimerText.blockedExplanation
        case .timeSinceAmputation, .prosthesisType, .kLevel:
            // Unreachable: these never block. Non-nil anyway, so that a future
            // gate added to one of them cannot produce a silent dead end.
            "Answer this question to continue."
        }
    }

    // MARK: - Movement

    /// Advances, or finishes on the last screen.
    func advance() async {
        guard canContinue else { return }

        if draft.step == .timeSinceAmputation, draft.timeSinceAmputationMonths == nil {
            // The wheel was never touched. Zero is what it was showing, and
            // zero is a real answer, so record it rather than carry a nil into
            // a required field.
            draft.timeSinceAmputationMonths = 0
        }

        guard let next = nextStep() else {
            await complete()
            return
        }

        draft.step = next
        persist()
    }

    /// Back one screen, skipping any the current level does not visit — so a
    /// bilateral user returns from "how long ago" straight to the level screen.
    func back() {
        let steps = applicableSteps
        guard let index = steps.firstIndex(of: draft.step), index > 0 else { return }
        draft.step = steps[index - 1]
        persist()
    }

    private func nextStep() -> OnboardingStep? {
        let steps = applicableSteps
        guard let index = steps.firstIndex(of: draft.step) else { return nil }
        let next = index + 1
        return next < steps.count ? steps[next] : nil
    }

    // MARK: - Completion

    /// Saves the profile and hands the app back to the router.
    ///
    /// The disclaimer is re-checked here rather than trusted from the caller:
    /// this is the only function in the app that can create a profile, and
    /// [PRD §7] says there is no path to Home without the tick.
    private func complete() async {
        guard disclaimerAccepted else { return }
        guard let level = draft.amputationLevel, let side = draft.side else { return }

        saveFailure = nil
        let now = clock.now

        do {
            let profile = try UserProfile(
                id: UUID(),
                amputationLevel: level,
                side: side,
                timeSinceAmputationMonths: draft.timeSinceAmputationMonths ?? 0,
                prosthesisType: draft.prosthesisType,
                kLevel: draft.kLevel,
                disclaimerAcceptedAt: now,
                createdAt: now
            )
            try await profiles.save(profile)
            // Only now: a draft that outlived its wizard would send the next
            // launch straight back into onboarding.
            await store.clear()
            logService.log(.info, .app, "onboarding complete")
            await onCompleted()
        } catch let error as StabilyzError {
            saveFailure = error
            logService.log(.error, .app, "onboarding could not save the profile")
        } catch {
            saveFailure = .persistence(.saveFailed)
            logService.log(.error, .app, "onboarding could not build a valid profile")
        }
    }

    /// Writes the draft after every answer, so "resume where you left off" does
    /// not depend on the app being given a chance to shut down cleanly.
    private func persist() {
        let snapshot = draft
        Task { await store.save(snapshot) }
    }
}
