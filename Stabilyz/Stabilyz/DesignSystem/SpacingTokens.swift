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
    /// The session timer ring (Figma node 130:2722).
    ///
    /// The SVG draws a 254pt bounding box whose band runs from radius 109.55
    /// to 127 — 17.45pt of fill plus its own 5pt stroke, which `strokeBorder`
    /// reproduces as one band inset into a 254pt frame.
    static let timerRingDiameter: CGFloat = 254
    static let timerRingWidth: CGFloat = 17.5
    /// Half the band, which is how far a centred stroke has to be inset to sit
    /// inside the same circle `strokeBorder` fills. Derived rather than typed,
    /// so the two cannot drift if the band changes.
    static let timerRingInset: CGFloat = timerRingWidth / 2

    /// Clearance between the primary button and the bottom safe-area edge on a
    /// **full-screen cover** — no tab bar, no wizard chrome.
    ///
    /// Figma 128:2591 puts the button at y=690 in an 874pt frame, which is
    /// exactly where 123:914 puts Start. That is the point: the button does not
    /// jump when the cover appears over the setup screen. 874 − 34pt home
    /// indicator = 840 safe-area bottom, less the button's 745 bottom edge.
    static let coverFooterBottomGap: CGFloat = 95

    /// The gap under the mark on the Processing screen.
    ///
    /// Larger than any step on the 4pt scale, because this screen is one
    /// column of centred text with nothing else in it: the mark has to read as
    /// separate from the sentence under it rather than as its heading.
    static let processingLogoGap: CGFloat = 60

    /// The score ring on the Score screen (Figma node 150:3209, ellipse
    /// 150:3235).
    ///
    /// The node's SVG is a filled annulus from radius 90 to 100 carrying a 4pt
    /// stroke on both edges, which is one 14pt band inside a 204pt box — what
    /// `strokeBorder` draws directly. It wears the same vertical gradient as
    /// the session timer ring, so the screen that reports the walk echoes the
    /// one that measured it.
    static let scoreRingDiameter: CGFloat = 204
    static let scoreRingWidth: CGFloat = 14
    /// Half the band, which is how far a centred stroke has to be inset to sit
    /// inside the same circle `strokeBorder` fills. Derived rather than typed,
    /// so the two cannot drift if the band changes.
    static let scoreRingInset: CGFloat = scoreRingWidth / 2

    /// One dot of the baseline-calibration indicator under the score ring.
    ///
    /// Not a control and not a tap target — it is a read-only count of five,
    /// restated in words directly above it, so it is sized to be counted at a
    /// glance rather than to the 44pt floor.
    static let progressDotDiameter: CGFloat = 10

    /// A grouped-list section header block (Figma node 123:914 draws each
    /// "Section Title" 39pt tall).
    ///
    /// The height is the header *and* the gap under it: the node puts its
    /// content at y=39 with nothing between. Implemented as a minimum with the
    /// text at the top, so the gap is what gives way when Dynamic Type grows
    /// the label rather than the label being clipped.
    static let sectionHeaderHeight: CGFloat = 39
    /// The **large** segmented control — Test Mode (Figma node 123:1485 draws
    /// it 50pt tall, with its two 46pt options inset 2pt).
    ///
    /// SwiftUI's `.segmented` picker is ~32pt by default, which is the compact
    /// variant. This is the size the node specifies (`variantSize="Large"`),
    /// and it matters for the same reason `rowHeight` does: choosing the test
    /// is the first real decision on the screen, and 32pt of tap target for it
    /// is mean on a hand that may not be steady.
    ///
    /// Equal to `buttonHeight` by coincidence rather than derivation — the two
    /// are read from different nodes and neither follows the other.
    static let segmentedControlHeight: CGFloat = 50
    /// One capsule of the onboarding progress bar (Figma 40:835).
    static let progressBarHeight: CGFloat = 14
    /// The wave mark above the app name on Welcome (Figma 47:1275).
    static let logoHeight: CGFloat = 60
    /// The wave mark on the splash, at 1.5x `logoHeight`.
    ///
    /// Its own token rather than a shared one: on Welcome the mark is a label
    /// sitting above the app's name, and on the splash it is the only thing on
    /// screen. The same 60pt reads as correct in the first place and as lost in
    /// the second.
    static let splashLogoHeight: CGFloat = 90
    /// Clearance between the primary button and the bottom safe-area edge, on a
    /// screen with **no tab bar**.
    ///
    /// Figma 40:835 puts the button's bottom edge at y=770 in an 874pt frame —
    /// 104pt clear of the screen, 70pt clear of the 34pt home-indicator inset.
    /// Measured from the safe area rather than the screen so the gap is the
    /// same visible distance on a device without a home indicator.
    static let footerBottomGap: CGFloat = 70

    /// The same clearance on a screen **inside the tab bar**.
    ///
    /// Figma 123:914 puts the button's bottom edge at y=745 and the tab bar's
    /// top at y=779 — 34pt between them. Inside a `TabView` the safe area
    /// already stops at the tab bar, so this is measured from there, and
    /// `footerBottomGap` would stack 70pt *on top of* the tab bar: the button
    /// climbs into the content and the scroll area loses the difference.
    ///
    /// Equal to the home-indicator inset by coincidence, not derivation — this
    /// one is the gap the node draws above a tab bar, and moves with that node.
    static let tabFooterBottomGap: CGFloat = 34
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
