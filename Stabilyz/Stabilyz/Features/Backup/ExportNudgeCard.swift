import SwiftUI

/// The Walk tab's one-time backup prompt (docs/21 #11, Task 10.2.3).
///
/// Non-intrusive by construction: a plain elevated card in the setup screen's
/// own column, no border and no alert colour — nothing is wrong, and amber and
/// red keep their meanings (§2.3). Its action is a text button rather than a
/// capsule, so Start stays the screen's one primary action.
struct ExportNudgeCard: View {
    let nudge: ExportNudgeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack(alignment: .center, spacing: Space.x2) {
                Image(systemName: "lock.shield")
                    .font(StabilyzFont.bodyBold)
                    .foregroundStyle(StabilyzColor.primary600)
                    .accessibilityHidden(true)

                Text(ExportNudgeViewModel.title)
                    .font(StabilyzFont.subheading2Bold)
                    .foregroundStyle(StabilyzColor.ink900)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 0)

                Button {
                    nudge.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(StabilyzFont.smallBold)
                        .foregroundStyle(StabilyzColor.ink600)
                        .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ExportNudgeViewModel.dismissLabel)
            }

            Text(ExportNudgeViewModel.message)
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.ink600)
                .fixedSize(horizontal: false, vertical: true)

            Button(ExportNudgeViewModel.backUpLabel) {
                nudge.backUpNow()
            }
            .font(StabilyzFont.bodyBold)
            .foregroundStyle(StabilyzColor.primary600)
            .frame(minHeight: Metrics.minimumTapTarget, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Space.x4)
        .padding(.vertical, Space.x2)
        .background(StabilyzColor.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
