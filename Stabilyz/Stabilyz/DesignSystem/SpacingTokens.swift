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
    /// Break between a screen's chrome and its question (Figma 40:835: the
    /// progress bar ends at y=218, the question starts at y=258).
    static let x10: CGFloat = 40
    /// Major screen-section breaks.
    static let x12: CGFloat = 48

    /// Screen margins, left and right: text, chrome and the primary button.
    static let screenMargin: CGFloat = 24

    /// The answer card's margins, left and right.
    ///
    /// Deliberately 8pt wider than `screenMargin` on each side: Figma 40:835
    /// draws the card at x=16 in a 402pt frame while the question above it sits
    /// at x=24, so the card breaks the text margin rather than sharing it. That
    /// is what makes it read as a surface the copy sits on top of instead of
    /// another paragraph in the same column.
    static let cardMargin: CGFloat = 16
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
    ///
    /// 55, not the 60 Figma node 40:835 draws. The node's button is bottom
    /// anchored, so the 5pt comes off the top and the capsule keeps its
    /// position on the page; at 60 with a 17pt label it read as a slab rather
    /// than a control.
    static let heroButtonHeight: CGFloat = 55
    /// The circular back control in a screen's top-left.
    static let backButtonDiameter: CGFloat = 50
    /// A row in an onboarding choice card (Figma 40:835: three 52pt rows in a
    /// 156pt card). Above the 44pt floor, because these rows are the whole
    /// interaction on their screen.
    static let rowHeight: CGFloat = 52
    /// One capsule of the onboarding progress bar (Figma 40:835).
    static let progressBarHeight: CGFloat = 14
    /// Clearance between the primary button and the bottom safe-area edge.
    ///
    /// Figma 40:835 puts the button's bottom edge at y=770 in an 874pt frame —
    /// 104pt clear of the screen, 70pt clear of the 34pt home-indicator inset.
    /// Measured from the safe area rather than the screen so the gap is the
    /// same visible distance on a device without a home indicator.
    static let footerBottomGap: CGFloat = 70
}

/// Corner radii (§4). No sharp corners anywhere.
enum Radius {
    static let control: CGFloat = 8
    /// The answer card. Figma 40:835 draws the grouped list at 26pt — iOS 26's
    /// own grouped-list radius — which is larger than `sheet`; the two are read
    /// from different sources and neither is derived from the other, so the
    /// ordering between them carries no meaning.
    static let card: CGFloat = 26
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
