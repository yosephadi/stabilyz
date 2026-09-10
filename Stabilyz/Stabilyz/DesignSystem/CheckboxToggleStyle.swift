import SwiftUI

/// The disclaimer tick [PRD §7 AC], drawn as a checkbox rather than a switch.
///
/// The PRD calls it a checkbox and the onboarding design draws one, so a switch
/// was the odd one out. This is a `ToggleStyle` rather than a bespoke control on
/// purpose: the `Toggle` underneath keeps its binding, its Dynamic Type
/// behaviour and its VoiceOver toggle semantics, so what changes is only what
/// the control looks like — which is the whole remit of a restyle.
///
/// Lives here because `Features/` may not name a colour, a size or a spacing
/// value; the raw ones all belong to the design system.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.x3) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(StabilyzFont.subheading2Regular)
                    .foregroundStyle(
                        configuration.isOn ? StabilyzColor.primary600 : StabilyzColor.ink400
                    )
                configuration.label
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink900)
                    .multilineTextAlignment(.leading)
                    // The acknowledgement wraps; without this it truncates
                    // instead at large type settings (§9).
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: Metrics.minimumTapTarget)
            // The whole row is the target, not just the box (§4, §9).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}

extension ToggleStyle where Self == CheckboxToggleStyle {
    static var checkbox: CheckboxToggleStyle { CheckboxToggleStyle() }
}
