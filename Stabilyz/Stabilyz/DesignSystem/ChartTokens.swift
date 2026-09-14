import SwiftUI

/// The trend chart's palette (docs/design/design-system.md §6).
///
/// Built from the navy scale in `ColorTokens.swift` rather than from hex, so
/// the chart moves when the palette does.
extension StabilyzColor {
    /// The flat fill under the trend line: `primary-600` at 15% in light mode
    /// and 25% in dark (§6). No gradient (§1).
    static let chartArea = Color(
        light: primary600, lightOpacity: 0.15,
        dark: primary600, darkOpacity: 0.25
    )

    /// The trend line and the ring around each point.
    ///
    /// `primary-600` in light mode, as §6 specifies. **`primary-300` in dark
    /// mode**, which §6 does not say and §8 does: navy on the near-black card
    /// sits at about 2:1, under the 3:1 a line the reader has to follow needs
    /// (§9). §8 already makes the same swap for large filled areas.
    static let chartLine = Color(light: primary600, lightOpacity: 1, dark: primary300, darkOpacity: 1)

    /// Gridlines: `primary-300`, dimmed in dark mode (§6).
    static let chartGrid = Color(
        light: primary300, lightOpacity: 1,
        dark: primary300, darkOpacity: 0.35
    )

    /// The dashed baseline rule. Neutral rather than navy, so the reference
    /// never reads as part of the series.
    static let chartBaseline = ink400
}

/// The trend chart's strokes and size (§6).
enum ChartMetrics {
    /// The plot's height inside the card. Tall enough that a spread of twenty
    /// index points is not a flat line; short enough that the card and the
    /// first sessions share a screen.
    static let trendHeight: CGFloat = 180
    /// §6: a 2pt stroke.
    static let lineWidth: CGFloat = 2
    /// §6: thin.
    static let gridLineWidth: CGFloat = Metrics.hairline
    static let baselineRuleWidth: CGFloat = Metrics.hairline
    static let baselineDash: [CGFloat] = [4, 4]
    /// §6: a small filled circle per session.
    static let pointDiameter: CGFloat = 10
}

extension Color {
    /// A colour whose light and dark variants are other tokens at an opacity.
    init(light: Color, lightOpacity: Double, dark: Color, darkOpacity: Double) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark).resolvedColor(with: traits).withAlphaComponent(darkOpacity)
                : UIColor(light).resolvedColor(with: traits).withAlphaComponent(lightOpacity)
        })
    }
}
