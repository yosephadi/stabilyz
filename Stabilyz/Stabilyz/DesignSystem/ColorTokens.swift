import SwiftUI

/// The palette from docs/design/design-system.md §2, as code.
///
/// Hex values live here and nowhere else: a colour typed into a view is a
/// colour that will drift from the document. The score scale (§2.4) and the
/// chart palette (§6) are deliberately absent — they arrive with the screens
/// that render them, so nothing unused has to be kept honest in the meantime.
///
/// **Light and dark.** Neutrals carry a pair and resolve against the trait
/// collection; the navy scale does not, because §8 keeps `primary-600` as the
/// interactive brand colour in both modes. Where dark mode needs a different
/// navy — a large filled area, which wants `primary-300` — that is a choice the
/// view makes, not a token that changes underneath it.
enum StabilyzColor {

    // MARK: - Primary: deep-trust navy (§2.1)

    /// Pressed states, high-emphasis text on a light background.
    static let primary900 = Color(hex: 0x0A1F3D)
    /// Headers, nav bar (dark-mode surface).
    static let primary700 = Color(hex: 0x123A66)
    /// **Brand.** Primary buttons, active states, links.
    static let primary600 = Color(hex: 0x1B4F8C)
    /// Secondary emphasis, icons.
    static let primary500 = Color(hex: 0x2E6BAE)
    /// Disabled-but-visible states, chart gridlines.
    static let primary300 = Color(hex: 0x8FB4D6)
    /// Selected-row fill, subtle highlight.
    static let primary100 = Color(hex: 0xD9E6F2)
    /// Card fill on light backgrounds.
    static let primary50 = Color(hex: 0xF0F5FA)

    // MARK: - Neutrals (§2.2)

    /// Primary text.
    static let ink900 = Color(light: 0x14181F, dark: 0xF2F3F5)
    /// Secondary text.
    static let ink600 = Color(light: 0x4B5563, dark: 0xB8BEC7)
    /// Placeholder, disabled text.
    static let ink400 = Color(light: 0x8A909B, dark: 0x7A828E)
    /// Dividers, borders.
    static let ink200 = Color(light: 0xDDE0E4, dark: 0x2A2F37)
    /// Subtle fills.
    static let ink100 = Color(light: 0xEEF0F2, dark: 0x1C2027)
    /// Screen background. Never pure black in dark mode (§8).
    static let bgBase = Color(light: 0xF7F7F7, dark: 0x0D1117)
    /// Cards, sheets.
    static let bgElevated = Color(light: 0xFFFFFF, dark: 0x161B22)

    // MARK: - Semantic (§2.3)

    /// Noisy/insufficient-data screens and other non-blocking alerts.
    ///
    /// Resolved 2026-09-10: amber and red keep their iOS meanings and stay out
    /// of score rendering entirely (§2.4). A relative index is never a pass or
    /// a fail, so it is never coloured with the vocabulary this app uses for
    /// "something went wrong".
    static let warning = Color(hex: 0xB7791B)
    /// Destructive confirmations and the permission-denied state. Nowhere else.
    static let danger = Color(hex: 0xB3261E)

    /// The label on a `primary-600` fill. White in both modes, because the
    /// tint is navy in both — this is the pair §9 checks for WCAG AA, and it is
    /// a token so `Features/` never has to type `.white`.
    static let onPrimary = Color(hex: 0xFFFFFF)

    // MARK: - Session timer ring (Figma node 130:2722)

    /// The ring's gradient, top and bottom, read verbatim from the node's SVG.
    ///
    /// Their own tokens rather than `primary700`/`primary600`, for the same
    /// reason the onboarding greys below are: the node disagrees with the navy
    /// scale by a few units at both ends at once, and re-tinting the scale to
    /// match one screen would move every other screen to follow it.
    static let timerRingTop = Color(light: 0x1D3963, dark: 0x8FB4D6)
    static let timerRingBottom = Color(light: 0x294E88, dark: 0x2E6BAE)

    /// The scrim the countdown numeral sits on (node 129:2695).
    ///
    /// Dark in both modes: it exists to push the screen behind it back, and a
    /// light scrim in dark mode would do the opposite.
    static let countdownScrim = Color(hex: 0x000000).opacity(0.45)

    /// The countdown numeral. White on the scrim in both modes.
    static let countdownNumeral = Color(hex: 0xFFFFFF)

    // MARK: - Score scale (§2.4)

    /// The relative index encoded by **saturation and value only** — never by
    /// hue. A score is a comparison against the user's own baseline, never a
    /// pass or a fail, so the amber/red vocabulary above appears nowhere near
    /// it (§2.3). Direction is carried by an ↑/↓ glyph and copy, and these only
    /// reinforce it (§9).
    ///
    /// **Dark mode inverts the scale's value direction** (§8): lighter blues
    /// read as stronger against a dark background, so the ends swap rather than
    /// the light-mode scale being reused as-is. `scoreNeutral` is its own
    /// midpoint and sits still.
    static let scoreStrong = Color(light: 0x0A1F3D, dark: 0xD3DEEA)
    static let scoreGood = Color(light: 0x1B4F8C, dark: 0xA9BDD2)
    static let scoreNeutral = Color(light: 0x6B84A0, dark: 0x6B84A0)
    static let scoreSoft = Color(light: 0xA9BDD2, dark: 0x1B4F8C)
    static let scoreLow = Color(light: 0xD3DEEA, dark: 0x0A1F3D)

    /// The scale's band for an index.
    static func score(_ index: Int) -> Color {
        switch index {
        case 115...: scoreStrong
        case 105..<115: scoreGood
        case 95..<105: scoreNeutral
        case 85..<95: scoreSoft
        default: scoreLow
        }
    }

    /// The colour the **numeral** is drawn in.
    ///
    /// Not always the band. §2.4 already makes this exception for `score-low`
    /// — "`#D3DEEA` with `ink-900` numeral, not a hue change" — because the
    /// palest end of a scale built for fills cannot carry text over `bg-base`.
    /// `score-soft` fails the same way and for the same reason (≈1.9:1, well
    /// under §9's 3:1 floor for large text), so it takes the same substitution.
    /// The band itself still encodes the index on the ring, so nothing is lost
    /// but the illegibility.
    static func scoreNumeral(_ index: Int) -> Color {
        index < 95 ? ink900 : score(index)
    }

    // MARK: - Onboarding wizard (§2.5)

    /// Read verbatim from Figma node 40:835, which is the authority for what
    /// this wizard draws.
    ///
    /// They are their own tokens rather than edits to the scales above because
    /// the node disagrees with those scales by a few units in several places at
    /// once — `#4D5562` under the question, `#575F6C` over the progress bar —
    /// and the two greys are different on purpose. Re-tinting `ink-600` to one
    /// of them would silently move every other screen in the app to match one
    /// screen's read, and could not represent the other grey at all.
    ///
    /// Only the light values come from Figma; the design has no dark mode yet,
    /// so the dark halves borrow the neutral scale in §2.2 rather than invent a
    /// palette the document does not contain.

    /// The question. `#000000`, not `ink-900` — §8's "never pure black" is
    /// about dark-mode *surfaces*, and this is a light-mode title.
    static let onboardingTitle = Color(light: 0x000000, dark: 0xF2F3F5)
    /// The "why we ask" line beneath the question.
    static let onboardingSubtitle = Color(light: 0x4D5562, dark: 0xB8BEC7)
    /// "3 out of 5", above the progress bar.
    static let progressLabel = Color(light: 0x575F6C, dark: 0xB8BEC7)
    /// A step already reached.
    static let progressFill = Color(light: 0x1D3963, dark: 0x8FB4D6)
    /// A step not yet reached.
    static let progressTrack = Color(light: 0xDBE3F3, dark: 0x2A2F37)

    // MARK: - Restore (Figma nodes 64:3890, 94:579, 94:665, 94:722)

    /// Light values read verbatim from the nodes; the design has no dark mode,
    /// so the dark halves are chosen to stay legible on dark `bg-base`.

    /// The one-line problem above the passphrase field ("That passphrase
    /// didn't work"). A muted coral rather than `danger`: nothing here is
    /// destructive, and §2.3 keeps `danger` for what is. The words carry the
    /// problem; the colour only reinforces it (§9).
    static let restoreProblem = Color(light: 0xBE4C4C, dark: 0xE38B8B)
    /// The helper and problem explanation beneath the field.
    static let restoreHelper = Color(light: 0x697281, dark: 0xB8BEC7)
    /// The neutral tile standing in for the picked file.
    static let fileThumbnail = Color(light: 0xD9D9D9, dark: 0x2A2F37)
}

// MARK: - Hex

extension Color {
    /// A colour that is the same in both modes.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// A colour with a dark-mode variant, resolved by the system rather than by
    /// anything reading the environment itself.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
