import SwiftUI

/// The launch screen: the wave mark on `bg-base`, briefly (design-system.md §10).
///
/// It covers the moment `AppRouter` spends reading the store, so the app opens
/// on its own mark rather than on a spinner. It knows nothing about what comes
/// after — it counts down and calls `onFinished`, and `ContentView` decides what
/// that reveals.
///
/// **Reduce Motion removes the movement, not the time.** With the setting on the
/// mark is already at rest on the first frame — no fade, no settle — but the
/// hand-off still happens at `Motion.splashTotal`, so launching the app takes
/// the same length either way. The alternative, a launch that is a third as
/// long because the user turned animation off, is a different app rather than an
/// accessible one.
struct SplashView: View {
    /// Called once, when the hold is over. Not called if the view goes away
    /// first — a cancelled splash has nothing to hand off to.
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false

    var body: some View {
        ZStack {
            StabilyzColor.bgBase
                .ignoresSafeArea()

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(height: Controls.splashLogoHeight)
                .scaleEffect(scale)
                .opacity(opacity)
        }
        // One element saying the app's name, rather than an unlabelled image
        // that VoiceOver would announce as nothing for the length of the hold.
        .accessibilityElement()
        .accessibilityLabel("Stabilyz")
        .task { await run() }
    }

    // MARK: - Appearance

    /// Computed from the environment rather than seeded into `@State`, because
    /// `@State` cannot read the environment in its initialiser — and a single
    /// frame at `opacity: 0` before `.task` runs is exactly the flash Reduce
    /// Motion is meant to prevent.
    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        return isRevealed ? 1 : Motion.splashInitialScale
    }

    private var opacity: Double {
        guard !reduceMotion else { return 1 }
        return isRevealed ? 1 : 0
    }

    // MARK: - Timing

    private func run() async {
        if reduceMotion {
            // No `withAnimation`: the mark is already at rest, and this only
            // settles the state so the two paths agree.
            isRevealed = true
        } else {
            withAnimation(.easeOut(duration: Motion.splashReveal)) {
                isRevealed = true
            }
        }

        do {
            try await Task.sleep(for: .seconds(Motion.splashTotal))
        } catch {
            // Cancelled — the view is going away, so there is nothing to hand
            // off. Returning here rather than using `try?` is the difference
            // between that and calling `onFinished` on a dead view.
            return
        }

        onFinished()
    }
}
