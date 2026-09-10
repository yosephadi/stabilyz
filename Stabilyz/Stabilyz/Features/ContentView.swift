import SwiftUI

/// The app's root, driven by `AppRouter` (docs/11 §11.1).
///
/// Each phase's real screen arrives with its own task; until then the phase is
/// named on screen so the routing is visible in the running app rather than only
/// in tests.
struct ContentView: View {
    @State private var router: AppRouter
    private let dependencies: AppDependencies

    init(router: AppRouter, dependencies: AppDependencies) {
        _router = State(initialValue: router)
        self.dependencies = dependencies
    }

    var body: some View {
        Group {
            switch router.phase {
            case .resolving:
                ResolvingView(failure: router.launchFailure) {
                    Task { await router.resolve() }
                }
            case .firstLaunch:
                // Task 8.1.2: Welcome, with Get Started and Restore.
                RootPlaceholder(name: "Welcome", action: "Get Started") {
                    router.beginOnboarding()
                }
            case .onboarding:
                OnboardingView(
                    model: OnboardingViewModel(
                        store: dependencies.onboardingDrafts,
                        profiles: dependencies.userProfileRepository,
                        clock: dependencies.clock,
                        logService: dependencies.logService,
                        onCompleted: { await router.resolve() }
                    )
                )
            case .main:
                // Task 8.3.1: Home / History / Settings.
                RootPlaceholder(name: "Home")
            }
        }
        .task { await router.resolve() }
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
