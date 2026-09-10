import SwiftUI

/// Which of the two capsules a button is (design-system.md §5).
enum CapsuleButtonRole {
    /// The screen's one forward action. A solid `primary-600` fill.
    case primary
    /// The alternative beside it. The same shape on a material.
    case secondary
}

/// The app's capsule buttons: full width, `button-height-hero` (55pt) on
/// single-decision screens, `button-height` (50pt) elsewhere.
///
/// **Why this is a style and not `.borderedProminent`.** The enabled primary is
/// exactly what the system draws — a `primary-600` capsule with a white label —
/// but the disabled state is not. `.borderedProminent` dims its own fill into an
/// opaque grey slab, heavier on the page than the enabled button it replaces,
/// and the loudest thing on a screen where the user has not done anything yet.
/// Here "not ready" is a translucent capsule with a hairline edge and an
/// `ink-400` label: present, legible, and plainly waiting.
///
/// That material is also the secondary's *enabled* surface, which is why the two
/// roles share one style rather than being written twice. Three of the four
/// combinations draw the same capsule; only the enabled primary is filled.
///
/// The sizing and the `contentShape` are applied to `configuration.label`, so
/// the whole capsule is the hit area rather than the width of the words inside
/// it. That is the one detail this style exists to guarantee for every caller.
struct CapsuleButtonStyle: ButtonStyle {
    let role: CapsuleButtonRole
    /// `Controls.buttonHeight` or `Controls.heroButtonHeight` (§4).
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, role: role, height: height)
    }

    /// A nested `View` so the style can read `isEnabled` — a `ButtonStyle` is
    /// not itself a view and has no environment of its own.
    private struct Surface: View {
        let configuration: Configuration
        let role: CapsuleButtonRole
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        /// True only for the one filled combination.
        private var isFilled: Bool { role == .primary && isEnabled }

        var body: some View {
            configuration.label
                .font(StabilyzFont.buttonLabel)
                .foregroundStyle(label)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(fill)
                // Edge to edge, not the width of the label.
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: Motion.buttonPress), value: configuration.isPressed)
        }

        private var label: Color {
            guard isEnabled else { return StabilyzColor.ink400 }
            return isFilled ? StabilyzColor.onPrimary : StabilyzColor.ink900
        }

        /// The hairline is not decoration: `.ultraThinMaterial` has almost no
        /// edge of its own against `bg-base`, so without it the capsule loses
        /// its shape entirely.
        @ViewBuilder
        private var fill: some View {
            if isFilled {
                Capsule().fill(StabilyzColor.primary600)
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .strokeBorder(StabilyzColor.ink200, lineWidth: Metrics.hairline)
                    )
            }
        }
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    /// The standard full-width primary (§4: 50pt).
    static var primaryCapsule: CapsuleButtonStyle {
        CapsuleButtonStyle(role: .primary, height: Controls.buttonHeight)
    }

    /// The taller primary for single-decision screens (§4: 55pt).
    static var primaryCapsuleHero: CapsuleButtonStyle {
        CapsuleButtonStyle(role: .primary, height: Controls.heroButtonHeight)
    }

    /// The standard full-width secondary (§4: 50pt).
    static var secondaryCapsule: CapsuleButtonStyle {
        CapsuleButtonStyle(role: .secondary, height: Controls.buttonHeight)
    }

    /// The secondary beside a hero primary (§4: 55pt).
    static var secondaryCapsuleHero: CapsuleButtonStyle {
        CapsuleButtonStyle(role: .secondary, height: Controls.heroButtonHeight)
    }
}
