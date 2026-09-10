import SwiftUI

/// The onboarding progress indicator [PRD §7 AC], as the screen designs draw
/// it: a short label over one capsule per step, filled up to the current one.
///
/// The label is not decoration. A row of capsules is invisible to VoiceOver and
/// collapses at large type settings, so the position is stated in words as well
/// and the two are merged into a single accessibility element — the bar is then
/// read once, as "Step 2 of 6", rather than as six anonymous shapes.
struct StepProgressBar: View {
    let step: Int
    let of: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text("Step \(step) of \(of)")
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.ink600)

            HStack(spacing: Space.x1) {
                ForEach(1...max(of, 1), id: \.self) { index in
                    Capsule()
                        .fill(
                            index <= step
                                ? StabilyzColor.primary700
                                : StabilyzColor.primary100
                        )
                        .frame(height: Space.x2)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}
