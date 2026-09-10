import SwiftUI

/// First launch: the app's name, what it does, and the two ways in
/// [PRD §5] (Figma node 47:1275).
///
/// The wave mark, the title and the subtitle sit at the top; the illustration
/// runs full bleed beneath them, breaking the text margin entirely rather than
/// sharing it; the two capsules sit at the bottom on the same 70pt clearance the
/// wizard's primary uses, so the button does not move when the user taps through
/// to the first question.
///
/// The two `Spacer`s are what keep this working on a phone shorter than the
/// 874pt frame Figma draws: the header and the buttons hold their distance from
/// the two edges, and the illustration gives up the slack in between.
struct WelcomeView: View {
    /// "Get Started" — the only transition the router cannot derive from the
    /// store, so it is handed in rather than reached for (docs/12 §12.3).
    let beginOnboarding: () -> Void

    @State private var isShowingRestoreNotice = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Space.screenMargin)

            Spacer(minLength: Space.x6)

            // Full bleed: the node draws this 402pt wide in a 402pt frame.
            Image("WelcomeIllustration")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                // Decorative. The title and subtitle already say everything it
                // says, so announcing it would only add a stop to navigate past.
                .accessibilityHidden(true)

            Spacer(minLength: Space.x6)

            actions
                .padding(.horizontal, Space.screenMargin)
        }
        .padding(.top, Space.x12)
        .padding(.bottom, Controls.footerBottomGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StabilyzColor.bgBase)
        .alert("Restore isn't ready yet", isPresented: $isShowingRestoreNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                """
                Restoring from an export arrives in a later update. \
                Choose Get Started to set Stabilyz up on this device.
                """
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Space.x6) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(height: Controls.logoHeight)
                // The title directly beneath is the app's name in words.
                .accessibilityHidden(true)

            VStack(spacing: Space.x4) {
                Text("Stabilyz")
                    .font(StabilyzFont.heading)
                    .foregroundStyle(StabilyzColor.onboardingTitle)

                Text("Measure your walking stability over time, using your own baseline.")
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.onboardingTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Actions

    /// Both capsules are `CapsuleButtonStyle`, so the shape, the height and the
    /// edge-to-edge hit area are the same on each and neither view states them.
    private var actions: some View {
        VStack(spacing: Space.x4) {
            Button(action: beginOnboarding) {
                HStack(spacing: Space.x2) {
                    Text("Get Started")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(.primaryCapsuleHero)

            // Restore is Task 10.3.2. It is on screen from the start because
            // [PRD §5] puts it here, and a first launch that offered no route
            // back to an export would be the one screen where a returning user
            // is stuck; until the epic lands it says so rather than pretending.
            Button {
                isShowingRestoreNotice = true
            } label: {
                HStack(spacing: Space.x2) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Restore from Export")
                }
            }
            .buttonStyle(.secondaryCapsuleHero)
        }
    }
}
