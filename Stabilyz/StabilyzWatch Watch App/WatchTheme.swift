import SwiftUI

/// The watch's tokens [PRD §8: dark background, navy primary, 15 pt minimum].
///
/// The watch target cannot compile the phone's `DesignSystem/`, so the navy is
/// repeated here: `primary600` and its white label from
/// `Stabilyz/DesignSystem/ColorTokens.swift`, the pair checked for WCAG AA.
/// Change them together.
enum WatchTheme {
    static let background = Color.black
    static let primary = primaryRGB.color
    static let onPrimary = Color.white
    static let text = Color.white
    static let secondaryText = Color(white: 0.75)

    // MARK: Colour values, kept as numbers so a test can compute their contrast
    //
    // Non-text contrast needs 3:1 (WCAG 1.4.11). The navy alone is 2.54:1 on
    // black, so the capsule carries a 1 pt lighter outline, and the progress
    // fill is the light blue the phone's dark mode uses (`progressFill`) on a
    // lighter-than-black track.

    static let primaryRGB = WatchRGB(hex: 0x1B4F8C)
    static let onPrimaryRGB = WatchRGB(hex: 0xFFFFFF)
    static let backgroundRGB = WatchRGB(hex: 0x000000)
    /// The 1 pt boundary of the navy capsule, against black.
    static let capsuleOutlineRGB = WatchRGB(hex: 0x3F78B5)
    static let progressFillRGB = WatchRGB(hex: 0x8FB4D6)
    static let progressTrackRGB = WatchRGB(hex: 0x3A3F47)

    static let capsuleOutline = capsuleOutlineRGB.color
    static let progressFill = progressFillRGB.color
    static let track = progressTrackRGB.color
    static let capsuleOutlineWidth: CGFloat = 1
    static let progressBarHeight: CGFloat = 8

    /// Text styles only from here: none renders below 15 pt on watchOS.
    static let title = Font.title3.weight(.semibold)
    static let body = Font.body
    static let heading = Font.headline

    // MARK: Big numbers
    //
    // The countdown numeral and the walk timer scale with Dynamic Type from
    // these base sizes (the approved design), up to a cap, and shrink rather
    // than clip on a small watch (`bigNumber`).

    static let numeralBaseSize: CGFloat = 72
    static let numeralMaxSize: CGFloat = 96
    static let timerBaseSize: CGFloat = 52
    static let timerMaxSize: CGFloat = 68
    /// How far a big number may shrink to fit one line.
    static let bigNumberMinimumScale: CGFloat = 0.5
    /// The big numbers' size when a screen would otherwise have to scroll, so
    /// the words around them stay in view.
    static let compactNumberScale: CGFloat = 0.7
    /// The smallest step, for the largest text sizes on the smallest watch.
    static let tightNumberScale: CGFloat = 0.5

    /// The Dynamic Type-scaled size, capped, then scaled for a compact layout.
    static func numeral(size: CGFloat, scale: CGFloat = 1) -> Font {
        .system(size: min(size, numeralMaxSize) * scale, weight: .bold, design: .rounded)
    }

    static func timer(size: CGFloat, scale: CGFloat = 1) -> Font {
        .system(size: min(size, timerMaxSize) * scale, weight: .semibold, design: .rounded).monospacedDigit()
    }

    // MARK: Layout

    /// The primary action capsule: Stop and Done [PRD §8: 55 pt Stop].
    static let capsuleHeight: CGFloat = 55
    static let spacing: CGFloat = 8
    /// The side margin every screen shares, so no text runs edge to edge.
    static let screenMargin: CGFloat = 8
    static let pressedOpacity: Double = 0.7
    static let disabledOpacity: Double = 0.5
}

/// The solid navy capsule, shared by Stop and Done, so the two primary actions
/// look like one control rather than one solid and one system-translucent.
struct WatchPrimaryCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WatchTheme.heading)
            .foregroundStyle(WatchTheme.onPrimary)
            .frame(maxWidth: .infinity, minHeight: WatchTheme.capsuleHeight)
            .background(Capsule().fill(WatchTheme.primary))
            .overlay(Capsule().strokeBorder(WatchTheme.capsuleOutline, lineWidth: WatchTheme.capsuleOutlineWidth))
            .opacity(isEnabled ? (configuration.isPressed ? WatchTheme.pressedOpacity : 1) : WatchTheme.disabledOpacity)
    }
}

extension ButtonStyle where Self == WatchPrimaryCapsuleStyle {
    static var watchPrimaryCapsule: WatchPrimaryCapsuleStyle { WatchPrimaryCapsuleStyle() }
}

extension View {
    /// One line, shrinking rather than clipping on a small watch or at a large
    /// text size.
    func bigNumber() -> some View {
        lineLimit(1).minimumScaleFactor(WatchTheme.bigNumberMinimumScale)
    }

    /// Wraps onto as many lines as it needs instead of truncating. The screen
    /// scrolls if they do not fit.
    func wrapping() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}

/// An sRGB colour held as numbers, so its WCAG contrast can be computed.
nonisolated struct WatchRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// WCAG 2.x relative luminance.
    var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1...21.
    func contrast(with other: WatchRGB) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
