import Foundation

/// Export My Data from passphrase to share sheet (docs/04 §4.16, docs/13
/// §13.2, Task 10.2.2).
///
/// docs/04's state machine, `passphraseEntry → confirming → warningAck →
/// generating → sharing → done | failed(clean)`: the first three are the
/// wizard's (Task 10.2.1), and this model owns the rest.
///
/// **The temporary file never outlives the flow.** It is deleted when the share
/// sheet reports how it ended — shared, cancelled, or failed — and when the
/// flow is closed with the sheet still up. A file an interrupted flow left
/// behind is swept the next time an export starts. `failed(clean)` is literal:
/// by the time a failure is shown, nothing is left on disk.
@MainActor
@Observable
final class ExportFlowModel {
    enum Phase: Equatable {
        /// The wizard: passphrase, confirmation, warning.
        case entering
        case generating
        case sharing(PreparedExport)
        case finished(Outcome)
        case failed(ErrorPresentation)
    }

    enum Outcome: Equatable {
        /// An activity in the share sheet completed.
        case shared
        /// The share sheet was dismissed without one.
        case notShared
    }

    private(set) var phase: Phase = .entering
    private(set) var wizard: ExportWizardViewModel

    /// Bumped to ask for the share sheet again — if it could not be presented
    /// the first time, the person is not left stranded with a file they cannot
    /// reach.
    private(set) var shareAttempt = 0

    /// The running generation, held so tests can await it.
    private(set) var generationTask: Task<Void, Never>?
    /// The deletion a close started, held for the same reason.
    private(set) var cleanupTask: Task<Void, Never>?

    var onClose: @MainActor () -> Void

    private let exporter: ArchiveExporting
    private let keyDerivation: KeyDerivation
    private let logService: LogService
    private var isClosed = false

    init(
        exporter: ArchiveExporting,
        keyDerivation: KeyDerivation,
        logService: LogService,
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        self.exporter = exporter
        self.keyDerivation = keyDerivation
        self.logService = logService
        self.onClose = onClose
        self.wizard = ExportWizardViewModel(keyDerivation: keyDerivation)
        wire(wizard)
    }

    private func wire(_ wizard: ExportWizardViewModel) {
        wizard.onCreate = { [weak self] request in
            guard let self else { return }
            self.generationTask = Task { await self.generate(request) }
        }
        wizard.onCancel = { [weak self] in
            self?.close()
        }
    }

    /// Sweeps exports an interrupted flow left behind.
    func start() async {
        await exporter.discardStaleExports()
    }

    // MARK: - Generating

    func generate(_ request: ExportRequest) async {
        guard phase == .entering, !isClosed else { return }
        phase = .generating

        do {
            let prepared = try await exporter.prepare(request)
            // Closed while the file was being written: it has nowhere to go.
            guard !isClosed, phase == .generating else {
                await exporter.discard(prepared)
                return
            }
            phase = .sharing(prepared)
        } catch {
            guard !isClosed else { return }
            let failure = (error as? StabilyzError) ?? .export(.archiveGenerationFailed)
            logService.log(.error, .backup, "export flow failed: \(failure.technicalDescription)")
            phase = .failed(Self.presentation(for: failure))
        }
    }

    // MARK: - Sharing

    func showShareOptions() {
        guard case .sharing = phase else { return }
        shareAttempt += 1
    }

    /// How the share sheet ended. The file is deleted whatever the answer.
    ///
    /// Leaves `sharing` before deleting, so a second report of the same
    /// ending cannot delete twice or overwrite the first.
    ///
    /// - Parameter failed: the share sheet reported an error. Its detail is
    ///   not carried: nothing about it would change what the person is told.
    func shareFinished(completed: Bool, failed: Bool) async {
        guard case .sharing(let prepared) = phase else { return }

        if failed {
            phase = .failed(Self.presentation(for: .export(.shareFailed)))
        } else {
            phase = .finished(completed ? .shared : .notShared)
        }
        await exporter.discard(prepared)
        logService.log(.info, .backup, "export share ended: completed=\(completed) failed=\(failed)")
    }

    // MARK: - Leaving

    /// Closes the flow from any phase, deleting a file still waiting to be
    /// shared and clearing anything typed.
    func close() {
        guard !isClosed else { return }
        isClosed = true

        if case .sharing(let prepared) = phase {
            let exporter = self.exporter
            cleanupTask = Task { await exporter.discard(prepared) }
        }
        wizard.discardSecrets()
        onClose()
    }

    /// Back to an empty wizard after a failure or an unshared backup. The
    /// passphrase was cleared on hand-off, so it is entered again.
    func startOver() {
        switch phase {
        case .failed, .finished(.notShared):
            wizard = ExportWizardViewModel(keyDerivation: keyDerivation)
            wire(wizard)
            generationTask = nil
            phase = .entering
        case .entering, .generating, .sharing, .finished(.shared):
            return
        }
    }

    private static func presentation(for error: StabilyzError) -> ErrorPresentation {
        ErrorPresenter.presentation(for: error)
            ?? ErrorPresentation(message: fallbackFailureMessage, isRecoverable: true, reassuresDataUnchanged: true)
    }

    // MARK: - Copy

    static let generatingTitle = "Creating Your Backup"
    static let generatingBody = "Encrypting your data. This takes a moment."

    static let sharingTitle = "Choose Where to Save It"
    static let sharingBody =
        "Save it to Files, send it with AirDrop, or keep it anywhere you trust. The copy on this iPhone is removed when you're done."
    static let showShareOptionsLabel = "Show Share Options"

    static let sharedTitle = "Backup Created"
    static let sharedBody = "Keep your passphrase somewhere safe. Without it, this backup can't be opened."

    static let notSharedTitle = "Backup Not Saved"
    static let notSharedBody = "Nothing was shared, and the backup has been removed from this iPhone."

    static let failedTitle = "Backup Not Created"
    static let fallbackFailureMessage = "Export didn't complete — nothing was changed."

    static let doneLabel = "Done"
    static let tryAgainLabel = "Try Again"
    static let closeLabel = "Close"
}
