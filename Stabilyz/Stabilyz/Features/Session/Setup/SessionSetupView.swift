import SwiftUI

/// Choose a test, choose your cues, start (Figma node 123:914, docs/04 §4.5).
///
/// The node draws the established Quick Test state; the other five cells of the
/// matrix — two modes × three baseline states — are the same layout with
/// different copy, all of it decided in `SessionSetupViewModel`.
///
/// Structure follows the node: three stacked groups at 24pt screen margins in a
/// 354pt column, each a grey section header over its content, with the primary
/// capsule anchored at the bottom on the same clearance the wizard uses. The
/// node's tab bar and "Walk" title are app chrome and belong to the router, not
/// to this screen.
struct SessionSetupView: View {
    @Bindable var model: SessionSetupViewModel
    /// The one-time backup prompt (Task 10.2.3); nil where it does not apply.
    var exportNudge: ExportNudgeViewModel? = nil

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x6) {
                    if model.permissionMessage != nil {
                        permissionCard
                    }
                    if let exportNudge, exportNudge.isVisible(given: model.baselineStates) {
                        ExportNudgeCard(nudge: exportNudge)
                    }
                    modeGroup
                    baselineGroup
                    cuesGroup
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.screenMargin)
                .padding(.top, Space.x4)
            }

            startButton
                .padding(.horizontal, Space.screenMargin)
                // Separates the button from content scrolled up against it;
                // the node's own gap here is larger only because its content
                // happens to be short.
                .padding(.top, Space.x4)
                // The tab-bar clearance, not the wizard's. This screen sits
                // inside the `TabView`, so the safe area already ends at the
                // tab bar.
                .padding(.bottom, Controls.tabFooterBottomGap)
        }
        .background(StabilyzColor.bgBase)
        .task {
            // Both, on appear: the cards and the cue rules are a function of
            // each mode's baseline state, and the permission line of a system
            // setting the user may have changed while the app was away.
            await model.refreshBaselineStates()
            await model.refreshPermission()
            // An export from Settings retires the prompt too.
            exportNudge?.refresh()
        }
    }

    // MARK: - Choose a test

    private var modeGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(SessionSetupViewModel.chooseTestHeader)

            Picker(SessionSetupViewModel.chooseTestHeader, selection: modeBinding) {
                ForEach(TestMode.allCases, id: \.self) { mode in
                    Text(model.segmentLabel(for: mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // The node's Large variant. `controlSize` alone does not resize a
            // segmented picker on iOS, so the height is set explicitly to the
            // 50pt the node draws.
            .controlSize(.large)
            .frame(height: Controls.segmentedControlHeight)

            footnote(model.modeSubtitle)
                .padding(.top, Space.x2)
        }
    }

    /// The model owns the switch, because changing mode also resets the cue
    /// toggle — the two modes' cues are different features.
    private var modeBinding: Binding<TestMode> {
        Binding(get: { model.mode }, set: { model.select($0) })
    }

    // MARK: - Baseline

    private var baselineGroup: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            sectionHeader(model.baselineCardHeader)

            Text(model.baselineHeadline)
                .font(model.baselineHeadlineIsMetric ? StabilyzFont.heading : StabilyzFont.subheading2Bold)
                .foregroundStyle(StabilyzColor.ink900)
                // The index is a number, not a word: read it as one rather than
                // spelling it out, and say what it is while doing so.
                .accessibilityLabel(
                    model.baselineHeadlineIsMetric
                        ? Text("\(model.baselineCardHeader), \(model.baselineHeadline)")
                        : Text(model.baselineHeadline)
                )

            footnote(model.baselineSupportingCopy)
        }
    }

    // MARK: - Session cues

    private var cuesGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(SessionSetupViewModel.sessionCuesHeader)

            VStack(spacing: 0) {
                toggleRow(
                    title: model.audioCueTitle,
                    subtitle: model.audioCueSubtitle,
                    isOn: $model.isAudioCueOn
                )

                Divider().overlay(StabilyzColor.ink200)

                toggleRow(
                    title: SessionSetupViewModel.hapticsTitle,
                    subtitle: SessionSetupViewModel.hapticsSubtitle,
                    isOn: $model.isHapticsOn
                )
            }
            .background(StabilyzColor.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(title)
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink900)
                Text(subtitle)
                    .font(StabilyzFont.smallRegular)
                    .foregroundStyle(StabilyzColor.ink600)
            }
        }
        .tint(StabilyzColor.primary600)
        .padding(.horizontal, Space.x4)
        .padding(.vertical, Space.x3)
        .frame(minHeight: Controls.rowHeight)
    }

    // MARK: - Permission

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(SessionSetupViewModel.permissionTitle)
                .font(StabilyzFont.subheading2Bold)
                .foregroundStyle(StabilyzColor.ink900)

            if let message = model.permissionMessage {
                Text(message)
                    .font(StabilyzFont.smallRegular)
                    .foregroundStyle(StabilyzColor.ink600)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.permissionOffersSettings {
                Button(SessionSetupViewModel.permissionSettingsLabel) {
                    model.openSystemSettings()
                }
                .font(StabilyzFont.bodyBold)
                .foregroundStyle(StabilyzColor.primary600)
                .frame(minHeight: Metrics.minimumTapTarget, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.x4)
        .background(StabilyzColor.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(StabilyzColor.danger, lineWidth: Metrics.hairline)
        }
    }

    // MARK: - Start

    private var startButton: some View {
        Button(model.startButtonTitle) { model.start() }
            .buttonStyle(.primaryCapsuleHero)
            .disabled(model.isStartEnabled == false)
            .accessibilityIdentifier("walk.start")
    }

    // MARK: - Shared bits

    /// The grey group header the node draws above each section.
    ///
    /// A 39pt block rather than a label with padding: the node's Section Title
    /// is 39pt tall and its content begins immediately after, so the space
    /// under the header belongs to the header. Text at the top, so Dynamic
    /// Type spends the gap before it grows the block.
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(StabilyzFont.subheading2Bold)
            .foregroundStyle(StabilyzColor.ink600)
            .frame(
                maxWidth: .infinity,
                minHeight: Controls.sectionHeaderHeight,
                alignment: .topLeading
            )
    }

    /// Supporting copy under a group. `smallRegular` is the 15pt floor (§3) —
    /// the node's grouped-table footers land here, and nothing on this screen
    /// goes below it.
    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(StabilyzFont.smallRegular)
            .foregroundStyle(StabilyzColor.ink600)
            .fixedSize(horizontal: false, vertical: true)
    }
}
