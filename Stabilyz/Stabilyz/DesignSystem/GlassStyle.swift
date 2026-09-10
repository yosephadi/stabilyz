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

    /// The primary button's fill: Liquid Glass on iOS 26, the bordered-prominent
    /// fill below it.
    ///
    /// `primary-600` stays the brand tint in both branches (§8), so the button
    /// is the same colour on both — on iOS 26 it is that colour *in* glass.
    @ViewBuilder
    func adaptiveGlassButtonStyle(tint: Color = StabilyzColor.primary600) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(tint)
        } else {
            buttonStyle(.borderedProminent).tint(tint)
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
