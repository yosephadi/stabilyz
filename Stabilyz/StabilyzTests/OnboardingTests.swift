import Foundation
import Testing
@testable import Stabilyz

// MARK: - Doubles

private final class OnboardingLog: LogService, @unchecked Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

private struct OnboardingClock: Clock {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let uptime: TimeInterval = 0
}

/// A draft store a test can inspect, standing in for UserDefaults.
private actor MemoryDraftStore: OnboardingDraftStore {
    private(set) var draft: OnboardingDraft?
    private(set) var clearCount = 0

    init(draft: OnboardingDraft? = nil) { self.draft = draft }

    func hasDraft() async -> Bool { draft != nil }
    func load() async -> OnboardingDraft? { draft }
    func save(_ draft: OnboardingDraft) async { self.draft = draft }
    func clear() async {
        draft = nil
        clearCount += 1
    }
}

private actor RecordingProfiles: UserProfileRepository {
    private(set) var saved: UserProfile?
    private var failure: StabilyzError?

    init(failure: StabilyzError? = nil) { self.failure = failure }

    func fetchProfile() async throws -> UserProfile? { saved }
    func save(_ profile: UserProfile) async throws {
        if let failure { throw failure }
        saved = profile
    }
}

@MainActor
private func makeModel(
    store: OnboardingDraftStore = MemoryDraftStore(),
    profiles: UserProfileRepository = RecordingProfiles(),
    onCompleted: @escaping @MainActor () async -> Void = {}
) -> OnboardingViewModel {
    OnboardingViewModel(
        store: store,
        profiles: profiles,
        clock: OnboardingClock(),
        logService: OnboardingLog(),
        onCompleted: onCompleted
    )
}

/// Walks the wizard to the end with the required answers only, leaving both
/// optional fields blank.
@MainActor
private func fillRequiredFields(_ model: OnboardingViewModel, level: AmputationLevel = .transtibial, side: AmputationSide = .left) async {
    model.select(level: level)
    await model.advance()
    if model.draft.side == nil { model.select(side: side) }
    await model.advance()
    model.setTimeSinceAmputation(months: 30)
    await model.advance()
    await model.advance()   // prosthesis, left blank
    await model.advance()   // K-level, left blank
}

// MARK: - The disclaimer gate [PRD §7 AC — no skip path]

@MainActor
@Test func thereIsNoPathToAProfileWithoutTheTick() async {
    let profiles = RecordingProfiles()
    let model = makeModel(profiles: profiles)
    await fillRequiredFields(model)
    #expect(model.step == .disclaimer)

    // Every way forward, tried without ticking.
    await model.advance()
    await model.advance()
    await model.advance()

    #expect(model.step == .disclaimer, "the wizard moved past the disclaimer")
    #expect(await profiles.saved == nil, "a profile was created without the disclaimer")
}

@MainActor
@Test func tickingTheBoxIsWhatCompletesOnboarding() async {
    let profiles = RecordingProfiles()
    let model = makeModel(profiles: profiles)
    await fillRequiredFields(model)

    await model.advance()
    #expect(await profiles.saved == nil)

    model.disclaimerAccepted = true
    await model.advance()

    let saved = try! #require(await profiles.saved)
    #expect(saved.hasAcceptedDisclaimer)
    #expect(saved.disclaimerAcceptedAt == OnboardingClock().now)
}

@MainActor
@Test func theDisclaimerIsTheOnlyScreenThatExplainsItsBlock() async {
    // [PRD §6] names one case: the disclaimer checkbox, where the gate is easy
    // to miss. Everywhere else the wizard says nothing — a choice screen with
    // nothing chosen is its own explanation, and a line under every question
    // restating that is the helper text this flow deliberately does not have.
    for step in OnboardingStep.allCases {
        let model = makeModel(store: MemoryDraftStore(draft: OnboardingDraft(step: step)))
        await model.start()

        if step == .disclaimer {
            #expect(model.canContinue == false)
            #expect(model.blockedExplanation == DisclaimerText.blockedExplanation)
        } else {
            #expect(model.blockedExplanation == nil, "\(step) carries helper text")
        }
    }
}

@MainActor
@Test func theDisclaimerScreenSaysWhyItCannotBeSkipped() async {
    let model = makeModel(store: MemoryDraftStore(draft: OnboardingDraft(step: .disclaimer)))
    await model.start()

    #expect(model.canContinue == false)
    #expect(model.blockedExplanation == DisclaimerText.blockedExplanation)

    model.disclaimerAccepted = true
    #expect(model.canContinue)
    #expect(model.blockedExplanation == nil)
}

@Test func theDisclaimerTextLivesInOneePlaceAndSaysWhatItMust() {
    // [PRD §7 AC] Settings shows this same text later, without the checkbox.
    #expect(DisclaimerText.body.localizedCaseInsensitiveContains("not a medical device"))
    #expect(DisclaimerText.acknowledgement.localizedCaseInsensitiveContains("not a medical device"))
    // Non-diagnostic: it must not promise to detect or diagnose anything.
    #expect(DisclaimerText.body.localizedCaseInsensitiveContains("does not provide clinical diagnoses"))
    // The reader is pointed at a person, not at a future score [PRD §7 AC].
    #expect(DisclaimerText.body.localizedCaseInsensitiveContains("prosthetist"))
    #expect(DisclaimerText.body.isEmpty == false)
}

/// Every string the disclaimer shows, so a clause break added later cannot
/// reintroduce the character.
@Test func theDisclaimerUsesNoEmDashes() {
    let copy = [
        DisclaimerText.title,
        DisclaimerText.body,
        DisclaimerText.acknowledgement,
        DisclaimerText.blockedExplanation
    ]

    for text in copy {
        // An em dash is set as one long rule with no surrounding space: at 17pt
        // it reads as a hyphen joining two words, and VoiceOver skips it.
        #expect(text.contains("\u{2014}") == false, "em dash in \"\(text)\"")
        #expect(text.contains("\u{2013}") == false, "en dash in \"\(text)\"")
    }
}

/// The one line the wizard shows above a disabled button.
@Test func theBlockedExplanationIsASingleShortSentence() {
    let text = DisclaimerText.blockedExplanation

    #expect(text == "Check the box above to continue.")
    #expect(text.filter { $0 == "." }.count == 1, "more than one sentence")
}

// MARK: - Resume [PRD §6 edge case, §7 AC]

@MainActor
@Test func resumingLandsExactlyWhereTheUserQuit() async {
    for step in OnboardingStep.allCases {
        let store = MemoryDraftStore(draft: OnboardingDraft(step: step, amputationLevel: .transfemoral, side: .right))
        let model = makeModel(store: store)

        await model.start()

        #expect(model.step == step)
    }
}

@MainActor
@Test func resumingOnTheDisclaimerScreenLeavesTheBoxUnticked() async {
    // [PRD AC] The exact case the PRD calls out. An acknowledgement is an
    // affirmative act; a box that came back ticked would be the app remembering
    // a consent that was never finished.
    let store = MemoryDraftStore(draft: OnboardingDraft(
        step: .disclaimer,
        amputationLevel: .transtibial,
        side: .left,
        timeSinceAmputationMonths: 12
    ))
    let model = makeModel(store: store)

    await model.start()

    #expect(model.step == .disclaimer)
    #expect(model.disclaimerAccepted == false)
    #expect(model.canContinue == false)
}

@MainActor
@Test func theTickIsNeverWrittenToTheDraft() async {
    // Belt and braces on the same rule: even mid-screen, nothing persists it.
    let store = MemoryDraftStore()
    let model = makeModel(store: store)
    await fillRequiredFields(model)
    model.disclaimerAccepted = true

    // Anything that persists after the tick must still not carry it.
    model.back()
    await Task.yield()

    let saved = await store.draft
    let encoded = String(decoding: try! JSONEncoder().encode(saved), as: UTF8.self)
    #expect(encoded.localizedCaseInsensitiveContains("disclaimer") == false, "the draft carries the tick: \(encoded)")
}

@MainActor
@Test func answersSurviveTheQuitThatComesBeforeThem() async {
    // The draft is written after every answer, not on the way out, because a
    // force-quit gives no chance to save.
    let store = MemoryDraftStore()
    let model = makeModel(store: store)

    model.select(level: .bilateral)
    await Task.yield()
    #expect(await store.draft?.amputationLevel == .bilateral)

    model.setTimeSinceAmputation(months: 7)
    await Task.yield()
    #expect(await store.draft?.timeSinceAmputationMonths == 7)
}

@MainActor
@Test func aFreshStartWithNoDraftBeginsAtTheFirstField() async {
    let model = makeModel()
    await model.start()

    #expect(model.step == .amputationLevel)
    #expect(model.progress?.step == 1)
    #expect(model.progress?.of == 5)
}

// MARK: - Optional fields never block [PRD §7 AC]

@MainActor
@Test func onboardingCompletesWithOnlyTheRequiredFields() async {
    let profiles = RecordingProfiles()
    let model = makeModel(profiles: profiles)

    await fillRequiredFields(model)
    model.disclaimerAccepted = true
    await model.advance()

    let saved = try! #require(await profiles.saved)
    #expect(saved.prosthesisType == nil)
    #expect(saved.kLevel == nil)
    #expect(saved.timeSinceAmputationMonths == 30)
}

@MainActor
@Test func theOptionalStepsNeverBlockTheButton() async {
    for step in [OnboardingStep.prosthesisType, .kLevel] {
        let model = makeModel(store: MemoryDraftStore(draft: OnboardingDraft(step: step)))
        await model.start()

        #expect(model.canContinue, "\(step) blocked with nothing filled in")
        #expect(step.isOptionalField)
    }
}

@MainActor
@Test func blankTextIsStoredAsNoAnswerRatherThanAnEmptyString() async {
    let model = makeModel()
    model.setProsthesisType("   ")
    #expect(model.draft.prosthesisType == nil)

    model.setProsthesisType("  Ottobock C-Leg ")
    #expect(model.draft.prosthesisType == "Ottobock C-Leg")
}

@MainActor
@Test func zeroMonthsIsARealAnswerNotAMissingOne() async {
    // Someone two weeks post-amputation is zero months, so this screen has no
    // invalid state — and an untouched wheel records the zero it was showing.
    let profiles = RecordingProfiles()
    let model = makeModel(profiles: profiles)

    model.select(level: .transtibial)
    await model.advance()
    model.select(side: .right)
    await model.advance()
    #expect(model.canContinue, "the time screen blocked before it was touched")
    await model.advance()

    #expect(model.draft.timeSinceAmputationMonths == 0)

    await model.advance()
    await model.advance()
    model.disclaimerAccepted = true
    await model.advance()

    #expect(await profiles.saved?.timeSinceAmputationMonths == 0)
}

// MARK: - Level / side consistency [REC, and UserProfile throws otherwise]

@MainActor
@Test func bilateralIsFullySupportedAndRecordsBothSides() async {
    // [PRD AC] Not a dead end: it completes, and it completes as `both`.
    let profiles = RecordingProfiles()
    let model = makeModel(profiles: profiles)

    await fillRequiredFields(model, level: .bilateral)
    model.disclaimerAccepted = true
    await model.advance()

    let saved = try! #require(await profiles.saved)
    #expect(saved.amputationLevel == .bilateral)
    #expect(saved.side == .both)
    #expect(saved.supportsStepTimeAsymmetry == false)
}

@MainActor
@Test func choosingBilateralSettlesTheSideImmediately() async {
    let model = makeModel()
    model.select(level: .bilateral)

    #expect(model.draft.side == .both)
    #expect(model.allowedSides == [.both])
    #expect(model.canContinue)
}

@MainActor
@Test func aUnilateralUserIsNeverOfferedBoth() async {
    // The wizard cannot build the pairing `UserProfile` would throw on.
    let model = makeModel()
    model.select(level: .transfemoral)

    #expect(model.allowedSides == [.left, .right])

    model.select(side: .both)
    #expect(model.draft.side == nil, "a unilateral profile accepted 'both'")
}

@MainActor
@Test func changingFromBilateralClearsTheSideThatNoLongerApplies() async {
    // A stale `both` would sail through the wizard and throw at the very end.
    let model = makeModel()
    model.select(level: .bilateral)
    #expect(model.draft.side == .both)

    model.select(level: .transtibial)
    #expect(model.draft.side == nil)

    // The level screen itself is answered, so it continues; the side screen is
    // where the cleared answer has to be given again.
    #expect(model.canContinue)
    await model.advance()

    #expect(model.step == .side)
    #expect(model.canContinue == false, "the side must be answered again")
    #expect(model.blockedExplanation == nil, "the side screen carries helper text")
}

@MainActor
@Test func everyLevelAndSidePairTheWizardCanProduceBuildsAValidProfile() async {
    // The consistency rule, checked against the type that enforces it.
    for level in AmputationLevel.allCases {
        for side in OnboardingDraft.allowedSides(for: level) {
            let profiles = RecordingProfiles()
            let model = makeModel(profiles: profiles)
            await fillRequiredFields(model, level: level, side: side)
            model.disclaimerAccepted = true
            await model.advance()

            #expect(await profiles.saved != nil, "\(level)/\(side) produced no profile")
        }
    }
}

// MARK: - One field per screen, with progress [PRD §7 AC]

@MainActor
@Test func everyStepIsOneFieldAndTheProgressIsVisible() async {
    let model = makeModel()

    var seen: [OnboardingStep] = []
    var positions: [Int?] = []

    model.select(level: .transtibial)
    seen.append(model.step)
    positions.append(model.progress?.step)
    await model.advance()

    model.select(side: .left)
    seen.append(model.step)
    positions.append(model.progress?.step)
    await model.advance()

    for _ in 0..<3 {
        seen.append(model.step)
        positions.append(model.progress?.step)
        await model.advance()
    }
    seen.append(model.step)
    positions.append(model.progress?.step)

    #expect(seen == OnboardingStep.allCases)
    // Five numbered questions, then the disclaimer — a consent gate rather than
    // a field, so it carries no number and draws no bar.
    #expect(positions == [1, 2, 3, 4, 5, nil])
    #expect(model.step == .disclaimer)
    #expect(model.progress == nil)
}

@MainActor
@Test func theDisclaimerIsNotCountedAmongTheQuestions() async {
    // The count the user reads on the first screen has to be the number of
    // questions they will actually be asked — Figma 40:835 says "1 out of 5",
    // and there are six screens.
    let model = makeModel()

    #expect(model.progress?.of == 5)
    #expect(model.numberedSteps.contains(.disclaimer) == false)
    #expect(model.applicableSteps.contains(.disclaimer), "the disclaimer left the flow, not just the count")
}

@MainActor
@Test func theProgressFractionAdvancesAndEndsFullOnTheLastQuestion() async {
    let model = makeModel()
    let first = model.progressFraction

    model.select(level: .transtibial)
    await model.advance()
    model.select(side: .left)
    await model.advance()
    model.setTimeSinceAmputation(months: 30)
    await model.advance()
    await model.advance()   // prosthesis, left blank

    #expect(model.step == .kLevel)
    #expect(first ?? 0 < model.progressFraction ?? 0)
    #expect(model.progressFraction == 1.0, "the bar is not full on the last question")

    await model.advance()

    // Full on the last question, absent on the gate after it — never full
    // *before* the user has consented to anything.
    #expect(model.step == .disclaimer)
    #expect(model.progressFraction == nil)
}

@MainActor
@Test func goingBackReturnsToThePreviousFieldWithItsAnswerIntact() async {
    let model = makeModel()
    model.select(level: .transfemoral)
    await model.advance()
    model.select(side: .right)
    await model.advance()

    #expect(model.step == .timeSinceAmputation)
    model.back()

    #expect(model.step == .side)
    #expect(model.draft.side == .right)
    #expect(model.canGoBack)
}

@MainActor
@Test func thereIsNoBackFromTheFirstScreen() async {
    let model = makeModel()
    #expect(model.canGoBack == false)

    model.back()
    #expect(model.step == .amputationLevel)
}

// MARK: - Completion

@MainActor
@Test func completingClearsTheDraftSoTheNextLaunchGoesHome() async {
    let store = MemoryDraftStore()
    let model = makeModel(store: store)
    await fillRequiredFields(model)
    model.disclaimerAccepted = true

    await model.advance()

    #expect(await store.draft == nil)
    #expect(await store.clearCount == 1)
    #expect(await store.hasDraft() == false)
}

@MainActor
@Test func completingHandsTheAppBackToTheRouter() async {
    let handedBack = Handoff()
    let model = makeModel(onCompleted: { await handedBack.record() })
    await fillRequiredFields(model)
    model.disclaimerAccepted = true

    await model.advance()

    #expect(await handedBack.count == 1)
}

private actor Handoff {
    private(set) var count = 0
    func record() { count += 1 }
}

@MainActor
@Test func aFailedSaveKeepsTheUserOnTheDisclaimerWithTheirAnswersIntact() async {
    // Nothing is lost and nothing is half-done: no profile, no cleared draft.
    let store = MemoryDraftStore()
    let model = makeModel(store: store, profiles: RecordingProfiles(failure: .persistence(.saveFailed)))
    await fillRequiredFields(model)
    model.disclaimerAccepted = true

    await model.advance()

    #expect(model.step == .disclaimer)
    #expect(model.saveFailure == .persistence(.saveFailed))
    #expect(await store.clearCount == 0, "the draft was cleared without a profile to replace it")
    #expect(ErrorPresenter.presentation(for: .persistence(.saveFailed)) != nil)
}

@MainActor
@Test func theCompletedProfileReachesTheRouterAsHome() async {
    // The wizard's last act plus the router's re-read: the two halves of
    // "onboarding ends at Home", with no special route between them.
    let profiles = RecordingProfiles()
    let router = AppRouter(
        profiles: profiles,
        drafts: EmptyOnboardingDraftStore(),
        logService: OnboardingLog()
    )
    let model = makeModel(profiles: profiles, onCompleted: { await router.resolve() })

    await router.resolve()
    #expect(router.phase == .firstLaunch)

    await fillRequiredFields(model)
    model.disclaimerAccepted = true
    await model.advance()

    #expect(router.phase == .main)
}

// MARK: - The draft store itself

@Test func aDraftSurvivesTheRoundTripThroughUserDefaults() async {
    let defaults = UserDefaults(suiteName: "stabilyz.tests.\(UUID().uuidString)")!
    let store = UserDefaultsOnboardingDraftStore(defaults: defaults)
    let draft = OnboardingDraft(
        step: .kLevel,
        amputationLevel: .transfemoral,
        side: .right,
        timeSinceAmputationMonths: 42,
        prosthesisType: "Ottobock C-Leg",
        kLevel: .k3
    )

    #expect(await store.hasDraft() == false)
    await store.save(draft)

    #expect(await store.hasDraft())
    #expect(await store.load() == draft)

    await store.clear()
    #expect(await store.load() == nil)
    #expect(await store.hasDraft() == false)
}

@Test func anUnreadableDraftStartsTheWizardOverInsteadOfFailing() async {
    // A draft written by an older build is not something to show the user an
    // error about; it is a few taps.
    let defaults = UserDefaults(suiteName: "stabilyz.tests.\(UUID().uuidString)")!
    defaults.set(Data("not a draft".utf8), forKey: UserDefaultsOnboardingDraftStore.key)
    let store = UserDefaultsOnboardingDraftStore(defaults: defaults)

    #expect(await store.load() == nil)
    // And it does not sit there failing to decode on every launch.
    #expect(defaults.data(forKey: UserDefaultsOnboardingDraftStore.key) == nil)
}

@Test func theEmptyStoreStillReportsNothingToResume() async {
    let store = EmptyOnboardingDraftStore()
    await store.save(OnboardingDraft(step: .disclaimer))

    #expect(await store.hasDraft() == false)
    #expect(await store.load() == nil)
}

// MARK: - Bilateral skips the side screen (Task 8.1.5)

/// Choosing bilateral answers the side question, so that screen is not shown
/// again [PRD §7 AC — bilateral is fully supported, not a dead end]. These pin
/// the navigation, both directions, and the progress indicator that has to
/// agree with it.

@MainActor
@Test func bilateralGoesStraightFromLevelToTimeSinceAmputation() async {
    let model = makeModel()

    model.select(level: .bilateral)
    #expect(model.step == .amputationLevel)
    #expect(model.draft.side == .both, "bilateral did not settle the side")

    await model.advance()

    #expect(model.step == .timeSinceAmputation, "the side screen was shown to a bilateral user")
}

@MainActor
@Test func backFromTimeSinceReturnsToLevelWhenBilateral() async {
    let model = makeModel()
    model.select(level: .bilateral)
    await model.advance()
    #expect(model.step == .timeSinceAmputation)

    model.back()

    #expect(model.step == .amputationLevel, "back landed on the skipped side screen")
}

@MainActor
@Test func aUnilateralUserStillSeesTheSideScreenInBothDirections() async {
    // The mirror: the skip must be bilateral-only, or it would strand a
    // unilateral user with no way to say which side.
    let model = makeModel()
    model.select(level: .transtibial)

    await model.advance()
    #expect(model.step == .side)

    model.select(side: .left)
    await model.advance()
    #expect(model.step == .timeSinceAmputation)

    model.back()
    #expect(model.step == .side)
}

@MainActor
@Test func theProgressIndicatorCountsOnlyTheScreensBilateralVisits() async {
    // A user who sees five screens must not be told there are six, nor watch
    // the count jump from one to three.
    let model = makeModel()
    model.select(level: .bilateral)

    #expect(model.progress?.step == 1)
    #expect(model.progress?.of == 4, "bilateral was told there are more questions than it will be asked")

    await model.advance()
    #expect(model.progress?.step == 2)
    #expect(model.progress?.of == 4)

    var seen: [OnboardingStep] = [.amputationLevel, .timeSinceAmputation]
    for _ in 0..<2 {
        await model.advance()
        seen.append(model.step)
    }

    #expect(seen.contains(.side) == false)
    #expect(model.step == .kLevel)
    #expect(model.progress?.step == 4)
    #expect(model.progressFraction == 1.0)

    await model.advance()
    #expect(model.step == .disclaimer)
    #expect(model.progress == nil)
}

@MainActor
@Test func switchingToBilateralOnTheSideScreenLeavesAWayForward() async {
    // A draft resumed on the side screen after bilateral was chosen still has
    // a position: the step stays reachable rather than reading as "finished"
    // and completing the wizard early.
    let model = makeModel(store: MemoryDraftStore(draft: OnboardingDraft(step: .side, amputationLevel: .bilateral, side: .both)))
    await model.start()

    #expect(model.step == .side)
    #expect(model.canContinue)

    await model.advance()

    #expect(model.step == .timeSinceAmputation, "the wizard skipped to the end from a stale side step")
}

// MARK: - Skip, on the optional fields only (Task 8.1.6)

/// [PRD §6 edge case] "User skips both optional fields (device type, K-level).
/// Onboarding must complete successfully with only the required fields filled."
/// [PRD §7 AC] The disclaimer is the one hard gate — there is no skip path to
/// Home, so the affordance must never appear there either.

@MainActor
@Test func onlyTheTwoOptionalScreensOfferSkip() async {
    for step in OnboardingStep.allCases {
        let model = makeModel(store: MemoryDraftStore(draft: OnboardingDraft(step: step)))
        await model.start()

        #expect(
            model.canSkip == (step == .prosthesisType || step == .kLevel),
            "\(step) offers the wrong skip affordance"
        )
    }
}

@MainActor
@Test func skippingAnOptionalFieldLeavesItBlankAndMovesOn() async {
    let model = makeModel(store: MemoryDraftStore(draft: OnboardingDraft(step: .prosthesisType)))
    await model.start()

    model.setProsthesisType("Genium X3")
    #expect(model.draft.prosthesisType != nil)

    await model.skip()

    #expect(model.draft.prosthesisType == nil, "skip kept an answer the user abandoned")
    #expect(model.step == .kLevel)
}

@MainActor
@Test func skippingKLevelClearsItToo() async {
    let model = makeModel(store: MemoryDraftStore(draft: OnboardingDraft(step: .kLevel)))
    await model.start()

    model.setKLevel(.k3)
    await model.skip()

    #expect(model.draft.kLevel == nil)
    #expect(model.step == .disclaimer)
}

@MainActor
@Test func skipDoesNothingOnARequiredScreen() async {
    // Belt and braces against a view that showed the button anyway: the model
    // refuses, rather than trusting the caller.
    for step in [OnboardingStep.amputationLevel, .side, .timeSinceAmputation, .disclaimer] {
        let model = makeModel(store: MemoryDraftStore(draft: OnboardingDraft(step: step)))
        await model.start()

        await model.skip()

        #expect(model.step == step, "\(step) was skipped")
    }
}

@MainActor
@Test func skippingBothOptionalFieldsStillCompletesOnboarding() async {
    // The PRD edge case, end to end.
    let profiles = RecordingProfiles()
    let model = makeModel(profiles: profiles)

    model.select(level: .transtibial)
    await model.advance()
    model.select(side: .left)
    await model.advance()
    model.setTimeSinceAmputation(months: 18)
    await model.advance()

    #expect(model.step == .prosthesisType)
    await model.skip()
    #expect(model.step == .kLevel)
    await model.skip()

    #expect(model.step == .disclaimer)
    model.disclaimerAccepted = true
    await model.advance()

    let saved = try! #require(await profiles.saved)
    #expect(saved.prosthesisType == nil)
    #expect(saved.kLevel == nil)
}

// MARK: - Back from the first screen leaves the wizard (Task 8.1.7)

@MainActor
@Test func backFromTheFirstScreenReturnsToWelcome() async {
    // [PRD §5] Welcome is where the user came from, so it stays reachable.
    // `canGoBack` still answers "is there a previous field?" — and there is
    // not; leaving the wizard is a different act.
    var exited = false
    let model = OnboardingViewModel(
        store: MemoryDraftStore(),
        profiles: RecordingProfiles(),
        clock: OnboardingClock(),
        logService: OnboardingLog(),
        onCompleted: {},
        onExit: { exited = true }
    )

    #expect(model.canGoBack == false)

    model.exitToWelcome()

    #expect(exited, "the first screen had no way back to Welcome")
    #expect(model.step == .amputationLevel, "leaving the wizard moved the step")
}

@MainActor
@Test func leavingForWelcomeKeepsTheDraftSoGetStartedResumes() async {
    // [PRD §6 AC] The draft is what makes resuming work; exiting must not
    // discard the answers already given.
    let store = MemoryDraftStore()
    var exited = false
    let model = OnboardingViewModel(
        store: store,
        profiles: RecordingProfiles(),
        clock: OnboardingClock(),
        logService: OnboardingLog(),
        onCompleted: {},
        onExit: { exited = true }
    )

    model.select(level: .transfemoral)
    await model.advance()
    model.select(side: .right)
    // `persist()` is fire-and-forget, so let the write land before reading it.
    await Task.yield()

    model.exitToWelcome()

    #expect(exited)
    #expect(await store.draft?.amputationLevel == .transfemoral)
    #expect(await store.draft?.side == .right)
    #expect(await store.draft?.step == .side)
}
