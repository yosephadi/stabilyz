import SwiftUI

/// The onboarding wizard (docs/04 §4.3, design-system.md §4-§5, and the screen
/// designs in docs/design/screens).
///
/// **The shell owns the chrome.** Back chip, Skip, progress and the primary
/// button belong to the container and are drawn once; a step case contributes
/// only its question, its "why we ask" line and its answer control. That is
/// what keeps six screens looking like one wizard — the alternative, each case
/// drawing its own header and button, is six chances for them to drift apart.
///
/// Everything under the chrome stays native per §5: `List` `.insetGrouped`
/// holding inline `Picker`s for the closed-choice fields, a system `Toggle`
/// wearing `CheckboxToggleStyle` for the disclaimer tick, and a `Button` in
/// `GlassCapsuleButtonStyle`. Dynamic Type, VoiceOver and the 44pt row height
/// come from the system rather than from us remembering.
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
            VStack(alignment: .leading, spacing: Space.x6) {
                header
                // The choice cards grow with Dynamic Type and K-level has six
                // rows, so the step scrolls rather than clipping (§9).
                ScrollView {
                    stepContent
                        .padding(.bottom, Space.x6)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            // §4: 24pt screen margins, applied once to the container so no
            // child restates them.
            .padding(.horizontal, Space.screenMargin)
            .padding(.top, Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StabilyzColor.bgBase)
            // Pins the primary button and keeps it clear of the home indicator
            // without the content having to know the inset.
            .safeAreaInset(edge: .bottom) { footer }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(StabilyzColor.primary600)
        .task { await model.start() }
    }

    // MARK: - Container chrome

    /// Back and Skip on one line, the progress indicator beneath them.
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            HStack {
                backChip
                Spacer()
                skipButton
            }

            // Shown on every screen including the disclaimer: [PRD §7 AC] asks
            // for a visible progress indicator throughout, where the designs
            // drop it on the final screen.
            StepProgressBar(step: model.progress.step, of: model.progress.of)
        }
    }

    /// The circular back control (§5: 50x50 adaptive glass). A plain `Button`
    /// underneath, so it keeps its tap handling and VoiceOver behaviour; the
    /// space is held on the first screen so the progress bar does not jump.
    private var backChip: some View {
        Button {
            // On the first screen there is no previous field; what is behind it
            // is Welcome [PRD §5].
            if model.canGoBack { model.back() } else { model.exitToWelcome() }
        } label: {
            Image(systemName: "chevron.left")
                .font(StabilyzFont.bodyBold)
                .foregroundStyle(StabilyzColor.ink900)
                .frame(
                    width: Controls.backButtonDiameter,
                    height: Controls.backButtonDiameter
                )
                .adaptiveGlass(.chrome, in: Circle())
        }
        .accessibilityLabel(model.canGoBack ? "Back" : "Back to Welcome")
    }

    /// Skip, on the two optional screens only.
    ///
    /// `model.canSkip` is the authority, not this view: which fields are
    /// optional is a [PRD §7 AC] rule, and a required screen that became
    /// skippable because a view forgot to hide a button is the failure worth
    /// preventing.
    @ViewBuilder
    private var skipButton: some View {
        if model.canSkip {
            Button("Skip") {
                Task { await model.skip() }
            }
            .font(StabilyzFont.bodyBold)
            .foregroundStyle(StabilyzColor.primary600)
            .frame(minHeight: Metrics.minimumTapTarget)
        }
    }

    /// The primary button, plus the copy that says why it is unavailable.
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

            Button(model.step == .disclaimer ? "Continue to Stabilyz" : "Next") {
                Task { await model.advance() }
            }
            .buttonStyle(.glassCapsuleHero)
            .disabled(!model.canContinue)
        }
        .padding(.horizontal, Space.screenMargin)
        .padding(.vertical, Space.x6)
        .background(StabilyzColor.bgBase)
    }

    // MARK: - Steps

    /// Each case supplies only its question, its helper line and its answer
    /// control. Nothing here draws chrome.
    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .amputationLevel:
            step(
                "What is your amputation level?",
                "This helps us understand your walking profile and present your results clearly."
            ) {
                ChoiceCard(
                    options: [
                        .init(.transtibial, "Below the knee"),
                        .init(.transfemoral, "Above the knee"),
                        .init(.bilateral, "Both legs")
                    ],
                    selection: levelBinding
                )
            }

        case .side:
            step("Which side?", sideSubtitle) {
                ChoiceCard(
                    options: model.allowedSides.map { .init($0, sideLabel($0)) },
                    selection: sideBinding
                )
            }

        case .timeSinceAmputation:
            step("How long has it been since your amputation?", "An estimate is fine.") {
                OnboardingCard {
                    CardRow {
                        Picker("Years", selection: yearsBinding) {
                            ForEach(0...60, id: \.self) { Text("\($0) years").tag($0) }
                        }
                    }
                    Divider().padding(.leading, Space.x4)
                    CardRow {
                        Picker("Months", selection: monthsBinding) {
                            ForEach(0...11, id: \.self) { Text("\($0) months").tag($0) }
                        }
                    }
                }
            }

        case .prosthesisType:
            step(
                "What type of prosthesis do you use?",
                "Optional. This helps you keep a useful record of your setup."
            ) {
                OnboardingCard {
                    CardRow {
                        TextField("Prosthesis or device", text: prosthesisBinding)
                            .textInputAutocapitalization(.words)
                    }
                }
            }

        case .kLevel:
            step(
                "Do you know your K-level?",
                "Optional. Your prosthetist may have discussed this with you."
            ) {
                ChoiceCard(
                    options: KLevel.allCases.map { .init($0, kLevelLabel($0)) }
                        + [.init(nil, "I don't know")],
                    selection: kLevelBinding
                )
            }

        case .disclaimer:
            // The disclaimer's own body is the content of the screen, so it
            // carries no helper line above the card.
            step(DisclaimerText.title, nil) {
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
                }
            }
        }
    }

    /// The shape every step has: a two-line question, an optional helper line,
    /// then the answer control.
    private func step<Content: View>(
        _ title: String,
        _ subtitle: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.x6) {
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

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Copy

    /// The designs only ever draw the unilateral side screen. Bilateral is a
    /// fully supported answer [PRD §7 AC] and no longer reaches this screen at
    /// all, but a draft saved on it before the level changed still can, so it
    /// keeps the line explaining why there is nothing to pick between.
    private var sideSubtitle: String {
        model.draft.amputationLevel == .bilateral
            ? """
              With a bilateral amputation there's no sound side to compare \
              against, so Stabilyz measures how steadily you walk overall and \
              never invents a comparison it can't make.
              """
            : "This helps us describe some walking patterns accurately when we can identify them."
    }

    private func sideLabel(_ side: AmputationSide) -> String {
        switch side {
        case .left: "Left"
        case .right: "Right"
        case .both: "Both"
        }
    }

    /// K1-K4 are worded as the designs word them. K0 is not on that screen —
    /// it is a real `KLevel` the domain supports, so it keeps a label rather
    /// than becoming unselectable on the strength of a mockup that omitted it.
    private func kLevelLabel(_ level: KLevel) -> String {
        switch level {
        case .k0: "K0 — not walking at present"
        case .k1: "K1 — household walking"
        case .k2: "K2 — limited community walking"
        case .k3: "K3 — community walking"
        case .k4: "K4 — high activity"
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
