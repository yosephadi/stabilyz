import SwiftUI
import Testing
@testable import Stabilyz

// MARK: - Helpers

/// A token's resolved sRGB components in one interface style.
private func components(_ color: Color, dark: Bool) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
    let resolved = UIColor(color).resolvedColor(with: traits)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
    return (r, g, b, a)
}

private func hex(_ value: UInt32) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    (
        CGFloat((value >> 16) & 0xFF) / 255,
        CGFloat((value >> 8) & 0xFF) / 255,
        CGFloat(value & 0xFF) / 255
    )
}

/// Tighter than one 8-bit step (1/255 ≈ 0.0039), so a single digit typed wrong
/// in a hex value fails rather than rounding into tolerance.
private let colorTolerance = 0.002

private func expectColor(
    _ color: Color,
    light: UInt32,
    dark: UInt32? = nil,
    _ name: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let expectedLight = hex(light)
    let actualLight = components(color, dark: false)
    #expect(abs(actualLight.r - expectedLight.r) < colorTolerance, "\(name) light red", sourceLocation: sourceLocation)
    #expect(abs(actualLight.g - expectedLight.g) < colorTolerance, "\(name) light green", sourceLocation: sourceLocation)
    #expect(abs(actualLight.b - expectedLight.b) < colorTolerance, "\(name) light blue", sourceLocation: sourceLocation)

    let expectedDark = hex(dark ?? light)
    let actualDark = components(color, dark: true)
    #expect(abs(actualDark.r - expectedDark.r) < colorTolerance, "\(name) dark red", sourceLocation: sourceLocation)
    #expect(abs(actualDark.g - expectedDark.g) < colorTolerance, "\(name) dark green", sourceLocation: sourceLocation)
    #expect(abs(actualDark.b - expectedDark.b) < colorTolerance, "\(name) dark blue", sourceLocation: sourceLocation)
}

/// WCAG relative luminance and contrast ratio, for §9's stated checks.
private func luminance(_ color: Color, dark: Bool) -> Double {
    let c = components(color, dark: dark)
    func channel(_ value: CGFloat) -> Double {
        let v = Double(value)
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
}

private func contrastRatio(_ a: Color, _ b: Color, dark: Bool) -> Double {
    let la = luminance(a, dark: dark)
    let lb = luminance(b, dark: dark)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

// MARK: - Colour (§2)

@MainActor
@Test func theNavyScaleMatchesTheDocumentAndIsTheSameInBothModes() {
    // §8: primary-600 stays the interactive brand colour in both modes, so the
    // navy scale carries no dark variant. Where dark mode needs a different
    // navy for a large fill, the view chooses primary-300 — the token does not
    // change underneath it.
    expectColor(StabilyzColor.primary900, light: 0x0A1F3D, "primary-900")
    expectColor(StabilyzColor.primary700, light: 0x123A66, "primary-700")
    expectColor(StabilyzColor.primary600, light: 0x1B4F8C, "primary-600")
    expectColor(StabilyzColor.primary500, light: 0x2E6BAE, "primary-500")
    expectColor(StabilyzColor.primary300, light: 0x8FB4D6, "primary-300")
    expectColor(StabilyzColor.primary100, light: 0xD9E6F2, "primary-100")
    expectColor(StabilyzColor.primary50, light: 0xF0F5FA, "primary-50")
}

@MainActor
@Test func everyNeutralCarriesItsDarkVariant() {
    expectColor(StabilyzColor.ink900, light: 0x14181F, dark: 0xF2F3F5, "ink-900")
    expectColor(StabilyzColor.ink600, light: 0x4B5563, dark: 0xB8BEC7, "ink-600")
    expectColor(StabilyzColor.ink400, light: 0x8A909B, dark: 0x7A828E, "ink-400")
    expectColor(StabilyzColor.ink200, light: 0xDDE0E4, dark: 0x2A2F37, "ink-200")
    expectColor(StabilyzColor.ink100, light: 0xEEF0F2, dark: 0x1C2027, "ink-100")
    expectColor(StabilyzColor.bgBase, light: 0xF7F7F7, dark: 0x0D1117, "bg-base")
    expectColor(StabilyzColor.bgElevated, light: 0xFFFFFF, dark: 0x161B22, "bg-elevated")
}

@MainActor
@Test func theSemanticPairIsAmberAndRedAsResolved() {
    // Resolved 2026-09-10 in the design doc: amber for non-blocking alerts, red
    // for destructive confirmations and permission-denied, and neither anywhere
    // near a score.
    expectColor(StabilyzColor.onPrimary, light: 0xFFFFFF, "on-primary")
    expectColor(StabilyzColor.warning, light: 0xB7791B, "warning")
    expectColor(StabilyzColor.danger, light: 0xB3261E, "danger")
}

/// §2.5 — read verbatim off Figma node 40:835.
///
/// These are the values most likely to be "corrected" back onto the ink scale
/// by someone who notices `#4D5562` sitting two units from `ink-600`. They are
/// two units apart because the design says so, and the two greys in the wizard
/// differ from each other as well, so neither can be folded into the scale.
@MainActor
@Test func theOnboardingPaletteMatchesTheFigmaNode() {
    expectColor(StabilyzColor.onboardingTitle, light: 0x000000, dark: 0xF2F3F5, "onboarding title")
    expectColor(StabilyzColor.onboardingSubtitle, light: 0x4D5562, dark: 0xB8BEC7, "onboarding subtitle")
    expectColor(StabilyzColor.progressLabel, light: 0x575F6C, dark: 0xB8BEC7, "progress label")
    expectColor(StabilyzColor.progressFill, light: 0x1D3963, dark: 0x8FB4D6, "progress fill")
    expectColor(StabilyzColor.progressTrack, light: 0xDBE3F3, dark: 0x2A2F37, "progress track")
}

@MainActor
@Test func theOnboardingPaletteStaysLegibleInBothModes() {
    // The two greys carry copy, so they answer to §9 like any other text
    // colour — a value taken from a design is still not allowed to be
    // unreadable.
    #expect(contrastRatio(StabilyzColor.onboardingTitle, StabilyzColor.bgBase, dark: false) >= 4.5)
    #expect(contrastRatio(StabilyzColor.onboardingSubtitle, StabilyzColor.bgBase, dark: false) >= 4.5)
    #expect(contrastRatio(StabilyzColor.progressLabel, StabilyzColor.bgBase, dark: false) >= 4.5)
    #expect(contrastRatio(StabilyzColor.onboardingTitle, StabilyzColor.bgBase, dark: true) >= 4.5)
    #expect(contrastRatio(StabilyzColor.onboardingSubtitle, StabilyzColor.bgBase, dark: true) >= 4.5)

    // The filled and unfilled halves of the bar have to be told apart at a
    // glance; the bar is the only thing on screen saying where the user is.
    #expect(contrastRatio(StabilyzColor.progressFill, StabilyzColor.progressTrack, dark: false) >= 3)
}

@MainActor
@Test func darkModeNeverUsesPureBlack() {
    // §8: #0D1117 keeps enough warmth to avoid OLED smearing.
    let base = components(StabilyzColor.bgBase, dark: true)
    #expect(base.r > 0 && base.g > 0 && base.b > 0)

    let elevated = components(StabilyzColor.bgElevated, dark: true)
    #expect(elevated.r > base.r || elevated.g > base.g || elevated.b > base.b,
            "elevated surfaces must read as lifted off the base")
}

// MARK: - Contrast (§9)

@MainActor
@Test func theTwoContrastPairsTheDocumentNamesClearWCAGAA() {
    // §9 names these two specifically. 4.5:1 is the AA threshold at body size.
    #expect(contrastRatio(StabilyzColor.ink900, StabilyzColor.bgBase, dark: false) >= 4.5)
    #expect(contrastRatio(StabilyzColor.primary600, .white, dark: false) >= 4.5)
}

@MainActor
@Test func primaryTextClearsAAInDarkModeToo() {
    // Not stated in §9, which speaks about light mode — but a dark-mode failure
    // would be just as unreadable, and the pair is the same one.
    #expect(contrastRatio(StabilyzColor.ink900, StabilyzColor.bgBase, dark: true) >= 4.5)
}

@MainActor
@Test func whiteOnTheBrandColourIsLegibleForPrimaryButtons() {
    // The primary is a .borderedProminent capsule tinted primary-600 with an
    // on-primary label, in both modes — so the pair is checked in both.
    #expect(contrastRatio(StabilyzColor.onPrimary, StabilyzColor.primary600, dark: false) >= 4.5)
    #expect(contrastRatio(StabilyzColor.onPrimary, StabilyzColor.primary600, dark: true) >= 4.5)
}

// MARK: - Typography (§3)

@Test func noTypeTokenFallsBelowTheFifteenPointFloor() {
    // The floor is the reason the scale stops where it does: .footnote and
    // .caption both render below 15pt, so no token may map to them. There is no
    // exemption list — one existed briefly for the line under a disabled
    // button, and that sentence is the last text on this screen that should
    // shrink.
    for token in StabilyzFont.specifiedSizes {
        #expect(token.points >= Metrics.minimumFontSize, "\(token.name) is below the floor")
    }
}

@MainActor
@Test func everyHelperLineInTheAppRendersAtTheFloorOrAbove() {
    // The guard the exemption list used to defeat: the scale is checked against
    // the *rendered* size, so a token that quietly mapped to .footnote or
    // .caption would fail here even if its declared number said otherwise.
    let standard = UITraitCollection(preferredContentSizeCategory: .large)

    for token in StabilyzFont.specifiedSizes {
        guard let style = uiTextStyle(token.style) else {
            Issue.record("\(token.name) maps to a text style this test cannot resolve")
            continue
        }
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: standard).pointSize
        #expect(size >= Metrics.minimumFontSize, "\(token.name) renders at \(size)pt")
    }
}

/// SwiftUI's `Font.TextStyle` and UIKit's `UIFont.TextStyle` are different
/// types with no bridge, and only the UIKit one can be measured. Every case is
/// listed rather than defaulted, so a token pointing at `.caption2` resolves and
/// fails the floor instead of returning nil and being skipped.
private func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle? {
    switch style {
    case .largeTitle: .largeTitle
    case .title: .title1
    case .title2: .title2
    case .title3: .title3
    case .headline: .headline
    case .subheadline: .subheadline
    case .body: .body
    case .callout: .callout
    case .footnote: .footnote
    case .caption: .caption1
    case .caption2: .caption2
    @unknown default: nil
    }
}

@MainActor
@Test func eachTypeTokenRendersAtTheSizeTheDocumentSpecifies() {
    // At the default Dynamic Type setting the system styles land exactly on the
    // document's numbers — which is why the tokens name styles, not sizes, and
    // still grow when the user turns text up.
    let standard = UITraitCollection(preferredContentSizeCategory: .large)

    let styles: [(String, UIFont.TextStyle, CGFloat)] = [
        ("heading", .largeTitle, 34),
        ("subheading", .title1, 28),
        ("subheading2", .title3, 20),
        ("body", .body, 17),
        ("buttonLabel", .headline, 17),
        ("small", .subheadline, 15),
    ]

    for (name, style, expected) in styles {
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: standard).pointSize
        #expect(size == expected, "\(name) renders at \(size)pt, not \(expected)pt")
    }
}

@MainActor
@Test func theScaleGrowsWithDynamicType() {
    // §9 asks for support to at least Accessibility Large; a token that ignored
    // the setting would still pass the size test above.
    let standard = UITraitCollection(preferredContentSizeCategory: .large)
    let accessible = UITraitCollection(preferredContentSizeCategory: .accessibilityLarge)

    for (_, style, _) in [("body", UIFont.TextStyle.body, 17), ("small", .subheadline, 15)] {
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: standard).pointSize
        let scaled = UIFont.preferredFont(forTextStyle: style, compatibleWith: accessible).pointSize
        #expect(scaled > base, "\(style) does not scale")
    }
}

// MARK: - Layout (§4)

@Test func theSpacingScaleIsTheFourPointGrid() {
    let scale: [CGFloat] = [Space.x1, Space.x2, Space.x3, Space.x4, Space.x6, Space.x8, Space.x10, Space.x12]

    #expect(scale == [4, 8, 12, 16, 24, 32, 40, 48])
    for value in scale {
        #expect(value.truncatingRemainder(dividingBy: 4) == 0, "\(value) is off the 4pt grid")
    }
    #expect(scale == scale.sorted())
}

@Test func theFixedMeasurementsMatchTheDocument() {
    #expect(Space.screenMargin == 24)
    #expect(Space.cardMargin == 16)
    #expect(Radius.control == 8)
    #expect(Radius.card == 26)
    #expect(Radius.sheet == 24)
    #expect(Metrics.minimumTapTarget == 44)
    #expect(Metrics.minimumFontSize == 15)
    #expect(Controls.buttonHeight == 50)
    #expect(Controls.heroButtonHeight == 55)
    #expect(Controls.backButtonDiameter == 50)
    #expect(Controls.rowHeight == 52)
    #expect(Controls.progressBarHeight == 14)
    #expect(Controls.logoHeight == 60)
    // 1.5x, and pinned as the ratio so the two move together if either does.
    #expect(Controls.splashLogoHeight == 90)
    #expect(Controls.splashLogoHeight == Controls.logoHeight * 1.5)
    #expect(Controls.footerBottomGap == 70)
}

/// The measurements read straight off Figma node 40:835, checked as the
/// geometry they came from rather than as bare numbers — the node lays the
/// screen out on a 402x874 frame, so the tokens have to reconstruct it.
@Test func theOnboardingTokensReconstructTheFigmaFrame() {
    let frameWidth: CGFloat = 402

    // The question sits at x=24 in a 354pt column; the card breaks that margin
    // and sits at x=16 in a 370pt one.
    #expect(frameWidth - 2 * Space.screenMargin == 354)
    #expect(frameWidth - 2 * Space.cardMargin == 370)
    #expect(Space.cardMargin < Space.screenMargin, "the card no longer breaks the text margin")

    // Back chip at y=100 under a 59pt safe-area inset; three 52pt rows make the
    // 156pt card; the button's bottom edge lands at y=770 in an 874pt frame
    // once the 34pt home-indicator inset is added back.
    #expect(59 + Space.x10 + Controls.backButtonDiameter == 149)
    #expect(3 * Controls.rowHeight == 156)
    #expect(874 - 34 - Controls.footerBottomGap == 770)

    // The button is bottom anchored, so trimming it from the node's 60pt to 55
    // takes the 5pt off the top and leaves that bottom edge where Figma put it.
    #expect(Controls.heroButtonHeight == 55)
    #expect(770 - Controls.heroButtonHeight == 715)
}

@Test func aChoiceRowClearsTheTapTargetFloor() {
    // §5 draws these at 52pt; §9's floor is 44. The row is the whole
    // interaction on its screen, so it may never be the tighter of the two.
    #expect(Controls.rowHeight >= Metrics.minimumTapTarget)
    #expect(Controls.backButtonDiameter >= Metrics.minimumTapTarget)
    #expect(Controls.buttonHeight >= Metrics.minimumTapTarget)
    #expect(Controls.heroButtonHeight >= Controls.buttonHeight)
}

// MARK: - Motion (§10)

@Test func theSplashLandsInsideTheBudgetTheDocumentSets() {
    // §10: launch to hand-off in 0.8-0.9s. The splash runs beside `resolve()`
    // rather than before it, so this is what the launch costs only on a device
    // where reading a profile is slower than the countdown.
    #expect(Motion.splashTotal == Motion.splashReveal + Motion.splashHold)
    #expect(Motion.splashTotal >= 0.8)
    #expect(Motion.splashTotal <= 0.9)

    // The mark has to settle before it is taken away, or the reveal is a
    // flicker rather than an entrance.
    #expect(Motion.splashHold > 0)
    #expect(Motion.splashReveal > Motion.splashHold)
}

@Test func theSplashMarkSettlesRatherThanGrows() {
    // Close enough to 1 to read as arriving, not as zooming.
    #expect(Motion.splashInitialScale < 1)
    #expect(Motion.splashInitialScale >= 0.9)
}

@Test func motionCoversChangesFasterThanItPerformsThem() {
    // §10's ordering, and the reason it holds: a cross-fade is covering a
    // hand-off the user did not ask to watch, and a press is confirming a touch
    // they have already made. Only the brand reveal is worth a beat.
    #expect(Motion.buttonPress < Motion.rootCrossFade)
    #expect(Motion.rootCrossFade < Motion.splashReveal)

    // Nothing in the scale may stall a user who is trying to act.
    for duration in [Motion.buttonPress, Motion.rootCrossFade, Motion.splashReveal, Motion.splashHold] {
        #expect(duration > 0)
        #expect(duration <= 1, "\(duration)s is long enough to feel like a wait")
    }
}

@MainActor
@Test func reduceMotionChangesHowThingsMoveNotHowLongLaunchTakes() {
    // The rule §10 states, pinned as arithmetic: `SplashView` sleeps
    // `splashTotal` on both paths, so turning animation off removes the reveal
    // and leaves the hand-off where it was. A separate reduced total would make
    // the app a different length for the users most likely to be disoriented by
    // it changing.
    let animated = Motion.splashReveal + Motion.splashHold
    let reduced = Motion.splashTotal      // no reveal to wait through
    #expect(animated == reduced)
}

@Test func everyCornerIsRounded() {
    // §4: no sharp corners anywhere.
    #expect(Radius.control > 0 && Radius.card > 0 && Radius.sheet > 0)

    // A control is always the tightest of the three. Card and sheet are no
    // longer ordered against each other: the card's 26pt is read from Figma
    // node 40:835 (iOS 26's grouped-list radius) and the sheet's 24pt from §4,
    // so neither is derived from the other and the comparison said nothing.
    #expect(Radius.control < Radius.card)
    #expect(Radius.control < Radius.sheet)
}
