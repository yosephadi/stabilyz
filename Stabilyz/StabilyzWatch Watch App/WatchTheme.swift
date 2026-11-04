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
