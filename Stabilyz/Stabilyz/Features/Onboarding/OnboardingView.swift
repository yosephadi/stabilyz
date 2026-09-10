import SwiftUI

/// The onboarding wizard (docs/04 §4.3, design-system.md §5, and the screen
/// designs in docs/design/screens).
///
/// The designs replace the large-title nav bar with an in-content header —
/// circular back chip, progress, question, then the answer card — so the
/// navigation bar is hidden and that header is drawn here instead. Everything
/// under it stays native: `List` `.insetGrouped` holding inline `Picker`s for
/// the closed-choice fields (§5 explicitly forbids a custom dropdown), a system
/// `Toggle` wearing `CheckboxToggleStyle` for the disclaimer tick, and a
/// `.borderedProminent` primary button tinted `primary-600`. Dynamic Type,
/// VoiceOver and the 44pt row height therefore still come from the system
/// rather than from us remembering.
///
/// No colour, size or spacing literal appears in this file; `DesignTokenGuardTests`
/// enforces that for the whole of `Features/`.
struct OnboardingView: View {
    @State private var model: OnboardingViewModel

    init(model: OnboardingViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                stepContent
                footer
            }
            .background(StabilyzColor.bgBase)
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(StabilyzColor.primary600)
        .task { await model.start() }
    }

    // MARK: - Header

    /// Back chip, progress, question, and the "why we ask" line beneath it.
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            backChip

            // Shown on every screen including the disclaimer: [PRD §7 AC] asks
            // for a visible progress indicator throughout, where the design
            // drops it on the final screen.
            StepProgressBar(step: model.progress.step, of: model.progress.of)

            VStack(alignment: .leading, spacing: Space.x2) {
                Text(title)
                    .font(StabilyzFont.heading)
                    .foregroundStyle(StabilyzColor.ink900)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle)
                        .font(StabilyzFont.smallRegular)
                        .foregroundStyle(StabilyzColor.ink600)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.screenMargin)
        .padding(.bottom, Space.x6)
    }

    /// The circular back control from the designs. A plain `Button` underneath,
    /// so it keeps its tap handling and VoiceOver behaviour; the space is held
    /// even on the first screen so the header below it does not jump.
    @ViewBuilder
    private var backChip: some View {
        if model.canGoBack {
            Button { model.back() } label: {
                Image(systemName: "chevron.left")
                    .font(StabilyzFont.bodyBold)
                    .foregroundStyle(StabilyzColor.ink900)
                    .frame(
                        width: Metrics.minimumTapTarget,
                        height: Metrics.minimumTapTarget
                    )
                    .background(StabilyzColor.bgElevated, in: Circle())
            }
            .accessibilityLabel("Back")
        } else {
            Color.clear
                .frame(
                    width: Metrics.minimumTapTarget,
                    height: Metrics.minimumTapTarget
                )
                .accessibilityHidden(true)
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .amputationLevel:
            answerList {
                Picker("Amputation level", selection: levelBinding) {
                    Text("Below the knee (transtibial)").tag(AmputationLevel.transtibial as AmputationLevel?)
                    Text("Above the knee (transfemoral)").tag(AmputationLevel.transfemoral as AmputationLevel?)
                    Text("Both legs (bilateral)").tag(AmputationLevel.bilateral as AmputationLevel?)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

        case .side:
            answerList {
                Picker("Side", selection: sideBinding) {
                    ForEach(model.allowedSides, id: \.self) { side in
                        Text(sideLabel(side)).tag(side as AmputationSide?)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

        case .timeSinceAmputation:
            answerList {
                Picker("Years", selection: yearsBinding) {
                    ForEach(0...60, id: \.self) { Text("\($0) years").tag($0) }
                }
                Picker("Months", selection: monthsBinding) {
                    ForEach(0...11, id: \.self) { Text("\($0) months").tag($0) }
                }
            }

        case .prosthesisType:
            answerList {
                TextField("Prosthesis or device", text: prosthesisBinding)
                    .textInputAutocapitalization(.words)
            }

        case .kLevel:
            answerList {
                Picker("Activity level", selection: kLevelBinding) {
                    Text("Prefer not to say").tag(KLevel?.none)
                    ForEach(KLevel.allCases, id: \.self) { level in
                        Text(kLevelLabel(level)).tag(level as KLevel?)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

        case .disclaimer:
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x6) {
                    Text(DisclaimerText.body)
                        .font(StabilyzFont.bodyRegular)
                        .foregroundStyle(StabilyzColor.ink600)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(DisclaimerText.acknowledgement, isOn: $model.disclaimerAccepted)
                        .toggleStyle(.checkbox)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.screenMargin)
            }
        }
    }

    /// The answer card: the designs draw a white rounded panel with hairline
    /// dividers, which is what `.insetGrouped` already is (§5 — "no custom card
    /// view is built"). Only the backgrounds are re-pointed at our tokens so
    /// `bg-base` shows through around it.
    private func answerList<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        List {
            Section {
                content()
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink900)
                    .listRowBackground(StabilyzColor.bgElevated)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Metrics.minimumTapTarget)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Space.x3) {
            if let explanation = model.blockedExplanation {
                // A disabled button always says why [PRD §6].
                Text(explanation)
                    .font(StabilyzFont.smallRegular)
                    .foregroundStyle(StabilyzColor.ink600)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure = model.saveFailure,
               let presentation = ErrorPresenter.presentation(for: failure) {
                Text(presentation.message)
                    .font(StabilyzFont.smallRegular)
                    .foregroundStyle(StabilyzColor.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(model.step == .disclaimer ? "Finish" : "Continue") {
                Task { await model.advance() }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(StabilyzColor.primary600)
            .frame(maxWidth: .infinity, minHeight: Metrics.minimumTapTarget)
            .disabled(!model.canContinue)
        }
        .padding(.horizontal, Space.screenMargin)
        .padding(.vertical, Space.x6)
        .background(StabilyzColor.bgBase)
    }

    // MARK: - Copy

    private var title: String {
        switch model.step {
        case .amputationLevel: "Your amputation"
        case .side: "Which side"
        case .timeSinceAmputation: "How long ago"
        case .prosthesisType: "Your prosthesis"
        case .kLevel: "Activity level"
        case .disclaimer: DisclaimerText.title
        }
    }

    /// The helper line under each question. On level and side this is the
    /// "why we ask" microcopy [PRD §7 AC]; the designs put it here, directly
    /// beneath the question, rather than under the answer card.
    private var subtitle: String? {
        switch model.step {
        case .amputationLevel:
            """
            Why we ask: this tells Stabilyz which measurements make sense for \
            you. Everyone gets the same core walking measurements — this only \
            decides whether one extra comparison between your two legs is \
            possible.
            """
        case .side:
            sideSubtitle
        case .timeSinceAmputation:
            "An approximate answer is fine — this is context for your results, not a measurement."
        case .prosthesisType:
            "Optional. You can leave this blank and carry on."
        case .kLevel:
            "Optional. If your prosthetist has given you a K-level, it goes here."
        case .disclaimer:
            // The disclaimer's own body is the content of the screen.
            nil
        }
    }

    private var sideSubtitle: String {
        model.draft.amputationLevel == .bilateral
            ? """
              Why we ask: with a bilateral amputation there's no sound side to \
              compare against, so Stabilyz measures how steadily you walk \
              overall and never invents a comparison it can't make.
              """
            : """
              Why we ask: knowing which side is affected lets Stabilyz compare \
              the timing of your two legs. It's a comparison, not a judgement — \
              nothing here says one side is right and the other wrong.
              """
    }

    private func sideLabel(_ side: AmputationSide) -> String {
        switch side {
        case .left: "Left"
        case .right: "Right"
        case .both: "Both"
        }
    }

    private func kLevelLabel(_ level: KLevel) -> String {
        switch level {
        case .k0: "K0 — not walking at present"
        case .k1: "K1 — walking on level ground at home"
        case .k2: "K2 — some kerbs, stairs or uneven ground"
        case .k3: "K3 — varied walking speeds, most surfaces"
        case .k4: "K4 — high activity, sport or work demands"
        }
    }

    // MARK: - Bindings

    private var levelBinding: Binding<AmputationLevel?> {
        Binding(
            get: { model.draft.amputationLevel },
            set: { if let value = $0 { model.select(level: value) } }
        )
    }

    private var sideBinding: Binding<AmputationSide?> {
        Binding(
            get: { model.draft.side },
            set: { if let value = $0 { model.select(side: value) } }
        )
    }

    private var yearsBinding: Binding<Int> {
        Binding(
            get: { (model.draft.timeSinceAmputationMonths ?? 0) / 12 },
            set: { model.setTimeSinceAmputation(months: $0 * 12 + (model.draft.timeSinceAmputationMonths ?? 0) % 12) }
        )
    }

    private var monthsBinding: Binding<Int> {
        Binding(
            get: { (model.draft.timeSinceAmputationMonths ?? 0) % 12 },
            set: { model.setTimeSinceAmputation(months: ((model.draft.timeSinceAmputationMonths ?? 0) / 12) * 12 + $0) }
        )
    }

    private var prosthesisBinding: Binding<String> {
        Binding(
            get: { model.draft.prosthesisType ?? "" },
            set: { model.setProsthesisType($0) }
        )
    }

    private var kLevelBinding: Binding<KLevel?> {
        Binding(
            get: { model.draft.kLevel },
            set: { model.setKLevel($0) }
        )
    }
}
