import SwiftUI

/// The Clinician Summary (docs/04 §4.14, [PRD §5, §7], Task 9.2.1).
///
/// One screen the user hands over at an appointment: the mode segment, then
/// that mode's baseline parameters (μ ± σ), its last scored sessions, and the
/// same trend the Result tab draws. Built from design-system tokens and the
/// existing card, row and chart components; there is no Figma frame for it.
///
/// Presented from the Result tab in its own navigation stack with a close
/// button, as decided 2026-09-14. docs/11 §11.2 had it pushed onto History's
/// stack; a sheet keeps the tab's state untouched underneath while the phone is
/// in someone else's hand.
struct ClinicianSummaryView: View {
    @State private var model: ClinicianSummaryViewModel
    @Environment(\.dismiss) private var dismiss

    init(model: ClinicianSummaryViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x6) {
                    modePicker
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.screenMargin)
                .padding(.top, Space.x4)
                .padding(.bottom, Space.x8)
            }
            .background(StabilyzColor.bgBase)
            .navigationTitle(ClinicianSummaryViewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(ClinicianSummaryViewModel.closeLabel)
                    .accessibilityIdentifier("clinicianSummary.close")
                }
            }
            .refreshable { await model.load() }
            .task { await model.load() }
        }
    }

    // MARK: - Mode

    private var modePicker: some View {
        Picker(ClinicianSummaryViewModel.modePickerLabel, selection: modeBinding) {
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let summary = model.selected {
            if model.showsFailureBanner {
                failureCard
            }
            switch summary.status {
            case .established:
                if let baseline = summary.baseline {
                    parametersSection(baseline, summary: summary)
                }
                recentSection(summary)
                if let trend = summary.trend {
                    StabilityTrendChartView(trend: trend)
                }
            case .notStarted, .calibrating, .baselineRefused:
                statusCard(summary)
            }
        } else if model.phase == .failed {
            failureCard
        }
    }

    private func sectionHeader(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(title)
                .font(StabilyzFont.subheading2Bold)
                .foregroundStyle(StabilyzColor.ink900)
                .accessibilityAddTraits(.isHeader)
            Text(caption)
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.ink600)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Not established

    /// The defined empty and partial states [PRD §6]: a mode with no walks,
    /// one still calibrating, and one whose baseline was not established.
    private func statusCard(_ summary: ClinicianModeSummary) -> some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: Space.x2) {
                Text(summary.baselineTitle)
                    .font(StabilyzFont.subheading2Bold)
                    .foregroundStyle(StabilyzColor.ink900)
                    .accessibilityAddTraits(.isHeader)

                Text(summary.statusText())
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink600)

                if case .calibrating(let completed, let required) = summary.status {
                    HStack(spacing: Space.x2) {
                        ForEach(0..<required, id: \.self) { index in
                            Circle()
                                .fill(index < completed ? StabilyzColor.primary600 : StabilyzColor.ink200)
                                .frame(width: Controls.progressDotDiameter, height: Controls.progressDotDiameter)
                        }
                    }
                    .padding(.vertical, Space.x1)
                    // The line above states the count; the dots restate it.
                    .accessibilityHidden(true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.x4)
        }
    }

    // MARK: - Baseline parameters

    private func parametersSection(
        _ baseline: ClinicianModeSummary.BaselineParameters,
        summary: ClinicianModeSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            sectionHeader(ClinicianModeSummary.parametersTitle, caption: summary.statusText())

            OnboardingCard {
                ForEach(Array(baseline.parameters.enumerated()), id: \.element.id) { index, parameter in
                    if index > 0 {
                        Divider().padding(.horizontal, Space.x4)
                    }
                    parameterRow(parameter)
                }
            }

            VStack(alignment: .leading, spacing: Space.x1) {
                Text(ClinicianModeSummary.parametersCaption)
                if baseline.anyFloorApplied {
                    Text(ClinicianModeSummary.floorFootnote)
                }
            }
            .font(StabilyzFont.smallRegular)
            .foregroundStyle(StabilyzColor.ink600)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func parameterRow(_ parameter: ClinicianModeSummary.Parameter) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.x3) {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(parameter.label)
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink900)
                if let sampleSize = parameter.sampleSize {
                    Text(sampleSize)
                        .font(StabilyzFont.smallRegular)
                        .foregroundStyle(StabilyzColor.ink600)
                }
            }
            Spacer(minLength: Space.x2)
            Text(parameter.displayValue())
                .font(parameter.stat == nil ? StabilyzFont.smallRegular : StabilyzFont.bodyBold)
                .foregroundStyle(parameter.stat == nil ? StabilyzColor.ink600 : StabilyzColor.ink900)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Space.x4)
        .padding(.vertical, Space.x3)
        .frame(maxWidth: .infinity, minHeight: Controls.rowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Recent sessions

    private func recentSection(_ summary: ClinicianModeSummary) -> some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            sectionHeader(summary.recentTitle, caption: ClinicianModeSummary.recentCaption)

            OnboardingCard {
                if summary.recent.isEmpty {
                    Text(ClinicianModeSummary.noScoredWalks)
                        .font(StabilyzFont.bodyRegular)
                        .foregroundStyle(StabilyzColor.ink600)
                        .frame(maxWidth: .infinity, minHeight: Controls.rowHeight, alignment: .leading)
                        .padding(.horizontal, Space.x4)
                } else {
                    ForEach(Array(summary.recent.enumerated()), id: \.element.id) { index, session in
                        if index > 0 {
                            Divider().padding(.horizontal, Space.x4)
                        }
                        recentRow(session)
                    }
                }
            }
        }
    }

    private func recentRow(_ session: ClinicianModeSummary.RecentSession) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
                Text(session.title())
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink900)
                Spacer(minLength: Space.x2)
                Text("\(session.index)")
                    .font(StabilyzFont.bodyBold)
                    .foregroundStyle(StabilyzColor.ink900)
                Text(session.deltaText)
                    .font(StabilyzFont.smallBold)
                    .foregroundStyle(StabilyzColor.ink600)
            }
            ForEach(session.measurements) { measurement in
                HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
                    Text(measurement.label)
                        .foregroundStyle(StabilyzColor.ink600)
                    Spacer(minLength: Space.x2)
                    Text(measurement.displayValue())
                        .foregroundStyle(StabilyzColor.ink900)
                        .monospacedDigit()
                }
                .font(StabilyzFont.smallRegular)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Space.x4)
        .padding(.vertical, Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.accessibilityLabel())
    }

    // MARK: - Failure

    private var failureCard: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(ClinicianSummaryViewModel.failedMessage)
                .font(StabilyzFont.bodyRegular)
                .foregroundStyle(StabilyzColor.ink900)
                .fixedSize(horizontal: false, vertical: true)
            Button(ClinicianSummaryViewModel.retryLabel) {
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
