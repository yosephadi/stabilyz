import Foundation

/// Where a restore leaves its safety net while it runs (docs/13 §13.5 steps 2
/// and 4, Task 10.3.5).
protocol RestoreStaging: Sendable {
    /// Writes the pre-restore snapshot, then the in-progress marker. Both are
    /// on disk before this returns.
    ///
    /// - Returns: false when a marker is already there — an earlier restore
    ///   whose store could not be put back. Its snapshot is the only record of
    ///   the store as it was, so it is kept rather than overwritten with
    ///   whatever the store holds now.
    func stage(_ snapshot: StoreContents) throws -> Bool

    /// Removes the marker, then the snapshot.
    func clear() throws
}

/// The staging directory: a snapshot file and a marker file.
///
/// **Order is the contract.** The snapshot is written before the marker and
/// removed after it, so a marker on disk always means a complete snapshot
/// beside it. A snapshot with no marker means staging died before the store
/// was touched, and is simply deleted.
///
/// Both files are written atomically under complete data protection (docs/18):
/// the snapshot holds the whole store.
struct RestoreStagingArea: RestoreStaging {
    static let markerName = "restore-in-progress.json"
    static let snapshotName = "restore-snapshot.json"

    /// Under Application Support, beside the store (docs/06 §6.1). Not the
    /// temporary directory: iOS may empty that between launches, which is
    /// exactly when the snapshot is needed.
    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "RestoreStaging", directoryHint: .isDirectory)
    }

    let directory: URL
    private let fileIO: FileIO
    private let clock: Clock

    init(directory: URL = Self.defaultDirectory, fileIO: FileIO, clock: Clock) {
        self.directory = directory
        self.fileIO = fileIO
        self.clock = clock
    }

    var markerURL: URL { directory.appending(path: Self.markerName) }
    var snapshotURL: URL { directory.appending(path: Self.snapshotName) }

    var hasMarker: Bool { fileIO.fileExists(at: markerURL) }
    var hasSnapshot: Bool { fileIO.fileExists(at: snapshotURL) }

    func stage(_ snapshot: StoreContents) throws -> Bool {
        guard !hasMarker else { return false }

        let snapshotData = try StoreSnapshotCoding.encode(snapshot, createdAt: clock.now)
        let markerData = try JSONEncoder().encode(Marker(formatVersion: StoreSnapshotCoding.formatVersion, stagedAt: clock.now))
        do {
            try fileIO.createDirectory(at: directory)
            try fileIO.writeProtected(snapshotData, to: snapshotURL)
            try fileIO.writeProtected(markerData, to: markerURL)
        } catch {
            // No marker, so nothing half-staged may be read as a safety net.
            try? clear()
            throw error
        }
        return true
    }

    func clear() throws {
        if hasMarker { try fileIO.remove(at: markerURL) }
        if hasSnapshot { try fileIO.remove(at: snapshotURL) }
    }

    func readSnapshot() throws -> Data {
        try fileIO.read(from: snapshotURL)
    }

    /// Diagnostics only: recovery reads the marker's presence, not its content.
    private struct Marker: Codable {
        let formatVersion: Int
        let stagedAt: Date
    }
}

// MARK: - Launch recovery

/// What launch recovery found and did.
enum RestoreRecoveryOutcome: Sendable, Equatable {
    /// No restore was interrupted.
    case nothingToRecover
    /// A restore was interrupted; the store is back to its snapshot.
    case recovered(sessionCount: Int)
    /// A snapshot without a marker: staging stopped before the store was
    /// touched. Deleted.
    case discardedStaleSnapshot
    /// The marker was there but the snapshot was damaged or missing. Both are
    /// deleted: there is nothing to put back, and the store — which only
    /// ever changes in single transactions — is left as it is.
    case snapshotUnusable
    /// The snapshot could not be read (a locked device, say). Everything is
    /// kept for the next attempt.
    case snapshotUnreadable
    /// The snapshot could not be written back. Everything is kept for the next
    /// attempt.
    case recoveryFailed
}

/// Runs before anything reads the store at launch (docs/13 §13.5 step 4).
protocol RestoreRecovering: Sendable {
    func recoverInterruptedRestore() async -> RestoreRecoveryOutcome
}

/// Production `RestoreRecovering`.
///
/// A marker at launch means the process ended between staging and the
/// restore's verified end — killed mid-write, or with a store that could not
/// be put back. Either way the store is returned to the snapshot and verified,
/// and only then is the staging removed. Nothing here throws: whatever
/// happens, launch goes on, and the outcome says what happened.
struct RestoreRecoveryService: RestoreRecovering {
    private let staging: RestoreStagingArea
    private let replacer: StoreReplacing
    private let logService: LogService
    private let rebuildBaselineStates: (@Sendable () async throws -> Void)?

    init(
        staging: RestoreStagingArea,
        replacer: StoreReplacing,
        logService: LogService,
        rebuildBaselineStates: (@Sendable () async throws -> Void)? = nil
    ) {
        self.staging = staging
        self.replacer = replacer
        self.logService = logService
        self.rebuildBaselineStates = rebuildBaselineStates
    }

    func recoverInterruptedRestore() async -> RestoreRecoveryOutcome {
        guard staging.hasMarker else {
            guard staging.hasSnapshot else { return .nothingToRecover }
            discardStaging()
            logService.log(.info, .backup, "discarded a restore snapshot that was never marked in progress")
            return .discardedStaleSnapshot
        }

        logService.log(.warning, .backup, "a restore was interrupted; recovering the pre-restore store")

        guard staging.hasSnapshot else {
            discardStaging()
            logService.log(.error, .backup, "restore recovery: marker without a snapshot; store left as it is")
            return .snapshotUnusable
        }

        let data: Data
        do {
            data = try staging.readSnapshot()
        } catch {
            logService.log(.error, .backup, "restore recovery: snapshot unreadable, kept for the next launch: \(type(of: error))")
            return .snapshotUnreadable
        }

        let snapshot: StoreContents
        do {
            snapshot = try StoreSnapshotCoding.decode(data)
        } catch {
            discardStaging()
            logService.log(.error, .backup, "restore recovery: snapshot damaged (\(error)); store left as it is")
            return .snapshotUnusable
        }

        do {
            // Killed before the write, or the write rolled back: already right.
            if try await replacer.contents() != snapshot {
                try await replacer.replaceAll(with: snapshot)
                guard try await replacer.contents() == snapshot else {
                    throw StabilyzError.archiveImport(.restoreIncomplete)
                }
            }
        } catch {
            logService.log(.error, .backup, "restore recovery failed, kept for the next launch: \(type(of: error))")
            return .recoveryFailed
        }

        do {
            try await rebuildBaselineStates?()
        } catch {
            logService.log(.error, .backup, "baseline state rebuild after recovery failed: \(type(of: error))")
        }

        discardStaging()
        logService.log(.info, .backup, "restore recovery completed: store back to its snapshot, sessions=\(snapshot.sessions.count)")
        return .recovered(sessionCount: snapshot.sessions.count)
    }

    /// A marker that cannot be removed only means this runs again next launch,
    /// finds the store already matching, and tries the removal again.
    private func discardStaging() {
        do {
            try staging.clear()
        } catch {
            logService.log(.error, .backup, "could not remove restore staging: \(type(of: error))")
        }
    }
}
