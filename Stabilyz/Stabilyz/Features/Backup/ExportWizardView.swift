import SwiftUI

/// Export My Data: set a passphrase, then acknowledge it cannot be recovered
/// (docs/04 §4.16, docs/13 §13.2–13.3, Task 10.2.1).
///
/// Presented as a sheet (docs/11 §11.2) in its own navigation stack, from
/// Settings once the You tab exists. Built from design-system tokens and the
/// existing card, checkbox and capsule components; there is no Figma frame for
/// it. Every rule and string is `ExportWizardViewModel`'s.
struct ExportWizardView: View {
    @State private var model: ExportWizardViewModel
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case passphrase
        case confirmation
    }

    init(model: ExportWizardViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.x6) {
                        switch model.step {
                        case .passphrase:
                            passphraseStep
                        case .warning, .preparing, .handedOff:
                            warningStep
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.screenMargin)
                    .padding(.top, Space.x6)
                    .padding(.bottom, Space.x4)
                }

                footer
                    .padding(.horizontal, Space.screenMargin)
                    .padding(.top, Space.x4)
                    .padding(.bottom, Space.x6)
            }
            .background(StabilyzColor.bgBase)
            .navigationTitle(ExportWizardViewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ExportWizardViewModel.cancelLabel) { model.cancel() }
                        .disabled(model.step == .preparing)
                }
            }
        }
        // A swipe must not quietly throw away a passphrase someone is halfway
        // through choosing; Cancel is the way out once anything is typed.
        .interactiveDismissDisabled(!model.passphrase.isEmpty || model.step != .passphrase)
        // However the sheet goes, what was typed goes with it.
        .onDisappear { model.discardSecrets() }
    }

    // MARK: - Step 1

    private var passphraseStep: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            heading(ExportWizardViewModel.passphraseTitle, body: ExportWizardViewModel.passphraseBody)

            VStack(alignment: .leading, spacing: Space.x3) {
                OnboardingCard {
                    field(ExportWizardViewModel.passphraseLabel, text: $model.passphrase, as: .passphrase)
                    Divider().padding(.horizontal, Space.x4)
                    field(ExportWizardViewModel.confirmationLabel, text: $model.confirmation, as: .confirmation)
                }

                visibilityToggle

                message(model.passphraseMessage, isProblem: model.passphraseMessageIsProblem)
                if let mismatch = model.confirmationMessage {
                    message(mismatch, isProblem: true)
                }
            }
        }
        .onAppear { focus = .passphrase }
    }

    /// A secure field, or a plain one while the passphrase is shown.
    ///
    /// The plain field turns off autocapitalization and autocorrection: a
    /// keyboard that "fixed" a visible passphrase would change the key without
    /// the person noticing, and the backup would not open.
    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, as which: Field) -> some View {
        Group {
            if model.isPassphraseVisible {
                TextField(label, text: text)
            } else {
                SecureField(label, text: text)
            }
        }
        .font(StabilyzFont.bodyRegular)
        .foregroundStyle(StabilyzColor.ink900)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .privacySensitive()
        .focused($focus, equals: which)
        .accessibilityIdentifier(which == .passphrase ? "export.passphrase" : "export.confirmation")
        .submitLabel(which == .passphrase ? .next : .done)
        .onSubmit {
            switch which {
            case .passphrase:
                focus = .confirmation
            case .confirmation:
                focus = nil
                model.continueToWarning()
            }
        }
        .padding(.horizontal, Space.x4)
        .frame(maxWidth: .infinity, minHeight: Controls.rowHeight, alignment: .leading)
        .accessibilityLabel(label)
    }

    private var visibilityToggle: some View {
        Button {
            model.isPassphraseVisible.toggle()
        } label: {
            Label(
                model.isPassphraseVisible
                    ? ExportWizardViewModel.hidePassphraseLabel
                    : ExportWizardViewModel.showPassphraseLabel,
                systemImage: model.isPassphraseVisible ? "eye.slash" : "eye"
            )
            .font(StabilyzFont.smallBold)
            .foregroundStyle(StabilyzColor.primary600)
            .frame(minHeight: Metrics.minimumTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The glyph, not the colour, marks a problem (§9); amber is the palette's
    /// non-blocking alert colour, and red is reserved for destructive actions
    /// (§2.3).
    private func message(_ text: String, isProblem: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
            if isProblem {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(StabilyzColor.warning)
                    .accessibilityHidden(true)
            }
            Text(text)
                .foregroundStyle(isProblem ? StabilyzColor.ink900 : StabilyzColor.ink600)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(StabilyzFont.smallRegular)
    }

    // MARK: - Step 2

    private var warningStep: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            heading(ExportWizardViewModel.warningTitle, body: nil)

            HStack(alignment: .firstTextBaseline, spacing: Space.x3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(StabilyzFont.bodyBold)
                    .foregroundStyle(StabilyzColor.warning)
                    .accessibilityHidden(true)
                Text(ExportWizardViewModel.warningMessage)
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink900)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StabilyzColor.bgElevated, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder(StabilyzColor.warning, lineWidth: Metrics.hairline)
            }
            .accessibilityElement(children: .combine)

            Toggle(ExportWizardViewModel.acknowledgementLabel, isOn: $model.hasAcknowledgedWarning)
                .toggleStyle(.checkbox)
                .disabled(model.step != .warning)
                .accessibilityIdentifier("export.acknowledge")
        }
    }

    // MARK: - Shared

    private func heading(_ title: String, body: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(title)
                .font(StabilyzFont.subheadingBold)
                .foregroundStyle(StabilyzColor.ink900)
                .accessibilityAddTraits(.isHeader)
            if let body {
                Text(body)
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink600)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var footer: some View {
        switch model.step {
        case .passphrase:
            // Enabled on purpose: a disabled button cannot say why. Tapping it
            // with a short passphrase is what turns the rule into a message.
            Button(ExportWizardViewModel.continueLabel) {
                focus = nil
                model.continueToWarning()
            }
            .buttonStyle(.primaryCapsuleHero)
            .accessibilityIdentifier("export.continue")

        case .warning, .preparing, .handedOff:
            VStack(spacing: Space.x3) {
                Button {
                    Task { await model.createBackup() }
                } label: {
                    if model.step == .preparing {
                        HStack(spacing: Space.x2) {
                            ProgressView()
                            Text(ExportWizardViewModel.preparingLabel)
                        }
                    } else {
                        Text(ExportWizardViewModel.createBackupLabel)
                    }
                }
                .buttonStyle(.primaryCapsuleHero)
                .disabled(!model.canCreateBackup)
                .accessibilityIdentifier("export.create")

                Button(ExportWizardViewModel.backLabel) { model.backToPassphrase() }
                    .buttonStyle(.secondaryCapsuleHero)
                    .disabled(model.step != .warning)
            }
        }
    }
}

#Preview {
    ExportWizardView(model: ExportWizardViewModel(keyDerivation: CommonCryptoKeyDerivation()))
}
