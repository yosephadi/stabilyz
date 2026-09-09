import SwiftUI

/// The onboarding wizard (docs/04 §4.3, design-system.md §5).
///
/// Native components only: `NavigationStack` with large titles, `List`
/// `.insetGrouped` holding inline `Picker`s, a system `Toggle` for the
/// disclaimer tick, and a `.borderedProminent` primary button tinted
/// `primary-600`. Nothing here is custom-drawn, so Dynamic Type, VoiceOver and
/// the 44pt row height come from the system rather than from us remembering.
struct OnboardingView: View {
    @State private var model: OnboardingViewModel

    init(model: OnboardingViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepContent
                footer
            }
            .background(StabilyzColor.bgBase)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if model.canGoBack {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { model.back() }
                            .tint(StabilyzColor.primary600)
                    }
                }
            }
        }
        .task { await model.start() }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .amputationLevel:
            List {
                Section {
                    Picker("Amputation level", selection: levelBinding) {
                        Text("Below the knee (transtibial)").tag(AmputationLevel.transtibial as AmputationLevel?)
                        Text("Above the knee (transfemoral)").tag(AmputationLevel.transfemoral as AmputationLevel?)
                        Text("Both legs (bilateral)").tag(AmputationLevel.bilateral as AmputationLevel?)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    // "Why we ask" [PRD §7 AC].
                    Text("""
                        Why we ask: this tells Stabilyz which measurements make \
                        sense for you. Everyone gets the same core walking \
                        measurements — this only decides whether one extra \
                        comparison between your two legs is possible.
                        """)
                }
            }

        case .side:
            List {
                Section {
                    Picker("Side", selection: sideBinding) {
                        ForEach(model.allowedSides, id: \.self) { side in
                            Text(sideLabel(side)).tag(side as AmputationSide?)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text(sideFooter)
                }
            }

        case .timeSinceAmputation:
            List {
                Section {
                    Picker("Years", selection: yearsBinding) {
                        ForEach(0...60, id: \.self) { Text("\($0) years").tag($0) }
                    }
                    Picker("Months", selection: monthsBinding) {
                        ForEach(0...11, id: \.self) { Text("\($0) months").tag($0) }
                    }
                } footer: {
                    Text("An approximate answer is fine — this is context for your results, not a measurement.")
                }
            }

        case .prosthesisType:
            List {
                Section {
                    TextField("Prosthesis or device", text: prosthesisBinding)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Optional. You can leave this blank and carry on.")
                }
            }

        case .kLevel:
            List {
                Section {
                    Picker("Activity level", selection: kLevelBinding) {
                        Text("Prefer not to say").tag(KLevel?.none)
                        ForEach(KLevel.allCases, id: \.self) { level in
                            Text(kLevelLabel(level)).tag(level as KLevel?)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text("Optional. If your prosthetist has given you a K-level, it goes here.")
                }
            }

        case .disclaimer:
            List {
                Section {
                    Text(DisclaimerText.body)
                        .font(StabilyzFont.bodyRegular)
                        .foregroundStyle(StabilyzColor.ink900)
                }
                Section {
                    Toggle(DisclaimerText.acknowledgement, isOn: $model.disclaimerAccepted)
                        .tint(StabilyzColor.primary600)
                        .font(StabilyzFont.bodyRegular)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Space.x3) {
            // The progress indicator [PRD §7 AC], stated in words as well as a
            // bar so it survives VoiceOver and a very large type setting.
            ProgressView(value: model.progressFraction) {
                Text("Step \(model.progress.step) of \(model.progress.of)")
                    .font(StabilyzFont.smallRegular)
                    .foregroundStyle(StabilyzColor.ink600)
            }
            .tint(StabilyzColor.primary600)

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
            .controlSize(.large)
            .tint(StabilyzColor.primary600)
            .frame(maxWidth: .infinity, minHeight: Metrics.minimumTapTarget)
            .disabled(!model.canContinue)
        }
        .padding(.horizontal, Space.screenMargin)
        .padding(.vertical, Space.x6)
        .background(StabilyzColor.bgElevated)
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

    private var sideFooter: String {
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
