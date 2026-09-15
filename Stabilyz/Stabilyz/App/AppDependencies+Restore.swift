import Foundation

extension AppDependencies {
    /// Reads a picked export into a staged payload without touching the store
    /// (Task 10.3.1). Present in the degraded graph too: restoring an export is
    /// a way back from a store that will not open.
    var archiveInspector: ArchiveInspecting {
        ArchiveInspectionService(coder: secureArchive, fileIO: fileIO, logService: logService)
    }

    /// Whether a restore would overwrite anything (Task 10.3.3).
    var localDataDetector: LocalDataDetecting {
        RepositoryLocalDataDetector(
            profiles: userProfileRepository,
            sessions: gaitSessionRepository,
            baselines: baselineRepository
        )
    }

    /// Restore your data, ready to present (Tasks 10.3.2–10.3.3). `onFinished` runs
    /// when the screen closes or the restore succeeds; the app root moves on
    /// by itself, from the store-replacement broadcast.
    @MainActor
    func makeRestoreFlow(onFinished: @escaping @MainActor () -> Void) -> RestoreDataViewModel {
        RestoreDataViewModel(
            inspector: archiveInspector,
            restorer: archiveRestorer,
            localData: localDataDetector,
            makeExportFlow: { onClose in makeExportFlow(onClose: onClose) },
            fileAccess: SystemSecurityScopedAccess(),
            logService: logService,
            onRestored: { _ in onFinished() },
            onClose: onFinished
        )
    }
}
