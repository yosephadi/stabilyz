import SwiftUI

/// The app's two-option segmented control (design-system.md §5).
///
/// Replaces the system `.segmented` picker, whose labels stay near 13pt and do
/// not scale with Dynamic Type, which breaks the 15pt floor (§3). Labels are
/// text styles; the options sit side by side and stack vertically from the
/// accessibility sizes up, so neither label is ever truncated.
///
/// Accessibility: each option is a button carrying the `.isSelected` trait, and
/// the selected option is drawn with a checkmark and a filled surface, so the
/// state is never colour alone. Every option is at least `Metrics.minimumTapTarget`
/// tall.
struct SegmentedChoice<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }
    }

    /// Names the control for VoiceOver ("Choose a test"). Not drawn.
    let label: String
    let options: [Option]
    @Binding var selection: Value
    /// Each option's identifier is `"<identifier>.<index>"`.
    let identifier: String
    /// A taller control for the screen's first decision; never below the
    /// 44pt floor.
    var minHeight: CGFloat = Metrics.minimumTapTarget

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Space.x2))
            : AnyLayout(HStackLayout(spacing: Space.x2))
        layout {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                optionButton(option, index: index)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func optionButton(_ option: Option, index: Int) -> some View {
        let isSelected = option.value == selection
        return Button {
            selection = option.value
        } label: {
            HStack(spacing: Space.x2) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(StabilyzFont.bodyBold)
                        .accessibilityHidden(true)
                }
                Text(option.label)
                    .font(isSelected ? StabilyzFont.bodyBold : StabilyzFont.bodyRegular)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isSelected ? StabilyzColor.onPrimary : StabilyzColor.ink900)
            .padding(.horizontal, Space.x3)
            .padding(.vertical, Space.x2)
            .frame(maxWidth: .infinity, minHeight: max(minHeight, Metrics.minimumTapTarget))
            .background(
                isSelected ? StabilyzColor.primary600 : StabilyzColor.bgElevated,
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(
                        isSelected ? StabilyzColor.primary600 : StabilyzColor.ink400,
                        lineWidth: Metrics.hairline
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(identifier).\(index)")
    }
}
