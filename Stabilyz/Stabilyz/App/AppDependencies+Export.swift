import Foundation

extension AppDependencies {
    /// The export pipeline over this graph's store and archive coder
    /// (Task 10.2.2). Built per export: nothing about it outlives one.
    var archiveExporter: ArchiveExporting {
        ArchiveExportService(
            profiles: userProfileRepository,
            sessions: gaitSessionRepository,
            baselines: baselineRepository,
            coder: secureArchive,
            fileIO: fileIO,
            clock: clock,
            buildInfo: SystemBuildInfo(),
            logService: logService
        )
    }

    /// Export My Data, ready to present — for the Settings entry point on the
    /// You tab, when it lands.
    @MainActor
    func makeExportFlow(onClose: @escaping @MainActor () -> Void) -> ExportFlowModel {
        ExportFlowModel(
            exporter: archiveExporter,
            keyDerivation: keyDerivation,
            logService: logService,
            onClose: onClose,
            onExported: { [exportNudgeStore] in exportNudgeStore.recordExport() }
        )
    }
}
