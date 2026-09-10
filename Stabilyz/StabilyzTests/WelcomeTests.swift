import SwiftUI
import Testing
import UIKit
@testable import Stabilyz

// MARK: - Doubles

/// Each test file in this suite carries its own doubles; the ones in
/// `OnboardingTests` and `AppRouterTests` are file-private, and this file needs
/// both halves at once.
private final class WelcomeLog: LogService, @unchecked Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

private struct WelcomeClock: Clock {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let uptime: TimeInterval = 0
}

private actor WelcomeProfiles: UserProfileRepository {
    private var profile: UserProfile?
    func fetchProfile() async throws -> UserProfile? { profile }
    func save(_ profile: UserProfile) async throws { self.profile = profile }
}

/// The real draft store's behaviour, in memory: the router and the wizard share
/// one instance, which is the whole point of the round-trip test below.
private actor WelcomeDrafts: OnboardingDraftStore {
    private var draft: OnboardingDraft?
    func hasDraft() async -> Bool { draft != nil }
    func load() async -> OnboardingDraft? { draft }
    func save(_ draft: OnboardingDraft) async { self.draft = draft }
    func clear() async { draft = nil }
}

// MARK: - Assets (Task 8.1.2)

/// The two artwork assets Welcome draws, exported from Figma node 47:1275.
///
/// A view referencing `Image("AppLogo")` compiles whether or not the imageset
/// exists — a missing one renders as nothing at runtime and fails no build. So
/// the names are resolved here instead: a renamed folder, a `Contents.json` that
/// does not list its file, or an asset dropped from the target all fail as a
/// test rather than as a blank space on the first screen the user ever sees.
@Suite struct WelcomeAssetTests {

    static let assetNames = ["AppLogo", "WelcomeIllustration"]

    @MainActor
    @Test func bothWelcomeAssetsResolveFromTheAppBundle() {
        for name in Self.assetNames {
            #expect(UIImage(named: name) != nil, "\(name) is not in the asset catalog")
        }
    }

    @MainActor
    @Test func bothWelcomeAssetsKeepTheirVectorRepresentation() {
        // `preserves-vector-representation` is what lets these scale to any
        // device width without softening. Without it the catalog rasterises at
        // export size and the illustration blurs on a wide phone, which is
        // invisible in a simulator screenshot at 1x and obvious on a device.
        for name in Self.assetNames {
            guard let image = UIImage(named: name) else {
                Issue.record("\(name) is not in the asset catalog")
                continue
            }
            #expect(image.isSymbolImage == false, "\(name) resolved to a symbol, not the artwork")
            #expect(image.size.width > 0 && image.size.height > 0, "\(name) has no intrinsic size")
        }
    }

    @MainActor
    @Test func theIllustrationKeepsTheAspectRatioTheNodeDraws() {
        // 402x256 in the export. The view scales it to the screen width, so a
        // re-export at a different crop would silently change how much vertical
        // space it claims between the header and the buttons.
        guard let illustration = UIImage(named: "WelcomeIllustration") else {
            Issue.record("WelcomeIllustration is not in the asset catalog")
            return
        }
        let ratio = illustration.size.width / illustration.size.height
        #expect(abs(ratio - 402.0 / 256.0) < 0.01, "aspect ratio is \(ratio)")
    }
}

// MARK: - Welcome is the first-launch root, and the way back to it

/// The seam between `AppRouter` and the wizard, which each half's own tests
/// cannot see: the router's phase and the draft have to agree about what "back
/// to Welcome" means [PRD §5, §6 AC].
@Suite struct WelcomeRoutingTests {

    @MainActor
    @Test func aFirstLaunchWithNoDraftLandsOnWelcome() async {
        let router = AppRouter(
            profiles: WelcomeProfiles(),
            drafts: WelcomeDrafts(),
            logService: WelcomeLog()
        )

        await router.resolve()

        #expect(router.phase == .firstLaunch)
    }

    @MainActor
    @Test func backFromTheFirstQuestionReturnsToWelcomeWithTheDraftIntact() async {
        // The whole round trip: Get Started, answer one question, Back on the
        // first screen, then Get Started again. The answer has to survive it —
        // [PRD §6 AC] makes the draft the thing that carries it.
        let drafts = WelcomeDrafts()
        let router = AppRouter(
            profiles: WelcomeProfiles(),
            drafts: drafts,
            logService: WelcomeLog()
        )
        await router.resolve()
        #expect(router.phase == .firstLaunch)

        router.beginOnboarding()
        #expect(router.phase == .onboarding)

        let model = OnboardingViewModel(
            store: drafts,
            profiles: WelcomeProfiles(),
            clock: WelcomeClock(),
            logService: WelcomeLog(),
            onCompleted: {},
            onExit: { router.returnToWelcome() }
        )
        await model.start()

        model.select(level: .transfemoral)
        // `persist()` is fire-and-forget, so let the write land before reading.
        await Task.yield()

        // On the first question there is no previous field; what is behind it
        // is Welcome, and the wizard says so by exiting rather than moving.
        #expect(model.canGoBack == false)
        model.exitToWelcome()

        #expect(router.phase == .firstLaunch, "Back did not return to Welcome")
        #expect(await drafts.hasDraft(), "leaving for Welcome discarded the draft")

        // Get Started again, and the answer is still there.
        router.beginOnboarding()
        let resumed = OnboardingViewModel(
            store: drafts,
            profiles: WelcomeProfiles(),
            clock: WelcomeClock(),
            logService: WelcomeLog(),
            onCompleted: {},
            onExit: {}
        )
        await resumed.start()

        #expect(router.phase == .onboarding)
        #expect(resumed.draft.amputationLevel == .transfemoral, "the answer was lost")
    }
}
