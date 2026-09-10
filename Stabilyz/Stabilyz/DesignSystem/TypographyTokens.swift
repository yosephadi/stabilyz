import SwiftUI

/// The type scale from docs/design/design-system.md §3.
///
/// Every token is a **system text style with a weight**, not a fixed point
/// size. That is not a shortcut around the table: at the default Dynamic Type
/// setting each style already renders at exactly the size the document
/// specifies — large title 34, title 28, title3 20, body 17, subheadline 15 —
/// and §5 says as much for the large title. Naming the style instead of the
/// number is what makes the scale grow when the user turns text up, which §9
/// requires to at least Accessibility Large.
///
/// SF Pro is the system face, so it is inherited rather than requested. Italic
/// is never used (§3); nothing here can produce it.
enum StabilyzFont {
    /// 34 Bold — screen titles. `NavigationStack`'s large title renders this
    /// already, so a screen with a title bar needs no explicit font (§5).
    static let heading = Font.largeTitle.weight(.bold)
    /// 28 Bold — section titles.
    static let subheadingBold = Font.title.weight(.bold)
    /// 28 Medium — large numerals where bold is too heavy.
    static let subheadingRegular = Font.title.weight(.medium)
    /// 20 Bold — card titles, list section headers.
    static let subheading2Bold = Font.title3.weight(.bold)
    /// 20 Medium — card titles, less emphasis.
    static let subheading2Regular = Font.title3.weight(.medium)
    /// 17 Bold — emphasised body copy, button labels.
    static let bodyBold = Font.body.weight(.bold)
    /// 17 Medium — default body copy.
    static let bodyRegular = Font.body.weight(.medium)
    /// 15 Bold — metadata labels, timestamps.
    static let smallBold = Font.subheadline.weight(.bold)
    /// 15 Medium — captions and footnotes. **The floor** (§3).
    static let smallRegular = Font.subheadline.weight(.medium)
    /// 17 Semibold — the label on a filled primary button.
    ///
    /// `.headline` rather than `bodyBold`, because a `.borderedProminent`
    /// button is a system control and `.headline` is the weight iOS sets its
    /// own filled buttons in. Bold next to the system's semibold is the kind of
    /// difference that reads as "not quite an iOS button".
    static let buttonLabel = Font.headline
    /// 13 Regular — **the one style below the 15pt floor** (§3).
    ///
    /// Reserved for a hint that restates something already on screen, where the
    /// reader has the full-size version a few points away: today that is the
    /// single line under a disabled primary button, whose subject is the
    /// checkbox directly above it. It may not carry anything the user could
    /// only learn here.
    static let footnote = Font.footnote

    /// The point size each token renders at with Dynamic Type at its default
    /// setting, for tests that hold the scale to the document.
    ///
    /// `.footnote` and `.caption` are absent from the scale on purpose: both sit
    /// below the 15pt floor, so no token may map to them.
    static let specifiedSizes: [(name: String, style: Font.TextStyle, points: CGFloat)] = [
        ("heading", .largeTitle, 34),
        ("subheading", .title, 28),
        ("subheading2", .title3, 20),
        ("body", .body, 17),
        ("buttonLabel", .headline, 17),
        ("small", .subheadline, 15),
        ("footnote", .footnote, 13),
    ]

    /// The tokens §3 exempts from the 15pt floor, by name.
    ///
    /// A list rather than an omission from `specifiedSizes`: leaving `footnote`
    /// out of the scale would make the floor test pass by not looking, and the
    /// next style added below 15pt would be exempted by the same silence.
    static let belowTheFloorByException: Set<String> = ["footnote"]
}
