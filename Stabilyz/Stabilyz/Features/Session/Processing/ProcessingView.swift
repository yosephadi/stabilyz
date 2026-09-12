import SwiftUI

/// Between Stop and the result (docs/11 §11.3, [PRD §5]).
///
/// Deliberately plain. The PRD calls this step "brief, on-device only, no
/// network call", and the screen's job is to say so and get out of the way —
/// there is no progress bar, because a fraction the user cannot act on is
/// decoration, and on most walks this is gone before it is read.
///
/// **Non-dismissible.** There is no Cancel: the walk is already recorded and
/// the analysis is the only thing standing between it and a result. Cancelling
/// would leave the user with a session they cannot see [PRD §5 — after
/// processing, route to Noisy or Score, never neither].
struct ProcessingView: View {
    let mode: TestMode

    static let title = "Processing your data"
    static let privacyNote = "Your data stays on your iPhone."

    /// Names the mode, so a six-minute walk does not get a message written for
    /// a two-minute one.
    static func body(for mode: TestMode) -> String {
        "Reviewing your \(mode.displayName) data. This usually takes a few seconds."
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(height: Controls.logoHeight)
                // The title says what is happening; the mark is the app's face,
                // not information.
                .accessibilityHidden(true)

            Spacer().frame(height: Controls.processingLogoGap)

            Text(Self.title)
                .font(StabilyzFont.heading)
                .foregroundStyle(StabilyzColor.ink900)

            Spacer().frame(height: Space.x4)

            Text(Self.body(for: mode))
                .font(StabilyzFont.bodyRegular)
                .foregroundStyle(StabilyzColor.ink900)

            Spacer().frame(height: Space.x8)

            Text(Self.privacyNote)
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.ink600)

            Spacer()
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Space.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StabilyzColor.bgBase)
        // One announcement, in reading order, rather than four stops for a
        // screen that exists for a few seconds.
        .accessibilityElement(children: .combine)
    }
}
