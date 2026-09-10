import SwiftUI

/// The onboarding primary: a full-width capsule at `button-height-hero`
/// (design-system.md §5).
///
/// **Why this is a style and not `.borderedProminent`.** The enabled half is
/// exactly what the system draws — a `primary-600` capsule with a white
/// label — but the disabled half is not. `.borderedProminent` dims its own
/// fill, which turns the button into an opaque grey slab: heavier on the page
/// than the enabled button it replaces, and the loudest thing on a screen where
/// the user has not done anything yet. Disabled here is a translucent capsule
/// with a hairline edge and an `ink-400` label — present, legible, and plainly
/// not ready.
///
/// The sizing and the `contentShape` are applied to `configuration.label`, so
/// the whole capsule is the hit area rather than the width of the word inside
/// it. That is the one detail this style exists to guarantee for every caller.
struct PrimaryCapsuleButtonStyle: ButtonStyle {
    /// `Controls.buttonHeight` or `Controls.heroButtonHeight` (§4).
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, height: height)
    }

    /// A nested `View` so the style can read `isEnabled` — a `ButtonStyle` is
    /// not itself a view and has no environment of its own.
    private struct Surface: View {
        let configuration: Configuration
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(StabilyzFont.buttonLabel)
                .foregroundStyle(
                    isEnabled ? StabilyzColor.onPrimary : StabilyzColor.ink400
                )
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(fill)
                // Edge to edge, not the width of the label.
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }

        /// `.ultraThinMaterial` when disabled: the page shows through, which is
        /// what makes it read as unavailable without adding weight. The
        /// hairline is not decoration — the material has almost no edge of its
        /// own against `bg-base`, so without it the button loses its shape.
        @ViewBuilder
        private var fill: some View {
            if isEnabled {
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

extension ButtonStyle where Self == PrimaryCapsuleButtonStyle {
    /// The standard full-width primary (§4: 50pt).
    static var primaryCapsule: PrimaryCapsuleButtonStyle {
        PrimaryCapsuleButtonStyle(height: Controls.buttonHeight)
    }

    /// The taller primary for single-decision screens (§4: 55pt).
    static var primaryCapsuleHero: PrimaryCapsuleButtonStyle {
        PrimaryCapsuleButtonStyle(height: Controls.heroButtonHeight)
    }
}
