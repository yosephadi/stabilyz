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
    /// What "back" does on the first screen — in the app, return the router to
    /// Welcome. Injected rather than reached for, like `onCompleted`, so the
    /// wizard still knows nothing about routing (docs/12 §12.3).
    private let onExit: @MainActor () -> Void

    init(
        store: OnboardingDraftStore,
        profiles: UserProfileRepository,
        clock: Clock,
        logService: LogService,
        onCompleted: @escaping @MainActor () async -> Void,
        onExit: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.profiles = profiles
        self.clock = clock
        self.logService = logService
        self.onCompleted = onCompleted
        self.onExit = onExit
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

    /// The screens that carry a number.
    ///
    /// The disclaimer is not one of them. [PRD §7 AC] asks for a progress
    /// indicator over the screens that present "one field (or tightly grouped
    /// field-set)", and the disclaimer presents no field — it is the consent
    /// gate the flow ends on, and the designs draw it with no counter and no
    /// bar. Counting it would also make the bar full before the user has
    /// consented to anything, which reads as "done" on the one screen where
    /// nothing is yet.
    var numberedSteps: [OnboardingStep] {
        applicableSteps.filter { $0 != .disclaimer }
    }

    /// One-based position and total, for the visible progress indicator
    /// [PRD §7 AC]. `nil` on the screens that carry no number.
    var progress: (step: Int, of: Int)? {
        let steps = numberedSteps
        guard let index = steps.firstIndex(of: draft.step) else { return nil }
        return (index + 1, steps.count)
    }

    /// `nil` wherever `progress` is.
    var progressFraction: Double? {
        progress.map { Double($0.step) / Double($0.of) }
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

    /// Which band the amputation falls into. One of five, and until one is
    /// picked the screen has no answer.
    func select(timeSinceAmputation band: TimeSinceAmputation) {
        draft.timeSinceAmputation = band
        persist()
    }

    /// Optional [PRD AC]. `nil` is a complete answer and means the screen was
    /// skipped; `preferNotToSay` is a different thing — the user was asked and
    /// declined — and is recorded as such rather than collapsed into silence.
    func setProsthesisType(_ type: ProsthesisType?) {
        draft.prosthesisType = type
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
        // Required [PRD §5], and a band has no default. The wheel this replaced
        // was always showing *something*, so "untouched" and "zero months" were
        // indistinguishable; five ranges with none selected is an honestly
        // unanswered screen, and asking for one tap is better than recording an
        // answer the user never gave.
        case .side: draft.side != nil
        case .timeSinceAmputation: draft.timeSinceAmputation != nil
        // Both optional [PRD AC]: neither can block completion.
        case .prosthesisType, .kLevel: true
        case .disclaimer: disclaimerAccepted
        }
    }

    /// Why the button is unavailable, in the user's words. `nil` where there is
    /// nothing to say.
    ///
    /// **The disclaimer only.** [PRD §6] names one case — "the checkbox failing
    /// silently or the Continue button just not responding" — and it is that
    /// screen, where the gate is a tick box the reader may not have noticed is
    /// required. The level and side screens used to carry a line too; those
    /// were ours, and on a screen that is nothing but a list of unchosen
    /// options they restated the obvious under every question.
    ///
    /// The rule lives here rather than in the view so a screen cannot acquire
    /// an explanation by someone adding one to a `case`.
    var blockedExplanation: String? {
        guard !canContinue, draft.step == .disclaimer else { return nil }
        return DisclaimerText.blockedExplanation
    }

    // MARK: - Movement

    /// Advances, or finishes on the last screen.
    func advance() async {
        guard canContinue else { return }

        guard let next = nextStep() else {
            await complete()
            return
        }

        draft.step = next
        persist()
    }

    /// Whether this screen offers "Skip".
    ///
    /// The two optional fields and nothing else [PRD §6 edge case: "user skips
    /// both optional fields"; §7 AC: they can be left blank without blocking
    /// progress]. Level, side and time are required, and the disclaimer is the
    /// one hard gate in the app [PRD §7 AC — there is no skip path to Home], so
    /// none of them may show it.
    var canSkip: Bool { draft.step.isOptionalField }

    /// Leaves an optional field blank and moves on.
    ///
    /// Clears the field rather than merely advancing: skipping a screen the
    /// user had already typed into should not quietly keep the answer they
    /// just chose to abandon.
    func skip() async {
        guard canSkip else { return }

        switch draft.step {
        case .prosthesisType: draft.prosthesisType = nil
        case .kLevel: draft.kLevel = nil
        case .amputationLevel, .side, .timeSinceAmputation, .disclaimer: return
        }
        persist()
        await advance()
    }

    /// Leaves the wizard for Welcome.
    ///
    /// Separate from `back()` rather than folded into it, because the two are
    /// different acts: `canGoBack` asks whether there is a previous *field*,
    /// and on the first screen there is none — what sits behind it is the
    /// Welcome screen, not a step. The draft is kept, so returning resumes
    /// [PRD §6 AC].
    func exitToWelcome() {
        onExit()
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
        guard let level = draft.amputationLevel,
              let side = draft.side,
              let timeSinceAmputation = draft.timeSinceAmputation
        else { return }

        saveFailure = nil
        let now = clock.now

        do {
            let profile = try UserProfile(
                id: UUID(),
                amputationLevel: level,
                side: side,
                // The band's lower bound: the one number in the range that is
                // true of everyone who picked it, and distinct enough that the
                // band is recoverable from it.
                timeSinceAmputationMonths: timeSinceAmputation.lowerBoundMonths,
                prosthesisType: draft.prosthesisType?.rawValue,
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
