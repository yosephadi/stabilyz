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
