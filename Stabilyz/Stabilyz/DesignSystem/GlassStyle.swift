import SwiftUI

/// Where a glass surface is being used, which decides how it behaves rather
/// than how it looks — the material is deliberately the same everywhere
/// (docs/decisions.md §26).
enum GlassSurface {
    /// Something the user presses. Reacts to touch on iOS 26.
    case button
    /// A content panel: the onboarding answer card, a score card.
    case card
    /// Navigation furniture — the back chip, a floating bar.
    case chrome
}

extension View {

    /// Liquid Glass on iOS 26, `.ultraThinMaterial` below it.
    ///
    /// Progressive enhancement, not a fork: both branches produce a translucent
    /// surface in the same shape, so layout, hit-testing and contrast are
    /// identical either way and only the material differs. The deployment
    /// target stays 17.0 (docs/decisions.md §26).
    ///
    /// The shape is always passed in rather than defaulted, because a glass
    /// surface whose shape disagrees with its content's clipping is the one way
    /// this reads as a bug rather than a style.
    @ViewBuilder
    func adaptiveGlass(_ surface: GlassSurface, in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(surface.glass, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

@available(iOS 26.0, *)
private extension GlassSurface {
    var glass: Glass {
        switch self {
        case .button: .regular.interactive()
        case .card, .chrome: .regular
        }
    }
}

// MARK: - Primary button

/// The full-width capsule primary (§5): translucent glass, a hairline edge and
/// an `ink-900` label.
///
/// **Not** `.borderedProminent` or `.glassProminent`. Both paint the button as a
/// solid `primary-600` slab with white text, which is the opposite of what the
/// onboarding designs draw — there the button reads as glass over the page, not
/// as a blue rectangle on top of it. Building the surface here rather than
/// borrowing a system prominent style is what makes the label colour ours to
/// set, and `adaptiveGlass` keeps the iOS 17 fallback in one place.
///
/// The hairline is what stops the button dissolving into a light background:
/// glass alone has very little edge against `bg-base`, and on the iOS 17
/// fallback `.ultraThinMaterial` has none at all.
struct GlassCapsuleButtonStyle: ButtonStyle {
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
                .font(StabilyzFont.bodyBold)
                .foregroundStyle(StabilyzColor.ink900)
                .frame(maxWidth: .infinity, minHeight: height)
                .adaptiveGlass(.button, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(StabilyzColor.ink200, lineWidth: Metrics.hairline)
                )
                // A disabled primary always has copy beneath it saying why
                // [PRD §6], so this only has to read as unavailable.
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == GlassCapsuleButtonStyle {
    /// The standard full-width primary (§4: 50pt).
    static var glassCapsule: GlassCapsuleButtonStyle {
        GlassCapsuleButtonStyle(height: Controls.buttonHeight)
    }

    /// The taller primary for single-decision screens (§4: 60pt).
    static var glassCapsuleHero: GlassCapsuleButtonStyle {
        GlassCapsuleButtonStyle(height: Controls.heroButtonHeight)
    }
}
