import CoreGraphics

/// The 4pt grid and its fixed measurements (docs/design/design-system.md §4).
enum Space {
    /// Icon-to-label gap.
    static let x1: CGFloat = 4
    /// Tight internal padding.
    static let x2: CGFloat = 8
    /// Compact internal card padding.
    static let x3: CGFloat = 12
    /// Standard internal padding; gap between related elements.
    static let x4: CGFloat = 16
    /// Default card padding; gap between unrelated groups.
    static let x6: CGFloat = 24
    /// Section spacing.
    static let x8: CGFloat = 32
    /// Major screen-section breaks.
    static let x12: CGFloat = 48

    /// Screen margins, left and right.
    static let screenMargin: CGFloat = 24
}

/// Control sizing (§4).
///
/// Separate from `Metrics`, which holds accessibility *minimums*: these are the
/// sizes the design draws, all comfortably above the 44pt floor rather than
/// derived from it.
enum Controls {
    /// Primary button, full width.
    static let buttonHeight: CGFloat = 50
    /// The taller primary used on onboarding and other single-decision screens.
    static let heroButtonHeight: CGFloat = 60
    /// The circular back control in a screen's top-left.
    static let backButtonDiameter: CGFloat = 50
    /// A row in an onboarding choice card. Comfortably above the 44pt floor,
    /// because these rows are the whole interaction on their screen.
    static let rowHeight: CGFloat = 56
}

/// Corner radii (§4). No sharp corners anywhere.
enum Radius {
    static let control: CGFloat = 8
    static let card: CGFloat = 16
    static let sheet: CGFloat = 24
}

/// Fixed accessibility minimums (§4, §9).
enum Metrics {
    /// HIG minimum tap target, non-negotiable for this user base.
    static let minimumTapTarget: CGFloat = 44
    /// Hairline used instead of a drop shadow to separate surfaces.
    static let hairline: CGFloat = 1
    /// The type floor — nothing renders smaller (§3).
    static let minimumFontSize: CGFloat = 15
}
