import Foundation

/// An export written to temporary storage, waiting for the share sheet.
struct PreparedExport: Sendable, Equatable, Identifiable {
    let id: UUID
    let fileURL: URL
    /// The export's own directory. Removed with the file, so nothing of it
    /// outlives the share.
    let directoryURL: URL
}

/// Generates export files and removes them (docs/13 §13.2 step 5, Task
/// 10.2.2). Protocol-fronted so the export flow is testable without a store
/// or a disk.
protocol ArchiveExporting: Sendable {
    /// Reads the store, seals it, writes the file.
    ///
    /// - Throws: `StabilyzError.export` — each case already has its
    ///   plain-language copy (docs/15 §15.1).
    func prepare(_ request: ExportRequest) async throws -> PreparedExport

    /// Deletes a prepared export's file and directory. Safe to call twice.
    func discard(_ export: PreparedExport) async

    /// Deletes every export left behind by a flow that never finished — the
    /// app killed with the share sheet open.
    func discardStaleExports() async
}

/// The export file's name (Task 10.2.2).
enum ExportFileNaming {
    /// `Stabilyz-Backup-2026-09-15-143012.stabilyz`, in the device's time zone
    /// — the name a person sees in Files or AirDrop, so it reads as their time.
    ///
    /// Gregorian whatever the device's calendar: a phone set to the Buddhist
    /// calendar would otherwise name a 2026 backup "2569", and the name would
    /// not sort next to the others.
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d-%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        return "Stabilyz-Backup-\(stamp).\(ArchiveFormat.fileExtension)"
    }
}

/// Production `ArchiveExporting`: snapshot, seal, write (docs/13 §13.2).
///
/// **What reaches the disk is ciphertext only** — the payload is serialized
/// and sealed in memory, and only the finished archive is written [PRD, docs/13
/// §13.2 step 5]. The file sits in its own directory under temporary storage,
/// under complete data protection (docs/18), and is removed by `discard` as
/// soon as the share sheet is done with it (docs/15 §15.1).
///
/// **The store is only read.** Nothing an export does can change local data.
struct ArchiveExportService: ArchiveExporting {
    /// The directory, under temporary storage, that every export lives in.
    static let exportsDirectoryName = "StabilyzExports"

    private let profiles: UserProfileRepository
    private let sessions: GaitSessionRepository
    private let baselines: BaselineRepository
    private let coder: SecureArchiveCoding
    private let fileIO: FileIO
    private let clock: Clock
    private let buildInfo: BuildInfoProviding
    private let logService: LogService
    private let timeZone: TimeZone

    init(
        profiles: UserProfileRepository,
        sessions: GaitSessionRepository,
        baselines: BaselineRepository,
        coder: SecureArchiveCoding,
        fileIO: FileIO,
        clock: Clock,
        buildInfo: BuildInfoProviding,
        logService: LogService,
        timeZone: TimeZone = .current
    ) {
        self.profiles = profiles
        self.sessions = sessions
        self.baselines = baselines
        self.coder = coder
        self.fileIO = fileIO
        self.clock = clock
        self.buildInfo = buildInfo
        self.logService = logService
        self.timeZone = timeZone
    }

    var exportsDirectory: URL {
        fileIO.temporaryDirectory().appendingPathComponent(Self.exportsDirectoryName, isDirectory: true)
    }

    func prepare(_ request: ExportRequest) async throws -> PreparedExport {
        // The request's passphrase bytes are wiped once sealing is done. Best
        // effort: an array shares storage with any copy still alive (docs/13
        // §13.3), so the flow does not keep the request.
        var passphrase = request.passphrase
        defer { SecureBytes.zeroize(&passphrase) }

        // Valid sessions only, every read naming its mode (EPIC 6 audit).
        let payload: ArchivePayload
        do {
            payload = try await ArchivePayload.snapshot(
                profiles: profiles,
                sessions: sessions,
                baselines: baselines,
                buildInfo: buildInfo,
                clock: clock
            )
        } catch {
            logService.log(.error, .backup, "export snapshot failed: \(type(of: error))")
            throw StabilyzError.export(.archiveGenerationFailed)
        }

        let archive: Data
        do {
            archive = try await coder.encode(payload, passphrase: passphrase, iterations: request.iterations)
        } catch ArchiveEncodingError.keyDerivationFailed {
            logService.log(.error, .backup, "export key derivation failed")
            throw StabilyzError.export(.keyDerivationFailed)
        } catch {
            logService.log(.error, .backup, "export sealing failed: \(LogRedaction.describe(error))")
            throw StabilyzError.export(.archiveGenerationFailed)
        }

        let id = UUID()
        let directory = exportsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let file = directory.appendingPathComponent(ExportFileNaming.fileName(for: payload.exportedAt, timeZone: timeZone))
        do {
            try fileIO.createDirectory(at: directory)
            try fileIO.writeProtected(archive, to: file)
        } catch {
            // Nothing half-made is left behind.
            try? fileIO.remove(at: directory)
            logService.log(.error, .backup, "export write failed: \(type(of: error))")
            throw StabilyzError.export(.fileWriteFailed)
        }

        // Counts and versions only — never key material or data (docs/20).
        logService.log(
            .info, .backup,
            "export written: envelope v\(ArchiveFormat.envelopeVersion) schema v\(ArchiveFormat.schemaVersion) sessions=\(payload.sessions.count) baselines=\(payload.baselines.count)"
        )
        return PreparedExport(id: id, fileURL: file, directoryURL: directory)
    }

    func discard(_ export: PreparedExport) async {
        guard fileIO.fileExists(at: export.directoryURL) else { return }
        do {
            try fileIO.remove(at: export.directoryURL)
            logService.log(.info, .backup, "export temporary file removed")
        } catch {
            logService.log(.error, .backup, "export temporary file could not be removed: \(type(of: error))")
        }
    }

    func discardStaleExports() async {
        guard let leftovers = try? fileIO.contentsOfDirectory(at: exportsDirectory), !leftovers.isEmpty else { return }
        for leftover in leftovers {
            try? fileIO.remove(at: leftover)
        }
        logService.log(.info, .backup, "removed \(leftovers.count) stale export(s)")
    }
}
