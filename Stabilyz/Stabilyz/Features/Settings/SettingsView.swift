import SwiftUI
import UniformTypeIdentifiers

/// The You tab's content (docs/04 §4.15, Task 8.3.1 as repurposed in
/// decisions.md entry 42).
///
/// A native inset-grouped `List`, which design-system §5 reserves for exactly
/// this kind of full-screen settings surface. Every rule and string is
/// `SettingsViewModel`'s; the flows it opens are their own features.
struct SettingsView: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        List {
            Section {
                row(SettingsViewModel.clinicianSummaryLabel, systemImage: "stethoscope", disclosure: true) {
                    model.openClinicianSummary()
                }
            }

            Section(SettingsViewModel.backupSectionTitle) {
                row(SettingsViewModel.exportLabel, systemImage: "square.and.arrow.up") {
                    model.exportMyData()
                }
                row(SettingsViewModel.restoreLabel, systemImage: "square.and.arrow.down") {
                    model.restoreFromBackup()
                }
            }

            Section(SettingsViewModel.aboutSectionTitle) {
                LabeledContent(SettingsViewModel.appNameLabel, value: SettingsViewModel.appName)
                LabeledContent(SettingsViewModel.versionLabel, value: model.version)
                row(SettingsViewModel.disclaimerLabel, systemImage: "doc.text", disclosure: true) {
                    model.showDisclaimer()
                }
            }
            .font(StabilyzFont.bodyRegular)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(StabilyzColor.bgBase)
        .navigationDestination(isPresented: $model.isShowingDisclaimer) {
            DisclaimerReaderView()
        }
        .fileImporter(
            isPresented: $model.isPickingRestoreFile,
            // `.data` as well as the export's type — see `RestoreDataView`.
            allowedContentTypes: [ArchiveFormat.contentType, .data]
        ) { result in
            Task { await model.restoreFileImported(result) }
        }
        .sheet(item: Binding(
            get: { model.exportFlow },
            set: { if $0 == nil { model.exportClosed() } }
        )) { flow in
            ExportFlowView(model: flow)
        }
        .fullScreenCover(item: Binding(
            get: { model.restoreFlow },
            set: { if $0 == nil { model.restoreClosed() } }
        )) { flow in
            RestoreDataView(model: flow)
        }
        .task { await model.observeStoreReplacements() }
    }

    /// A tappable row: the icon in the brand colour, the label in `ink-900`,
    /// and a chevron where the row leads somewhere rather than starting a flow.
    private func row(
        _ title: String,
        systemImage: String,
        disclosure: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Space.x3) {
                Label {
                    Text(title)
                        .foregroundStyle(StabilyzColor.ink900)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(StabilyzColor.primary600)
                }
                .font(StabilyzFont.bodyRegular)

                Spacer(minLength: 0)

                if disclosure {
                    Image(systemName: "chevron.right")
                        .font(StabilyzFont.smallBold)
                        .foregroundStyle(StabilyzColor.ink400)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: Metrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The onboarding disclaimer, readable again after it was agreed to
/// [PRD §7 AC]. The same words, without the checkbox.
private struct DisclaimerReaderView: View {
    var body: some View {
        ScrollView {
            Text(SettingsViewModel.disclaimerBody)
                .font(StabilyzFont.bodyRegular)
                .foregroundStyle(StabilyzColor.ink900)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.screenMargin)
                .padding(.vertical, Space.x6)
        }
        .background(StabilyzColor.bgBase)
        .navigationTitle(SettingsViewModel.disclaimerLabel)
        .navigationBarTitleDisplayMode(.inline)
    }
}
