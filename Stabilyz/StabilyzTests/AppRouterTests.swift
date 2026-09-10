import Foundation
import Testing
@testable import Stabilyz

// MARK: - Doubles

private final class RouterLog: LogService, @unchecked Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// A profile store whose contents and health a test can set.
private actor StubProfiles: UserProfileRepository {
    private var profile: UserProfile?
    private var failure: StabilyzError?
    private(set) var fetchCount = 0

    init(profile: UserProfile? = nil, failure: StabilyzError? = nil) {
        self.profile = profile
        self.failure = failure
    }

    func fetchProfile() async throws -> UserProfile? {
        fetchCount += 1
        if let failure { throw failure }
        return profile
    }

    func save(_ profile: UserProfile) async throws { self.profile = profile }

    /// Stands in for whatever changed the store between resolves — onboarding
    /// finishing, a restore landing, a broken store coming back.
    func set(profile: UserProfile?, failure: StabilyzError? = nil) {
        self.profile = profile
        self.failure = failure
    }
}

private struct StubDrafts: OnboardingDraftStore {
    let exists: Bool
    func hasDraft() async -> Bool { exists }
    func load() async -> OnboardingDraft? { exists ? OnboardingDraft(step: .side) : nil }
    func save(_ draft: OnboardingDraft) async {}
    func clear() async {}
}

@MainActor
private func makeRouter(
    profiles: StubProfiles = StubProfiles(),
    draft: Bool = false
) -> AppRouter {
    AppRouter(profiles: profiles, drafts: StubDrafts(exists: draft), logService: RouterLog())
}

/// A profile that never passed the disclaimer — the sentinel `UserProfileEntity`
/// declares as its SwiftData default.
private func profileWithoutDisclaimer() -> UserProfile {
    try! UserProfile(
        id: UUID(),
        amputationLevel: .transtibial,
        side: .left,
        timeSinceAmputationMonths: 24,
        disclaimerAcceptedAt: .distantPast,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

// MARK: - The phase is a total function of stored state (docs/11 §11.5)

@MainActor
@Test func everyCombinationOfStoredStateResolvesToExactlyOnePhase() async {
    // The whole truth table, so no combination is left to be discovered later
    // by a user. Three profile states × two draft states.
    let cases: [(profile: UserProfile?, draft: Bool, expected: AppLaunchPhase)] = [
        (nil, false, .firstLaunch),
        (nil, true, .onboarding),
        (.fixture(), false, .main),
        (.fixture(), true, .main),
        (profileWithoutDisclaimer(), false, .onboarding),
        (profileWithoutDisclaimer(), true, .onboarding),
    ]

    for testCase in cases {
        let router = makeRouter(profiles: StubProfiles(profile: testCase.profile), draft: testCase.draft)
        await router.resolve()

        #expect(
            router.phase == testCase.expected,
            "profile=\(testCase.profile != nil) draft=\(testCase.draft) resolved to \(router.phase)"
        )
        #expect(router.launchFailure == nil)
    }
}

@MainActor
@Test func theRouterStartsResolvingRatherThanGuessing() {
    // Nothing has been read yet, so no root has been chosen. A launch that
    // flashed Welcome before landing on Home would be a bug the user sees.
    #expect(makeRouter().phase == .resolving)
}

@MainActor
@Test func anExistingUserGoesStraightToHome() async {
    let router = makeRouter(profiles: StubProfiles(profile: .fixture()))
    await router.resolve()

    #expect(router.phase == .main)
}

@MainActor
@Test func aFirstLaunchOffersWelcome() async {
    let router = makeRouter()
    await router.resolve()

    #expect(router.phase == .firstLaunch)
}

// MARK: - The disclaimer gate [PRD §7 AC]

@MainActor
@Test func aProfileWithoutAnAcceptedDisclaimerNeverReachesHome() async {
    // The gate the PRD calls hard. `UserProfileEntity` defaults the acceptance
    // date to `.distantPast`, so a row written by anything other than the
    // wizard — a migration, a malformed restore — can look like a complete
    // profile. It goes back through onboarding, not to Home.
    let router = makeRouter(profiles: StubProfiles(profile: profileWithoutDisclaimer()))
    await router.resolve()

    #expect(router.phase == .onboarding)
    #expect(router.phase != .main)
}

@MainActor
@Test func acceptingTheDisclaimerIsWhatOpensHome() async {
    // The same profile, before and after the gate.
    let profiles = StubProfiles(profile: profileWithoutDisclaimer())
    let router = makeRouter(profiles: profiles)
    await router.resolve()
    #expect(router.phase == .onboarding)

    await profiles.set(profile: .fixture())
    await router.resolve()

    #expect(router.phase == .main)
}

@Test func theDisclaimerPredicateReadsTheSentinelAsUnaccepted() {
    #expect(profileWithoutDisclaimer().hasAcceptedDisclaimer == false)
    #expect(UserProfile.fixture().hasAcceptedDisclaimer)
}

// MARK: - Resuming the wizard [PRD §6 AC]

@MainActor
@Test func aSavedDraftResumesTheWizardInsteadOfShowingWelcome() async {
    let router = makeRouter(draft: true)
    await router.resolve()

    #expect(router.phase == .onboarding)
}

@MainActor
@Test func gettingStartedIsTheOneTransitionTheStoreCannotProduce() async {
    // Tapping Get Started writes nothing, so no re-read could ever yield it.
    let router = makeRouter()
    await router.resolve()
    #expect(router.phase == .firstLaunch)

    router.beginOnboarding()
    #expect(router.phase == .onboarding)
}

@MainActor
@Test func nothingCanPushAnExistingUserBackIntoTheWizard() async {
    let router = makeRouter(profiles: StubProfiles(profile: .fixture()))
    await router.resolve()

    router.beginOnboarding()

    #expect(router.phase == .main)
}

@MainActor
@Test func resolvingAfterOnboardingLandsOnHomeWithoutASpecialRoute() async {
    let profiles = StubProfiles()
    let router = makeRouter(profiles: profiles)
    await router.resolve()
    router.beginOnboarding()
    #expect(router.phase == .onboarding)

    // The wizard's last act is saving the profile.
    await profiles.set(profile: .fixture())
    await router.resolve()

    #expect(router.phase == .main)
}

// MARK: - Restore, in both directions (docs/11 §11.4)

@MainActor
@Test func aSuccessfulFirstLaunchRestoreSkipsStraightToHome() async {
    // [PRD §5] The archive brought a profile, so onboarding is already complete.
    let profiles = StubProfiles()
    let router = makeRouter(profiles: profiles)
    await router.resolve()
    #expect(router.phase == .firstLaunch)

    await profiles.set(profile: .fixture())
    await router.resolve()

    #expect(router.phase == .main)
}

@MainActor
@Test func aFailedRestoreReturnsToWelcomeWithNothingChanged() async {
    // [PRD §5] A failed restore writes nothing, so the same re-read that would
    // have found a profile finds the store exactly as it was.
    let profiles = StubProfiles()
    let router = makeRouter(profiles: profiles)
    await router.resolve()

    await router.resolve()

    #expect(router.phase == .firstLaunch)
    #expect(router.launchFailure == nil)
}

// MARK: - A store that will not open (docs/15 §15.1)

@MainActor
@Test func anUnreadableStoreStaysUnresolvedRatherThanGuessingFirstLaunch() async {
    // Guessing Welcome would offer a fresh start over data that is sitting
    // there unreadable; guessing Home would show an empty app to someone who
    // has sessions. Neither is ours to choose.
    let router = makeRouter(profiles: StubProfiles(failure: .persistence(.storeCorruption)))
    await router.resolve()

    #expect(router.phase == .resolving)
    #expect(router.launchFailure == .persistence(.storeCorruption))
}

@MainActor
@Test func theLaunchFailureIsSomethingTheUserCanBeShownAndRetry() async {
    let router = makeRouter(profiles: StubProfiles(failure: .persistence(.storeCorruption)))
    await router.resolve()

    let failure = try! #require(router.launchFailure)
    let presentation = try! #require(ErrorPresenter.presentation(for: failure))

    #expect(presentation.isRecoverable, "a store failure at launch offers no way forward")
    #expect(presentation.message.isEmpty == false)
}

@MainActor
@Test func retryingAfterTheStoreRecoversResolvesNormally() async {
    let profiles = StubProfiles(profile: .fixture(), failure: .persistence(.storeCorruption))
    let router = makeRouter(profiles: profiles)
    await router.resolve()
    #expect(router.phase == .resolving)

    await profiles.set(profile: .fixture())
    await router.resolve()

    #expect(router.phase == .main)
    #expect(router.launchFailure == nil)
}

@MainActor
@Test func aNonStabilyzErrorStillBecomesAPresentableFailure() async {
    // Whatever a repository throws, the launch has one shape of failure.
    struct Unexpected: Error {}
    let router = AppRouter(
        profiles: ThrowingProfiles(error: Unexpected()),
        drafts: StubDrafts(exists: false),
        logService: RouterLog()
    )
    await router.resolve()

    #expect(router.phase == .resolving)
    #expect(router.launchFailure == .persistence(.storeCorruption))
}

private struct ThrowingProfiles: UserProfileRepository {
    let error: any Error
    func fetchProfile() async throws -> UserProfile? { throw error }
    func save(_ profile: UserProfile) async throws { throw error }
}

// MARK: - Re-resolution is what everything else uses

@MainActor
@Test func resolvingIsIdempotentAndDependsOnlyOnWhatIsStored() async {
    // The same store, read from three different starting phases, gives the same
    // answer every time (docs/11 §11.5).
    let router = makeRouter(profiles: StubProfiles(profile: .fixture()))

    await router.resolve()
    let first = router.phase
    await router.resolve()
    let second = router.phase
    router.beginOnboarding()
    await router.resolve()

    #expect(first == .main)
    #expect(second == .main)
    #expect(router.phase == .main)
}

@MainActor
@Test func aFailedResolveClearsItsFailureOnTheNextAttempt() async {
    // A stale error must not outlive the condition that caused it.
    let profiles = StubProfiles(failure: .persistence(.storeCorruption))
    let router = makeRouter(profiles: profiles)
    await router.resolve()
    #expect(router.launchFailure != nil)

    await profiles.set(profile: nil)
    await router.resolve()

    #expect(router.launchFailure == nil)
    #expect(router.phase == .firstLaunch)
}

// MARK: - The draft store until 8.1.2

@Test func theEmptyDraftStoreReportsNothingToResume() async {
    // Not a guess: nothing writes a draft yet, so this is the literal state.
    #expect(await EmptyOnboardingDraftStore().hasDraft() == false)
}

// MARK: - Leaving the wizard for Welcome (Task 8.1.7)

@MainActor
@Test func returningToWelcomeMovesBackOutOfTheWizard() async {
    let router = makeRouter()
    await router.resolve()
    router.beginOnboarding()
    #expect(router.phase == .onboarding)

    router.returnToWelcome()

    #expect(router.phase == .firstLaunch)
}

@MainActor
@Test func returningToWelcomeOnlyEverMovesBackwardOutOfTheWizard() async {
    // The mirror of `beginOnboarding`'s guard: nothing may drop a user who
    // already has a profile onto the first-launch screen.
    let profiles = StubProfiles()
    await profiles.set(profile: .fixture())
    let router = makeRouter(profiles: profiles)
    await router.resolve()
    #expect(router.phase == .main)

    router.returnToWelcome()

    #expect(router.phase == .main, "a user with a profile was sent to Welcome")
}
