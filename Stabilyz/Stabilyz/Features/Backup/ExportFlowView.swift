import SwiftUI

/// Export My Data, end to end (docs/04 §4.16, Task 10.2.2): the passphrase
/// wizard, then generation, the share sheet, and how it ended.
///
/// Presented as a sheet (docs/11 §11.2) from Settings once the You tab exists.
/// Built from design-system tokens; every rule and string is
/// `ExportFlowModel`'s.
struct ExportFlowView: View {
    @State private var model: ExportFlowModel

    init(model: ExportFlowModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            switch model.phase {
            case .entering:
                ExportWizardView(model: model.wizard)
                    // A fresh wizard after Try Again is a fresh screen.
                    .id(ObjectIdentifier(model.wizard))

            case .generating:
                status(
                    title: ExportFlowModel.generatingTitle,
                    body: ExportFlowModel.generatingBody,
                    mark: .progress
                )

            case .sharing(let export):
                status(
                    title: ExportFlowModel.sharingTitle,
                    body: ExportFlowModel.sharingBody,
                    mark: .glyph("square.and.arrow.up", StabilyzColor.primary600),
                    primary: (ExportFlowModel.showShareOptionsLabel, { model.showShareOptions() }),
                    secondary: (ExportFlowModel.closeLabel, { model.close() })
                )
                .background(
                    SharePresenter(export: export, attempt: model.shareAttempt) { completed, failed in
                        Task { await model.shareFinished(completed: completed, failed: failed) }
                    }
                )

            case .finished(.shared):
                status(
                    title: ExportFlowModel.sharedTitle,
                    body: ExportFlowModel.sharedBody,
                    mark: .glyph("checkmark.circle", StabilyzColor.primary600),
                    primary: (ExportFlowModel.doneLabel, { model.close() })
                )

            case .finished(.notShared):
                status(
                    title: ExportFlowModel.notSharedTitle,
                    body: ExportFlowModel.notSharedBody,
                    mark: .glyph("xmark.circle", StabilyzColor.ink400),
                    primary: (ExportFlowModel.tryAgainLabel, { model.startOver() }),
                    secondary: (ExportFlowModel.closeLabel, { model.close() })
                )

            case .failed(let presentation):
                if presentation.isRecoverable {
                    status(
                        title: ExportFlowModel.failedTitle,
                        body: presentation.message,
                        mark: .glyph("exclamationmark.circle", StabilyzColor.warning),
                        primary: (ExportFlowModel.tryAgainLabel, { model.startOver() }),
                        secondary: (ExportFlowModel.closeLabel, { model.close() })
                    )
                } else {
                    status(
                        title: ExportFlowModel.failedTitle,
                        body: presentation.message,
                        mark: .glyph("exclamationmark.circle", StabilyzColor.warning),
                        primary: (ExportFlowModel.closeLabel, { model.close() })
                    )
                }
            }
        }
        .task { await model.start() }
    }

    // MARK: - Status screens

    private enum Mark {
        case progress
        case glyph(String, Color)
    }

    /// One mark, a title, a sentence, and at most two actions — the same shape
    /// as History's empty state, so a screen with nothing to do but wait or
    /// decide still reads as a place in the app.
    private func status(
        title: String,
        body: String,
        mark: Mark,
        primary: (String, () -> Void)? = nil,
        secondary: (String, () -> Void)? = nil
    ) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: Space.x4) {
                        switch mark {
                        case .progress:
                            ProgressView()
                                .controlSize(.large)
                                .tint(StabilyzColor.primary600)
                                .padding(.vertical, Space.x8)
                        case .glyph(let name, let color):
                            Image(systemName: name)
                                .font(StabilyzFont.completionGlyph)
                                .foregroundStyle(color)
                                .accessibilityHidden(true)
                        }

                        Text(title)
                            .font(StabilyzFont.subheadingBold)
                            .foregroundStyle(StabilyzColor.ink900)
                            .accessibilityAddTraits(.isHeader)

                        Text(body)
                            .font(StabilyzFont.bodyRegular)
                            .foregroundStyle(StabilyzColor.ink600)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Space.screenMargin)
                    .padding(.top, Space.x10)
                }

                if primary != nil || secondary != nil {
                    VStack(spacing: Space.x3) {
                        if let primary {
                            Button(primary.0, action: primary.1)
                                .buttonStyle(.primaryCapsuleHero)
                        }
                        if let secondary {
                            Button(secondary.0, action: secondary.1)
                                .buttonStyle(.secondaryCapsuleHero)
                        }
                    }
                    .padding(.horizontal, Space.screenMargin)
                    .padding(.top, Space.x4)
                    .padding(.bottom, Space.x6)
                }
            }
            .background(StabilyzColor.bgBase)
            .navigationTitle(ExportWizardViewModel.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        // Nothing half-done may be swiped away: generation cannot be
        // abandoned mid-write, and a waiting file is deleted by Close.
        .interactiveDismissDisabled()
    }
}
