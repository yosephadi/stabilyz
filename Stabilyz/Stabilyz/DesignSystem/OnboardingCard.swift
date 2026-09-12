import SwiftUI

/// The onboarding answer card (§5).
///
/// A `VStack` in a `RoundedRectangle`, not a `List`. `.insetGrouped` is a
/// full-screen scrolling surface: it brings its own margins, its own background
/// and its own scroll view, none of which can be switched off cleanly, so a
/// wizard step that embeds one gets a card inset twice over and a scroll view
/// inside a scroll view. Composing the card from primitives is the native
/// answer here, not a custom control — `VStack`, `RoundedRectangle`, `Divider`
/// and `Button` are as stock as `List` is (§5 component law).
///
/// The card carries no padding of its own, so it sits flush against the 16pt
/// card margin its container applies (`Space.cardMargin`, wider than the 24pt
/// text margin — see Figma node 40:835).
///
/// **No border.** It had a hairline to separate it from `bg-base`; the Figma
/// node draws none, and at 26pt radius a solid white fill already has enough
/// edge against `#F7F7F7` for the border to have been drawing a second, fainter
/// outline just inside the corner rather than defining one.
struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(StabilyzColor.bgElevated, in: RoundedRectangle(cornerRadius: Radius.card))
        // The rows run edge to edge, so anything that reaches a corner has to
        // be clipped by the same shape that fills it.
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }
}

/// One selectable answer.
///
/// A `Button` with a native `checkmark` accessory, carrying `.isSelected` so
/// VoiceOver announces the state a `Picker` row would have announced for free.
/// That trait is the reason this is written out rather than left implicit: the
/// checkmark is what a sighted user reads, and without the trait it would be
/// the *only* thing that says which answer is chosen.
struct ChoiceRow: View {
    let label: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: Space.x3) {
                Text(label)
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink900)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(StabilyzFont.bodyBold)
                        .foregroundStyle(StabilyzColor.primary600)
                }
            }
            .padding(.horizontal, Space.x4)
            .frame(minHeight: Controls.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole row is the target, not just the label.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// One answer per row, separated by native `Divider`s inset to the text on
/// both sides, as Figma node 40:835 draws them.
struct ChoiceCard<Value: Hashable>: View {
    struct Option: Hashable {
        let value: Value
        let label: String

        init(_ value: Value, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    let options: [Option]
    @Binding var selection: Value

    var body: some View {
        OnboardingCard {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                if index > 0 {
                    Divider().padding(.horizontal, Space.x4)
                }
                ChoiceRow(
                    label: option.label,
                    isSelected: selection == option.value
                ) {
                    selection = option.value
                }
            }
        }
    }
}
