import SwiftUI

/// The countdown, over the walk it is about to start (Figma node 128:2591).
///
/// Sits on a scrim above `ActiveSessionView`, so the user sees the screen they
/// are counting into rather than a separate step. [PRD OQ-6] makes the two
/// channels explicit: the numerals are the **required** channel and the haptic
/// taps are the convenience one, which is why nothing here is conditional on
/// haptics being available.
///
/// The VoiceOver announcement per numeral closes the converse gap — a user who
/// has already pocketed the phone and cannot see the screen would otherwise
/// have nothing until the tone at Go.
struct CountdownOverlayView: View {
    let cancel: () -> Void

    static let cancelTitle = "Cancel"
    static let goText = "Go!"
    /// Named for VoiceOver, which would otherwise announce the scrim as an
    /// unlabelled group between the numeral and the button.
    static let accessibilityLabel = "Starting your walk"

    /// The scrim and Cancel. The numeral is `CountdownNumeralView`, drawn by
    /// the cover above this at the timer ring's centre.
    var body: some View {
        ZStack {
            StabilyzColor.countdownScrim
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Button(Self.cancelTitle, action: cancel)
                    .buttonStyle(.secondaryCapsuleHero)
                    .accessibilityIdentifier("countdown.cancel")
                    .padding(.horizontal, Space.screenMargin)
                    .padding(.bottom, Controls.coverFooterBottomGap)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel)
    }
}

/// The countdown numeral, centred in the timer ring.
///
/// Inside the ring rather than beside it: the ring is already the dial the
/// walk is timed on, and its centre is the one place on the walk screen with
/// nothing drawn (the clock is hidden until the countdown clears). White on the
/// scrim, which is dark enough in both modes for 4.5:1 (ColorTokens).
struct CountdownNumeralView: View {
    /// What to draw: "5"…"1", then "Go!" — or the preparing line.
    let numeral: String
    /// False for "Getting ready…", which is a sentence rather than a numeral
    /// and would be absurd at 128pt.
    let isNumeral: Bool

    var body: some View {
        Text(numeral)
            .font(isNumeral ? StabilyzFont.countdownNumeral : StabilyzFont.subheading2Bold)
            .foregroundStyle(StabilyzColor.countdownNumeral)
            // "Go!" is three glyphs where "5" is one; shrink rather than
            // truncate, and never wrap.
            .lineLimit(1)
            .minimumScaleFactor(Motion.countdownNumeralMinimumScale)
            // Each tick replaces the numeral; no cross-fade of two digits.
            .contentTransition(.identity)
            .frame(maxWidth: Controls.timerRingInnerDiameter)
            .multilineTextAlignment(.center)
            // The numeral is announced deliberately, per tick, by the owner of
            // the countdown — announcing it again as it redraws would double
            // every number.
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
