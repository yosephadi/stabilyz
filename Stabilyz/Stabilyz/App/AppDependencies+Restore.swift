import Foundation

extension AppDependencies {
    /// Reads a picked export into a staged payload without touching the store
    /// (Task 10.3.1). Present in the degraded graph too: restoring an export is
    /// a way back from a store that will not open.
    var archiveInspector: ArchiveInspecting {
        ArchiveInspectionService(coder: secureArchive, fileIO: fileIO, logService: logService)
    }
}
