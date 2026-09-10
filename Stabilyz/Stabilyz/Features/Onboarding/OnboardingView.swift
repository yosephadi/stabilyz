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
/// The geometry is Figma node 40:835's, and design-system.md §5 tabulates it:
/// 40pt from the safe area to the back chip, 24 to the progress label, 12 to
/// the bar, 40 to the question, 16 to the "why we ask" line, 24 to the answer
/// card, and 70 under the button. The question column sits at the 24pt text
/// margin; the card breaks it and sits at 16.
///
/// Everything under the chrome stays native per §5: `OnboardingCard` built from
/// `VStack`/`Divider`/`Button`, a system `Toggle` wearing `CheckboxToggleStyle`
/// for the disclaimer tick, and a `Button` in `GlassCapsuleButtonStyle`.
/// Dynamic Type, VoiceOver and the 44pt tap floor come from the system rather
/// than from us remembering.
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
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, Space.screenMargin)
                // The choice cards grow with Dynamic Type and K-level has six
                // rows, so the step scrolls rather than clipping (§9).
                ScrollView {
                    stepContent
                        // The break between the wizard's chrome and its
                        // question (Figma: bar ends at y=218, question starts
                        // at y=258).
                        .padding(.top, Space.x10)
                        .padding(.bottom, Space.x6)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            // Puts the back chip at y=100 on a 402x874 frame, where Figma draws
            // it. Horizontal margins are *not* applied here: the question uses
            // the 24pt text margin and the answer card the wider 16pt card
            // margin, so each names its own rather than fighting a shared one.
            .padding(.top, Space.x10)
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

    /// Back and Skip on one line, the progress indicator 24pt beneath them.
    ///
    /// The bar is absent on the disclaimer, which is a consent gate rather than
    /// a numbered field — `model.progress` is `nil` there and the row of
    /// capsules is simply not drawn, exactly as the design draws it. The back
    /// chip stays, on that screen as on every other.
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            HStack {
                backChip
                Spacer()
                skipButton
            }

            if let progress = model.progress {
                StepProgressBar(step: progress.step, of: progress.of)
            }
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
        .padding(.top, Space.x6)
        // Figma anchors the button 70pt above the bottom safe-area edge, not
        // snug against it.
        .padding(.bottom, Controls.footerBottomGap)
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
            // One "why we ask" line [PRD §5], the one the design draws. The
            // bilateral variant that used to sit here explained why there was
            // nothing to choose between on a screen bilateral no longer
            // reaches; it was ours, not the design's, so it is gone.
            step(
                "Which side?",
                "This helps us describe some walking patterns accurately when we can identify them."
            ) {
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
                    Divider().padding(.horizontal, Space.x4)
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
            // carries no helper line and no card — copy and a checkbox sitting
            // directly on the page, in the text column.
            step(DisclaimerText.title, nil, contentMargin: Space.screenMargin) {
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

    /// The shape every step has: a question, an optional "why we ask" line
    /// [PRD §5], then the answer control 24pt below it.
    ///
    /// The question is 28pt Bold rather than the 34pt `heading`: Figma draws it
    /// at 28, and at 34 the two-line questions ("What type of prosthesis do you
    /// use?") ran to three lines and pushed the card off the screen.
    ///
    /// `contentMargin` is the one thing a step gets to choose. An answer card
    /// sits at the 16pt card margin so it breaks the text column; the
    /// disclaimer's body and checkbox are copy, not a card, so they stay in the
    /// column at 24pt.
    private func step<Content: View>(
        _ title: String,
        _ subtitle: String?,
        contentMargin: CGFloat = Space.cardMargin,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.x4) {
                Text(title)
                    .font(StabilyzFont.subheadingBold)
                    .foregroundStyle(StabilyzColor.onboardingTitle)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle)
                        .font(StabilyzFont.smallRegular)
                        .foregroundStyle(StabilyzColor.onboardingSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Space.screenMargin)
            .accessibilityElement(children: .combine)

            content()
                .padding(.top, Space.x6)
                .padding(.horizontal, contentMargin)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Copy

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
