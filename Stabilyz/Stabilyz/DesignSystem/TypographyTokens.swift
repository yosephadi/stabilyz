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
    /// 17 Regular — default body copy.
    ///
    /// Regular, not Medium. §3's table said Medium until Figma node 123:914
    /// was read, which declares this style as SF Pro Regular at weight 400 —
    /// so the document was carrying a mistranscription from the earlier nodes.
    /// The design is the authority on its own weights; §3 has been corrected.
    static let bodyRegular = Font.body
    /// 15 Bold — metadata labels, timestamps.
    static let smallBold = Font.subheadline.weight(.bold)
    /// 15 Regular — captions and footnotes. **The floor** (§3).
    ///
    /// Regular for the same reason as `bodyRegular`. The floor is about
    /// *size*, which is unchanged at 15 — nothing here gets lighter than the
    /// system's own body weight, and nothing gets smaller.
    static let smallRegular = Font.subheadline
    /// 128 Bold — the countdown numeral (Figma node 130:2832).
    ///
    /// **The one fixed size in the scale, and deliberately so.** Every other
    /// token names a text style so Dynamic Type can grow it (§3); this one
    /// names a number because it is a glanceable numeral that has to fit
    /// inside a fixed circle from across a room, not copy anybody reads. It is
    /// paired with `minimumScaleFactor` at the call site so a longer string
    /// ("Go!") shrinks to fit rather than truncating, and VoiceOver announces
    /// each tick regardless of what is drawn.
    static let countdownNumeral = Font.system(size: 128, weight: .bold)

    /// 96 Regular — the state mark on the session completion gate.
    ///
    /// The scale's second fixed size, and for the same reason as
    /// `countdownNumeral`: it is a glyph rather than copy. Regular weight, to
    /// sit with the body text under it (§7 matches icon weight to nearby text);
    /// the size is what carries it, not the stroke. Nothing depends on reading
    /// it — the title beneath says the same thing, and the mark is hidden from
    /// VoiceOver.
    static let completionGlyph = Font.system(size: 96)

    /// 17 Semibold — the label on a filled primary button.
    ///
    /// `.headline` rather than `bodyBold`, because a `.borderedProminent`
    /// button is a system control and `.headline` is the weight iOS sets its
    /// own filled buttons in. Bold next to the system's semibold is the kind of
    /// difference that reads as "not quite an iOS button".
    static let buttonLabel = Font.headline

    /// The point size each token renders at with Dynamic Type at its default
    /// setting, for tests that hold the scale to the document.
    ///
    /// `.footnote` and `.caption` are absent from the scale on purpose: both sit
    /// below the 15pt floor, so no token may map to them. There is **no
    /// exception list** — a 13pt token existed here briefly for the one line
    /// under a disabled button, and on a screen built for readers in their 70s
    /// the sentence explaining why a button will not respond is the last place
    /// to save four points.
    static let specifiedSizes: [(name: String, style: Font.TextStyle, points: CGFloat)] = [
        ("heading", .largeTitle, 34),
        ("subheading", .title, 28),
        ("subheading2", .title3, 20),
        ("body", .body, 17),
        ("buttonLabel", .headline, 17),
        ("small", .subheadline, 15),
    ]
}
