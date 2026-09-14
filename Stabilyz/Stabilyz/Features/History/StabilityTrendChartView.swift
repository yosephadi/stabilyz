import Charts
import SwiftUI

/// The trend card at the top of the Result tab (Figma node 64:7837,
/// design-system §6, Task 9.1.2).
///
/// The node's card, top to bottom: Baseline beside Last Test, a rule, the
/// trend's title, the chart. Every rule about what may be plotted lives in
/// `StabilityTrend`; this draws one mode's trend and nothing else.
///
/// Styled to §6 rather than to the node where the two differ: §6's flat area
/// fill under the line (the node draws none), and no dropped rule from each
/// point to the axis (the node draws one; §1 has no decoration without
/// function, and the axis labels already say which walk is which).
struct StabilityTrendChartView: View {
    let trend: StabilityTrend

    var body: some View {
        OnboardingCard {
            switch trend.state {
            case .trend:
                if let latest = trend.latest {
                    header(latest)
                    Divider().padding(.horizontal, Space.x4)
                }
                VStack(alignment: .leading, spacing: Space.x4) {
                    title
                    chart
                }
                .padding(Space.x4)

            case .calibrating, .awaitingFirstScore:
                locked
                    .padding(Space.x4)
            }
        }
    }

    private var title: some View {
        Text(trend.title)
            .font(StabilyzFont.subheading2Bold)
            .foregroundStyle(StabilyzColor.ink900)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Baseline and last test

    /// Side by side as the node draws them, and stacked when Dynamic Type
    /// leaves no room for that.
    private func header(_ latest: StabilityTrend.Point) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.x4) {
                baselineBlock
                Divider()
                lastTestBlock(latest)
            }
            VStack(alignment: .leading, spacing: Space.x4) {
                baselineBlock
                lastTestBlock(latest)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.x4)
    }

    private var baselineBlock: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(StabilityTrend.baselineLabel)
                .font(StabilyzFont.bodyBold)
                .foregroundStyle(StabilyzColor.ink900)
            Text("\(trend.baselineIndex)")
                .font(StabilyzFont.subheadingBold)
                .foregroundStyle(StabilyzColor.ink900)
        }
        .accessibilityElement(children: .combine)
    }

    private func lastTestBlock(_ latest: StabilityTrend.Point) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
                Text(StabilityTrend.lastTestLabel)
                    .font(StabilyzFont.bodyBold)
                    .foregroundStyle(StabilyzColor.timerRingTop)
                if let date = trend.lastTestDate() {
                    Text(date)
                        .font(StabilyzFont.smallRegular)
                        .foregroundStyle(StabilyzColor.ink600)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.x3) {
                Text("\(latest.index)")
                    .font(StabilyzFont.subheadingBold)
                    .foregroundStyle(StabilyzColor.scoreNumeral(latest.index))
                deltaLine(latest.delta)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(StabilityTrend.lastTestLabel) \(trend.lastTestDate() ?? ""). "
                + StabilityTrend.scoreSentence(index: latest.index, delta: latest.delta)
        )
    }

    /// "↑8 vs. baseline", drawn as the Score screen draws it. The glyph carries
    /// the direction; the colour only reinforces it (§2.4, §9).
    private func deltaLine(_ delta: Int) -> some View {
        HStack(spacing: Space.x1) {
            if delta != 0 {
                Label("\(abs(delta))", systemImage: delta > 0 ? "arrow.up" : "arrow.down")
                    .labelStyle(.titleAndIcon)
                    .font(StabilyzFont.smallBold)
                    .foregroundStyle(StabilyzColor.primary500)
            }
            Text(delta == 0 ? "same as baseline" : "vs. baseline")
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.timerRingTop)
        }
    }

    // MARK: - The chart

    private var chart: some View {
        Chart {
            RuleMark(y: .value(StabilityTrend.baselineLabel, trend.baselineIndex))
                .foregroundStyle(StabilyzColor.chartBaseline)
                .lineStyle(StrokeStyle(
                    lineWidth: ChartMetrics.baselineRuleWidth,
                    dash: ChartMetrics.baselineDash
                ))
                .annotation(position: .bottom, alignment: .trailing) {
                    Text(StabilityTrend.baselineRuleLabel)
                        .font(StabilyzFont.smallRegular)
                        .foregroundStyle(StabilyzColor.ink600)
                }
                .accessibilityLabel(StabilityTrend.baselineLabel)
                .accessibilityValue("\(trend.baselineIndex)")

            ForEach(trend.points) { point in
                AreaMark(
                    x: .value("Walk", Double(point.position)),
                    yStart: .value("Floor", trend.yDomain.lowerBound),
                    yEnd: .value("Stability score", point.index)
                )
                .foregroundStyle(StabilyzColor.chartArea)
                .accessibilityHidden(true)

                LineMark(
                    x: .value("Walk", Double(point.position)),
                    y: .value("Stability score", point.index)
                )
                .foregroundStyle(StabilyzColor.chartLine)
                .lineStyle(StrokeStyle(lineWidth: ChartMetrics.lineWidth))
                .accessibilityHidden(true)

                PointMark(
                    x: .value("Walk", Double(point.position)),
                    y: .value("Stability score", point.index)
                )
                .symbol {
                    // §6: filled per the score scale. The ring keeps the palest
                    // bands visible on a white card; the height already says
                    // what the colour says (§9).
                    Circle()
                        .fill(StabilyzColor.score(point.index))
                        .overlay(Circle().strokeBorder(StabilyzColor.chartLine, lineWidth: Metrics.hairline))
                        .frame(width: ChartMetrics.pointDiameter, height: ChartMetrics.pointDiameter)
                }
                .annotation(position: .top, spacing: Space.x1) {
                    if trend.labelledPositions.contains(point.position) {
                        Text("\(point.index)")
                            .font(isLatest(point) ? StabilyzFont.smallBold : StabilyzFont.smallRegular)
                            .foregroundStyle(isLatest(point) ? StabilyzColor.ink900 : StabilyzColor.ink600)
                    }
                }
                .accessibilityLabel(trend.pointAccessibilityLabel(point))
            }
        }
        .chartXScale(domain: trend.xDomain)
        .chartYScale(domain: trend.yDomain)
        .chartXAxis {
            AxisMarks(values: trend.labelledPositions.map(Double.init)) { value in
                if let raw = value.as(Double.self) {
                    let position = Int(raw)
                    AxisValueLabel {
                        // At the 15pt floor: the axis default is caption-sized (§3).
                        Text(trend.axisLabel(for: position))
                            .font(position == trend.points.count ? StabilyzFont.smallBold : StabilyzFont.smallRegular)
                            .foregroundStyle(position == trend.points.count ? StabilyzColor.ink900 : StabilyzColor.ink600)
                    }
                }
            }
        }
        .chartYAxis {
            // Gridlines only: the labelled points and the baseline rule carry
            // the numbers, as the node has it. No axis border box (§6).
            AxisMarks(values: trend.gridValues) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: ChartMetrics.gridLineWidth))
                    .foregroundStyle(StabilyzColor.chartGrid)
            }
        }
        .frame(height: ChartMetrics.trendHeight)
        .accessibilityLabel(trend.accessibilitySummary)
    }

    private func isLatest(_ point: StabilityTrend.Point) -> Bool {
        point.id == trend.latest?.id
    }

    // MARK: - Nothing to plot yet

    /// The card still stands, titled for the mode, so the user learns where
    /// the trend will appear and what it is waiting for.
    private var locked: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            title

            if let headline = trend.lockedHeadline {
                Text(headline)
                    .font(StabilyzFont.bodyBold)
                    .foregroundStyle(StabilyzColor.ink900)
            }

            if case .calibrating(let completed, let required) = trend.state {
                HStack(spacing: Space.x2) {
                    ForEach(0..<required, id: \.self) { index in
                        Circle()
                            .fill(index < completed ? StabilyzColor.primary600 : StabilyzColor.ink200)
                            .frame(width: Controls.progressDotDiameter, height: Controls.progressDotDiameter)
                    }
                }
                .padding(.vertical, Space.x1)
                // The headline states the count; the dots restate it.
                .accessibilityHidden(true)
            }

            if let message = trend.lockedMessage {
                Text(message)
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink600)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
