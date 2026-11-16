import SwiftUI

/// Where the timer ring is on the walk screen, published so the countdown
/// numeral can sit in the ring's centre rather than at a guessed height.
///
/// The numeral is drawn by the cover above the scrim, but its position belongs
/// to the walk's layout: the ring moves with Dynamic Type and screen height,
/// and a numeral placed by its own spacers drifted onto the ring's stroke.
struct CountdownRingAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
