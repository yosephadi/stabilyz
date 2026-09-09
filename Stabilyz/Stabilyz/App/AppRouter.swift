import Foundation

/// Which root the app is showing (docs/04 §4.1, docs/05 §5.3, docs/11 §11.1).
///
/// Four cases and no more: every other navigation state in the app lives inside
/// one of these, not alongside them. A launch that cannot be resolved stays in
/// `resolving` and carries a failure rather than inventing a fifth root — see
/// `AppRouter.launchFailure`.
enum AppLaunchPhase: Sendable, Equatable {
    /// Reading the store. The launch screen's state, not a destination.
    case resolving
    /// Welcome: "Get Started" or "Restore from a previous export" [PRD §5].
    case firstLaunch
    /// The wizard, from the beginning or resumed mid-flow [PRD §6 AC].
    case onboarding
    /// Home / History / Settings.
    case main
}

/// The root state machine (docs/11 §11.1).
///
/// The phase is a **total function of stored state** — a profile, whether that
/// profile passed the disclaimer, and whether a resumable draft exists
/// (docs/11 §11.5). There are no hidden booleans and no transition graph to
/// keep consistent: everything that changes the app's root changes the store
/// first, and `resolve()` reads it again. That is why restore needs no route of
/// its own in either direction — a successful restore has written a profile, so
/// resolving lands on Home [PRD §5: skip straight to Home], and a failed one
/// wrote nothing, so resolving lands back on Welcome with the data untouched.
///
/// `beginOnboarding()` is the single exception, and deliberately so: tapping
/// "Get Started" changes no stored state, so no re-read could ever produce it.
@MainActor
@Observable
final class AppRouter {
    private(set) var phase: AppLaunchPhase = .resolving

    /// Set when the store could not be read at launch (docs/15 §15.1:
    /// persistence failures get a plain-language message and a retry).
    ///
    /// The phase stays `resolving` while this is set, because the app genuinely
    /// has not resolved: it does not know whether a profile exists. Guessing
    /// `firstLaunch` would offer to start a fresh onboarding over data that may
    /// be sitting right there, unreadable.
    private(set) var launchFailure: StabilyzError?

    private let profiles: UserProfileRepository
    private let drafts: OnboardingDraftStore
    private let logService: LogService

    init(
        profiles: UserProfileRepository,
        drafts: OnboardingDraftStore,
        logService: LogService
    ) {
        self.profiles = profiles
        self.drafts = drafts
        self.logService = logService
    }

    /// Reads the store and lands on a root.
    ///
    /// Safe to call again at any time — after onboarding completes, after a
    /// restore succeeds or fails, or to retry a failed launch. The answer
    /// depends only on what is stored, never on where the app was.
    func resolve() async {
        phase = .resolving
        launchFailure = nil

        let profile: UserProfile?
        do {
            profile = try await profiles.fetchProfile()
        } catch {
            // Stay unresolved and say so. Recovery is a retry or, from Welcome,
            // a restore — neither of which we may choose on the user's behalf.
            let failure = (error as? StabilyzError) ?? .persistence(.storeCorruption)
            launchFailure = failure
            logService.log(.error, .app, "launch unresolved: profile could not be read")
            return
        }

        if let profile {
            // A profile whose disclaimer was never accepted must not reach Home
            // [PRD §7]. Sending it back through the wizard is the only route
            // that can produce the acceptance the gate requires.
            guard profile.hasAcceptedDisclaimer else {
                logService.log(.warning, .app, "profile has no disclaimer acceptance; routing to onboarding")
                phase = .onboarding
                return
            }
            phase = .main
            return
        }

        // No profile: resume the wizard if there is something to resume,
        // otherwise Welcome [PRD §6 AC].
        phase = await drafts.hasDraft() ? .onboarding : .firstLaunch
        logService.log(.info, .app, "launch resolved: \(phase)")
    }

    /// "Get Started" from Welcome.
    ///
    /// The one transition not derivable from the store, and it only ever moves
    /// *forward from Welcome*: nothing may push a user with a profile out of the
    /// app and back into the wizard.
    func beginOnboarding() {
        guard phase == .firstLaunch else { return }
        phase = .onboarding
    }
}
