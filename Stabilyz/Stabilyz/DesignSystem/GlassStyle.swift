import SwiftUI

/// Where a glass surface is being used, which decides how it behaves rather
/// than how it looks — the material is deliberately the same everywhere
/// (docs/decisions.md §26).
///
/// The primary button is **not** in this vocabulary any more: it is a stock
/// `.borderedProminent` capsule tinted `primary-600`, so iOS owns its surface,
/// its press animation and its disabled dimming. `.button` remains for controls
/// that are genuinely glass, like the back chip's neighbours.
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
