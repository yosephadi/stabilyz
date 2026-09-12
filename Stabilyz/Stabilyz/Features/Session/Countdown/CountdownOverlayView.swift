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
    /// What to draw: "5"…"1", then "Go!" — or the preparing line.
    let numeral: String
    /// False for "Getting ready…", which is a sentence rather than a numeral
    /// and would be absurd at 128pt.
    let isNumeral: Bool
    let cancel: () -> Void

    static let cancelTitle = "Cancel"
    static let goText = "Go!"
    /// Named for VoiceOver, which would otherwise announce the scrim as an
    /// unlabelled group between the numeral and the button.
    static let accessibilityLabel = "Starting your walk"

    var body: some View {
        ZStack {
            StabilyzColor.countdownScrim
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Text(numeral)
                    .font(isNumeral ? StabilyzFont.countdownNumeral : StabilyzFont.subheading2Bold)
                    .foregroundStyle(StabilyzColor.countdownNumeral)
                    // "Go!" is three glyphs where "5" is one; shrink rather
                    // than truncate, and never wrap.
                    .lineLimit(1)
                    .minimumScaleFactor(Motion.countdownNumeralMinimumScale)
                    // The numeral is announced deliberately, per tick, by the
                    // owner of the countdown — announcing it again as it
                    // redraws would double every number.
                    .accessibilityHidden(true)

                Spacer()

                Button(Self.cancelTitle, action: cancel)
                    .buttonStyle(.secondaryCapsuleHero)
                    .padding(.horizontal, Space.screenMargin)
                    .padding(.bottom, Controls.coverFooterBottomGap)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel)
    }
}
