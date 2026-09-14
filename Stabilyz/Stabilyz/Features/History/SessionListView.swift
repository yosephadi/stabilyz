import SwiftUI

/// The Result tab's session list (Figma node 64:7837, docs/04 §4.13).
///
/// Built to the node: the selected mode's trend card and its summary line
/// (Task 9.1.2), then the "Recent Sessions" group — a 20pt bold section title
/// over a 26pt grouped card at the 24pt screen margin, one row per walk, each
/// with a chevron into that walk's Score screen. The node's share button is not
/// here; it belongs to the clinician summary (Task 9.2.1).
///
/// A `ScrollView` of primitives rather than `List(.insetGrouped)`: the trend
/// card sits above the list, and a grouped list embedded under other content
/// brings a second set of margins and its own scroll view (§5).
struct SessionListView: View {
    @Bindable var model: SessionListViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x6) {
                modePicker

                switch model.content {
                case .waiting:
                    EmptyView()
                case .sessions:
                    if model.showsFailureBanner {
                        failureBanner
                    }
                    trendGroup(model.trend)
                    sessionsGroup
                case .empty:
                    let empty = model.emptyState
                    StateMessage(
                        glyph: "figure.walk",
                        title: empty.title,
                        message: empty.message,
                        actionTitle: empty.actionTitle,
                        action: model.setUp
                    )
                case .failed:
                    StateMessage(
                        glyph: "exclamationmark.circle",
                        title: SessionListViewModel.failedTitle,
                        message: SessionListViewModel.failedMessage,
                        actionTitle: SessionListViewModel.retryLabel,
                        action: { Task { await model.load() } }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.screenMargin)
            .padding(.top, Space.x4)
            .padding(.bottom, Space.x8)
        }
        .background(StabilyzColor.bgBase)
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    // MARK: - Mode

    /// The node's Small segmented control: the stock size, so no height token.
    private var modePicker: some View {
        Picker(SessionListViewModel.modePickerLabel, selection: modeBinding) {
            ForEach(TestMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var modeBinding: Binding<TestMode> {
        Binding(get: { model.mode }, set: { model.select($0) })
    }

    // MARK: - Trend

    /// The trend card, and under it the latest scored walk's summary line, as
    /// the node places it.
    private func trendGroup(_ trend: StabilityTrend) -> some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            StabilityTrendChartView(trend: trend)
            if let summary = trend.latestSummary {
                Text(summary)
                    .font(StabilyzFont.smallRegular)
                    .foregroundStyle(StabilyzColor.ink900)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Sessions

    private var sessionsGroup: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            Text(SessionListViewModel.sectionTitle)
                .font(StabilyzFont.subheading2Bold)
                .foregroundStyle(StabilyzColor.ink900)
                .accessibilityAddTraits(.isHeader)

            OnboardingCard {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().padding(.horizontal, Space.x4)
                    }
                    NavigationLink {
                        SessionScoreView(presentation: row.detail, done: nil)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        SessionRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(SessionListViewModel.rowHint)
                }
            }
        }
    }

    private var failureBanner: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(SessionListViewModel.bannerMessage)
                .font(StabilyzFont.bodyRegular)
                .foregroundStyle(StabilyzColor.ink900)
                .fixedSize(horizontal: false, vertical: true)

            Button(SessionListViewModel.retryLabel) {
                Task { await model.load() }
            }
            .font(StabilyzFont.bodyBold)
            .foregroundStyle(StabilyzColor.primary600)
            .frame(minHeight: Metrics.minimumTapTarget, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.x4)
        .background(StabilyzColor.bgElevated, in: RoundedRectangle(cornerRadius: Radius.card))
    }
}

/// A whole-area message under the segment: the empty and failed states.
///
/// The completion gate's shape — one mark, a title, a sentence, one action —
/// so a screen with nothing on it still reads as a place in the app with a
/// next step, not as a blank. The mark is decorative: the title says the same
/// thing, so it is hidden from VoiceOver.
private struct StateMessage: View {
    let glyph: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: Space.x4) {
            Image(systemName: glyph)
                .font(StabilyzFont.completionGlyph)
                // Disabled-but-visible: nothing here to act on yet (§2.1).
                .foregroundStyle(StabilyzColor.primary300)
                .accessibilityHidden(true)

            VStack(spacing: Space.x2) {
                Text(title)
                    .font(StabilyzFont.subheading2Bold)
                    .foregroundStyle(StabilyzColor.ink900)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink600)
            }
            .fixedSize(horizontal: false, vertical: true)

            Button(actionTitle, action: action)
                .buttonStyle(.primaryCapsule)
                .padding(.top, Space.x4)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, Space.x10)
    }
}

/// One walk: date and mode on the left, what it scored on the right, and a
/// chevron into its Score screen.
///
/// A scored walk and a calibration walk are deliberately not the same shape.
/// The relative index is bold, in ink, with its ↑/↓ delta beside it; the
/// provisional number is regular weight in secondary ink with "Walk X of 5"
/// under it, and never carries a delta — it is not a comparison [PRD §7 AC].
struct SessionRowView: View {
    let row: SessionHistoryRow

    var body: some View {
        HStack(spacing: Space.x3) {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(row.title())
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink900)
                Text(row.subtitle())
                    .font(StabilyzFont.smallRegular)
                    .foregroundStyle(StabilyzColor.ink600)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Space.x2)

            trailing

            Image(systemName: "chevron.right")
                .font(StabilyzFont.smallBold)
                // The node's tertiary grey. The whole row is the target; the
                // chevron only says so.
                .foregroundStyle(StabilyzColor.ink400)
        }
        .padding(.horizontal, Space.x4)
        .padding(.vertical, Space.x3)
        .frame(maxWidth: .infinity, minHeight: Controls.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel())
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.standing {
        case .scored(let index, let delta):
            HStack(spacing: Space.x2) {
                Text("\(index)")
                    .font(StabilyzFont.bodyBold)
                    .foregroundStyle(StabilyzColor.ink900)
                if delta == 0 {
                    Text(SessionHistoryRow.sameAsBaselineLabel)
                        .font(StabilyzFont.smallRegular)
                        .foregroundStyle(StabilyzColor.ink600)
                } else {
                    // The glyph carries the direction; the colour only
                    // reinforces it (§2.4, §9).
                    Label("\(abs(delta))", systemImage: delta > 0 ? "arrow.up" : "arrow.down")
                        .labelStyle(.titleAndIcon)
                        .font(StabilyzFont.smallBold)
                        .foregroundStyle(StabilyzColor.primary500)
                }
            }

        case .calibrating(_, _, let provisional):
            VStack(alignment: .trailing, spacing: 0) {
                Text(provisional.map { "\($0)" } ?? SessionHistoryRow.noScoreLabel)
                    .font(provisional == nil ? StabilyzFont.smallRegular : StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink600)
                if let walkLabel = row.walkLabel {
                    Text(walkLabel)
                        .font(StabilyzFont.smallRegular)
                        .foregroundStyle(StabilyzColor.ink600)
                }
            }

        case .notComparable:
            Text(SessionHistoryRow.notComparedLabel)
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.ink600)
        }
    }
}
