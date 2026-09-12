import SwiftUI

/// The app's root, driven by `AppRouter` (docs/11 §11.1).
///
/// Each remaining phase's real screen arrives with its own task; until then the
/// phase is named on screen so the routing is visible in the running app rather
/// than only in tests.
///
/// **The splash and `resolve()` run at the same time.** The store read starts on
/// the first frame and the splash counts down beside it, so the ~0.9s costs the
/// launch nothing on any device where reading a profile is faster than that —
/// which is all of them. `isShowingSplash` is what keeps the two honest: the
/// mark stays up until the countdown is over *and* the router has an answer, so
/// a cold store that takes longer than the splash extends it rather than
/// flashing a spinner between the mark and the first screen.
struct ContentView: View {
    @State private var router: AppRouter
    /// Cleared by `SplashView` when its hold is over. One-way — nothing brings
    /// the splash back, so a later `resolve()` (after onboarding, after a
    /// restore) re-reads the store behind the app rather than under a mark.
    @State private var isSplashRunning = true
    private let dependencies: AppDependencies

    init(router: AppRouter, dependencies: AppDependencies) {
        _router = State(initialValue: router)
        self.dependencies = dependencies
    }

    var body: some View {
        ZStack {
            if isShowingSplash {
                SplashView { isSplashRunning = false }
                    .transition(.opacity)
            } else {
                root
                    .transition(.opacity)
            }
        }
        // Driven from the value rather than wrapped around the assignment, so
        // the fade happens whichever of the two inputs ends the splash.
        .animation(.easeInOut(duration: Motion.rootCrossFade), value: isShowingSplash)
        .task { await router.resolve() }
    }

    /// The splash also stands in for the `resolving` phase's spinner — that is
    /// the moment it exists to cover.
    ///
    /// A *failed* launch is the exception: the phase stays `resolving` forever
    /// when the store cannot be read, so the failure has to be able to end the
    /// splash or the app would never show the error, and never offer the retry.
    private var isShowingSplash: Bool {
        if isSplashRunning { return true }
        return router.phase == .resolving && router.launchFailure == nil
    }

    @ViewBuilder
    private var root: some View {
        Group {
            switch router.phase {
            case .resolving:
                ResolvingView(failure: router.launchFailure) {
                    Task { await router.resolve() }
                }
            case .firstLaunch:
                WelcomeView { router.beginOnboarding() }
            case .onboarding:
                OnboardingView(
                    model: OnboardingViewModel(
                        store: dependencies.onboardingDrafts,
                        profiles: dependencies.userProfileRepository,
                        clock: dependencies.clock,
                        logService: dependencies.logService,
                        onCompleted: { await router.resolve() },
                        onExit: { router.returnToWelcome() }
                    )
                )
            case .main:
                mainRoot
            }
        }
    }

    /// The Walk / Result / You shell, carrying the DEBUG-only reset gesture
    /// (docs/design/dev-notes.md).
    ///
    /// Release builds get the shell and nothing else — `debugResetGesture` does
    /// not exist to be called there.
    @ViewBuilder
    private var mainRoot: some View {
        let shell = MainShellView(dependencies: dependencies, router: router)
        #if DEBUG
        shell.debugResetGesture(writer: dependencies.debugStoreWriter, router: router)
        #else
        shell
        #endif
    }
}

/// The launch state, and the one thing that can go wrong in it: the store would
/// not open. Plain-language and retryable (docs/15 §15.1).
private struct ResolvingView: View {
    let failure: StabilyzError?
    let retry: () -> Void

    var body: some View {
        if let failure, let presentation = ErrorPresenter.presentation(for: failure) {
            VStack(spacing: Space.x4) {
                Text(presentation.message)
                    .multilineTextAlignment(.center)
                if presentation.isRecoverable {
                    Button("Try Again", action: retry)
                }
            }
            .padding()
        } else {
            ProgressView()
        }
    }
}

private struct RootPlaceholder: View {
    let name: String
    var action: String?
    var perform: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.x4) {
            Text(name).font(StabilyzFont.heading)
            if let action, let perform {
                Button(action, action: perform)
            }
        }
    }
}
