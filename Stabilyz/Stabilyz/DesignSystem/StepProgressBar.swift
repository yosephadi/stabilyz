import SwiftUI

/// The onboarding progress indicator [PRD §7 AC], as Figma node 40:835 draws
/// it: a 15pt label over one 14pt capsule per step, 4pt apart, filled up to the
/// current one.
///
/// The label is not decoration. A row of capsules is invisible to VoiceOver and
/// collapses at large type settings, so the position is stated in words as well
/// and the two are merged into a single accessibility element — the bar is then
/// read once, as "2 out of 5", rather than as five anonymous shapes.
///
/// It counts **questions only**. The disclaimer is a consent gate rather than a
/// field, so it is not a numbered step and draws no bar at all; the wizard
/// simply does not render this view there.
struct StepProgressBar: View {
    let step: Int
    let of: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text("\(step) out of \(of)")
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.progressLabel)

            HStack(spacing: Space.x1) {
                ForEach(1...max(of, 1), id: \.self) { index in
                    Capsule()
                        .fill(
                            index <= step
                                ? StabilyzColor.progressFill
                                : StabilyzColor.progressTrack
                        )
                        .frame(height: Controls.progressBarHeight)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}
