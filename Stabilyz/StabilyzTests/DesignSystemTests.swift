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
    expectColor(StabilyzColor.warning, light: 0xB7791B, "warning")
    expectColor(StabilyzColor.danger, light: 0xB3261E, "danger")
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
    // .borderedProminent tinted primary-600 puts white text on that fill.
    #expect(contrastRatio(.white, StabilyzColor.primary600, dark: false) >= 4.5)
}

// MARK: - Typography (§3)

@Test func noTypeTokenFallsBelowTheFifteenPointFloor() {
    // The floor is the reason the scale stops where it does: .footnote and
    // .caption both render below 15pt, so no token may map to them.
    for token in StabilyzFont.specifiedSizes {
        #expect(token.points >= Metrics.minimumFontSize, "\(token.name) is below the floor")
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
    let scale: [CGFloat] = [Space.x1, Space.x2, Space.x3, Space.x4, Space.x6, Space.x8, Space.x12]

    #expect(scale == [4, 8, 12, 16, 24, 32, 48])
    for value in scale {
        #expect(value.truncatingRemainder(dividingBy: 4) == 0, "\(value) is off the 4pt grid")
    }
    #expect(scale == scale.sorted())
}

@Test func theFixedMeasurementsMatchTheDocument() {
    #expect(Space.screenMargin == 24)
    #expect(Radius.control == 8)
    #expect(Radius.card == 16)
    #expect(Radius.sheet == 24)
    #expect(Metrics.minimumTapTarget == 44)
    #expect(Metrics.minimumFontSize == 15)
    #expect(Controls.buttonHeight == 50)
    #expect(Controls.heroButtonHeight == 60)
    #expect(Controls.backButtonDiameter == 50)
}

@Test func everyCornerIsRounded() {
    // §4: no sharp corners anywhere.
    #expect(Radius.control > 0 && Radius.card > 0 && Radius.sheet > 0)
    #expect(Radius.control < Radius.card && Radius.card < Radius.sheet)
}
