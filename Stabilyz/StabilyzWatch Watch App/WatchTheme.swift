import SwiftUI

/// The watch's tokens [PRD §8: dark background, navy primary, 15 pt minimum].
///
/// The watch target cannot compile the phone's `DesignSystem/`, so the navy is
/// repeated here: `primary600` and its white label from
/// `Stabilyz/DesignSystem/ColorTokens.swift`, the pair checked for WCAG AA.
/// Change them together.
enum WatchTheme {
    static let background = Color.black
    static let primary = Color(red: 0x1B / 255, green: 0x4F / 255, blue: 0x8C / 255)
    static let onPrimary = Color.white
    static let text = Color.white
    static let secondaryText = Color(white: 0.75)
    static let track = Color(white: 0.25)

    /// Text styles only from here: none renders below 15 pt on watchOS.
    static let title = Font.title3.weight(.semibold)
    static let body = Font.body
    static let heading = Font.headline
    static let numeral = Font.system(size: 64, weight: .bold, design: .rounded)
    static let timer = Font.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit()

    static let stopHeight: CGFloat = 55
    static let progressHeight: CGFloat = 6
    static let spacing: CGFloat = 8
}
