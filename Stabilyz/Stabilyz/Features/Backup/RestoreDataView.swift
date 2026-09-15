import SwiftUI
import UniformTypeIdentifiers

/// Restore your data (Figma 64:3890; problem states 94:579, 94:665, 94:722;
/// Task 10.3.2).
///
/// Presented full screen over Welcome once a file has been picked. The
/// problem's title sits between the prompt and the field and its explanation
/// takes the helper line's place beneath it, as the problem frames draw them.
/// Every rule and string is `RestoreDataViewModel`'s.
struct RestoreDataView: View {
    @State private var model: RestoreDataViewModel
    @FocusState private var isPassphraseFocused: Bool

    init(model: RestoreDataViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backChip
                .padding(.horizontal, Space.screenMargin)

            ScrollView {
                content
                    // Figma: chip ends at y=150, title starts at y=182.
                    .padding(.top, Space.x8)
                    .padding(.bottom, Space.x6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        // The back chip at y=100, where the onboarding chip sits.
        .padding(.top, Space.x10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StabilyzColor.bgBase)
        .safeAreaInset(edge: .bottom) { footer }
        .tint(StabilyzColor.primary600)
        .fileImporter(
            isPresented: $model.isPickerPresented,
            // `.data` as well as the export's own type: until the type is
            // declared in the app's Info, iOS does not associate `.stabilyz`
            // with it, and a picker offering nothing would be a dead end.
            allowedContentTypes: [ArchiveFormat.contentType, .data]
        ) { result in
            Task { await model.fileImported(result) }
        }
        .onDisappear { model.discardSecrets() }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            VStack(alignment: .leading, spacing: Space.x4) {
                Text(RestoreDataViewModel.title)
                    .font(StabilyzFont.subheadingBold)
                    .foregroundStyle(StabilyzColor.onboardingTitle)
                    .accessibilityAddTraits(.isHeader)

                if let file = model.file {
                    fileRow(file)
                }

                VStack(alignment: .leading, spacing: Space.x3) {
                    Text(RestoreDataViewModel.prompt)
                        .font(StabilyzFont.bodyRegular)
                        .foregroundStyle(StabilyzColor.onboardingSubtitle)

                    if let problem = model.problem {
                        Text(problem.title)
                            .font(StabilyzFont.smallRegular)
                            .foregroundStyle(StabilyzColor.restoreProblem)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.screenMargin)

            OnboardingCard {
                passphraseField
            }
            .padding(.horizontal, Space.cardMargin)

            Text(model.problem?.body ?? RestoreDataViewModel.helper)
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.restoreHelper)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.screenMargin)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: Motion.buttonPress), value: model.problem)
    }

    private func fileRow(_ file: RestoreDataViewModel.PickedFile) -> some View {
        HStack(spacing: Space.x4) {
            RoundedRectangle(cornerRadius: Radius.thumbnail)
                .fill(StabilyzColor.fileThumbnail)
                .frame(width: Controls.fileThumbnailWidth, height: Controls.fileThumbnailHeight)
                .overlay {
                    if model.phase == .checkingFile {
                        ProgressView()
                    }
                }
                .accessibilityHidden(true)

            Text(file.displayName)
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.onboardingTitle)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    /// Secure, with autocapitalization and autocorrection off: a keyboard that
    /// "fixed" a passphrase would change the key without the person noticing.
    private var passphraseField: some View {
        SecureField(RestoreDataViewModel.passphraseLabel, text: $model.passphrase)
            .font(StabilyzFont.bodyRegular)
            .foregroundStyle(StabilyzColor.ink900)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .privacySensitive()
            .focused($isPassphraseFocused)
            .submitLabel(.go)
            .onSubmit { restore() }
            .disabled(model.isWorking || model.phase == .restored)
            .padding(.horizontal, Space.x4)
            .frame(maxWidth: .infinity, minHeight: Controls.rowHeight, alignment: .leading)
            .accessibilityLabel(RestoreDataViewModel.passphraseLabel)
    }

    // MARK: - Chrome

    /// The circular back control, drawn as onboarding draws it (§5).
    private var backChip: some View {
        Button {
            model.close()
        } label: {
            Image(systemName: "chevron.left")
                .font(StabilyzFont.buttonLabel)
                .foregroundStyle(StabilyzColor.ink900)
                .frame(width: Controls.backButtonDiameter, height: Controls.backButtonDiameter)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.phase == .restoring)
        .accessibilityLabel(RestoreDataViewModel.backLabel)
    }

    private var footer: some View {
        VStack(spacing: Space.x4) {
            Button {
                restore()
            } label: {
                if model.phase == .restoring {
                    HStack(spacing: Space.x2) {
                        ProgressView()
                        Text(RestoreDataViewModel.restoringLabel)
                    }
                } else {
                    Text(RestoreDataViewModel.restoreLabel)
                }
            }
            .buttonStyle(.primaryCapsuleHero)
            .disabled(!model.canRestore)

            Button(RestoreDataViewModel.chooseDifferentFileLabel) {
                isPassphraseFocused = false
                model.chooseDifferentFile()
            }
            .buttonStyle(.secondaryCapsuleHero)
            .disabled(!model.canChooseDifferentFile)
        }
        .padding(.horizontal, Space.screenMargin)
        .padding(.top, Space.x6)
        .padding(.bottom, Controls.footerBottomGap)
        .background(StabilyzColor.bgBase)
    }

    private func restore() {
        isPassphraseFocused = false
        Task { await model.restore() }
    }
}
