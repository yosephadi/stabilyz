import Foundation
import Testing
@testable import Stabilyz

/// Export file generation and temporary storage (Task 10.2.2, docs/13 §13.2,
/// docs/15 §15.1, docs/18).

// MARK: - Doubles

/// Real file operations inside a per-test directory, with writes that can be
/// made to fail.
private struct SandboxFileIO: FileIO {
    let root: URL
    let failWrites: Bool
    private let base = FileManagerFileIO()

    init(failWrites: Bool = false) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.failWrites = failWrites
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    func temporaryDirectory() -> URL { root }
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func read(from url: URL) throws -> Data { try base.read(from: url) }
    func write(_ data: Data, to url: URL) throws {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        try base.write(data, to: url)
    }
    func writeProtected(_ data: Data, to url: URL) throws {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        try base.writeProtected(data, to: url)
    }
    func remove(at url: URL) throws { try base.remove(at: url) }
    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
}

/// Forwards to a real repository and records every query.
private actor RecordingSessions: GaitSessionRepository {
    let base: GaitSessionRepository
    private(set) var queries: [(mode: TestMode, includeInvalid: Bool)] = []

    init(_ base: GaitSessionRepository) { self.base = base }

    var modes: [TestMode] { queries.map(\.mode) }
    var everAskedForInvalid: Bool { queries.contains { $0.includeInvalid } }

    func save(_ session: GaitSession) async throws { try await base.save(session) }
    func session(id: UUID) async throws -> GaitSession? { try await base.session(id: id) }
    func validSessionCount(mode: TestMode) async throws -> Int { try await base.validSessionCount(mode: mode) }
    func sessions(mode: TestMode, includeInvalid: Bool, limit: Int?) async throws -> [GaitSession] {
        queries.append((mode, includeInvalid))
        return try await base.sessions(mode: mode, includeInvalid: includeInvalid, limit: limit)
    }
}

private struct UnreadableProfiles: UserProfileRepository {
    struct Unreadable: Error {}
    func fetchProfile() async throws -> UserProfile? { throw Unreadable() }
    func save(_ profile: UserProfile) async throws {}
}

private struct FailingCoder: SecureArchiveCoding {
    let error: ArchiveEncodingError
    func encode(_ payload: ArchivePayload, passphrase: [UInt8], iterations: Int) async throws -> Data { throw error }
    func decode(archiveData: Data, passphrase: [UInt8]) async throws -> DecodedArchivePayload { throw error }
}

private struct StubBuildInfo: BuildInfoProviding {
    let appVersion = "1.0 (7)"
    let deviceModel = "iPhone17,1"
}

private final class QuietLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) { entries.withLock { $0.append(message) } }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

// MARK: - Fixtures

private let passphrase = PassphraseEncoding.bytes(from: "correct horse battery")
private let request = ExportRequest(passphrase: passphrase, iterations: 1_000)
private let testCoder = SecureArchiveCoder(minimumEncodeIterations: 1)
private let utc = TimeZone(identifier: "UTC")!

private struct Fixture {
    let store: InMemoryStore
    let sessions: RecordingSessions
    let valid: [GaitSession]
    let invalid: [GaitSession]
}

/// A store with a profile, one baseline, and valid and invalid sessions in both
/// modes.
private func populatedStore() async throws -> Fixture {
    let store = try InMemoryStore()
    try await store.profiles.save(.fixture())
    try await store.baselines.save(.fixture(mode: .quickTest))

    let quick = GaitSession.fixtureValid(mode: .quickTest, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let full = GaitSession.fixtureValid(mode: .fullTest, startedAt: Date(timeIntervalSince1970: 1_700_000_600))
    let noisy = GaitSession.fixtureInvalid(mode: .quickTest, reason: .excessiveNoise, startedAt: Date(timeIntervalSince1970: 1_700_000_300))
    let short = GaitSession.fixtureInvalid(mode: .fullTest, startedAt: Date(timeIntervalSince1970: 1_700_000_900))
    for session in [quick, noisy, full, short] {
        try await store.sessions.save(session)
    }
    return Fixture(store: store, sessions: RecordingSessions(store.sessions), valid: [quick, full], invalid: [noisy, short])
}

private func service(
    _ fixture: Fixture,
    fileIO: FileIO,
    profiles: UserProfileRepository? = nil,
    coder: SecureArchiveCoding = testCoder,
    log: LogService = QuietLog()
) -> ArchiveExportService {
    ArchiveExportService(
        profiles: profiles ?? fixture.store.profiles,
        sessions: fixture.sessions,
        baselines: fixture.store.baselines,
        coder: coder,
        fileIO: fileIO,
        clock: FixedStoreClock(),
        buildInfo: StubBuildInfo(),
        logService: log,
        timeZone: utc
    )
}

// MARK: - The pipeline

@Test func theExportedFileHoldsTheStoresValidSessionsAndNothingElse() async throws {
    let fixture = try await populatedStore()
    let sandbox = SandboxFileIO()
    defer { sandbox.tearDown() }

    let prepared = try await service(fixture, fileIO: sandbox).prepare(request)
    let decoded = try await testCoder.decode(archiveData: try sandbox.read(from: prepared.fileURL), passphrase: passphrase)

    #expect(decoded.payload.sessions.map(\.id) == fixture.valid.map(\.id))
    #expect(Set(decoded.payload.sessions.map(\.id)).isDisjoint(with: fixture.invalid.map(\.id)))
    let storedProfile = try await fixture.store.profiles.fetchProfile()
    #expect(decoded.payload.profile == storedProfile)
    #expect(decoded.payload.baselines.map(\.mode) == [.quickTest])
    #expect(decoded.payload.exportedAt == FixedStoreClock().now)
}

@Test func everySessionReadNamesItsModeAndAsksForValidOnly() async throws {
    let fixture = try await populatedStore()
    let sandbox = SandboxFileIO()
    defer { sandbox.tearDown() }

    _ = try await service(fixture, fileIO: sandbox).prepare(request)

    #expect(Set(await fixture.sessions.modes) == Set(TestMode.allCases))
    #expect(await fixture.sessions.everAskedForInvalid == false)
}

@Test func theArchiveIsWrittenWithTheRequestedIterations() async throws {
    let fixture = try await populatedStore()
    let sandbox = SandboxFileIO()
    defer { sandbox.tearDown() }

    let prepared = try await service(fixture, fileIO: sandbox).prepare(ExportRequest(passphrase: passphrase, iterations: 1_234))
    #expect(try ArchiveEnvelope.parse(try sandbox.read(from: prepared.fileURL)).header.iterations == 1_234)
}

// MARK: - File naming and location

@Test func theFileNameIsTheBackupTimestampInTheDevicesTimeZone() {
    let date = Date(timeIntervalSince1970: 1_800_000_000) // 15 Jan 2027, 08:00:00 UTC
    #expect(ExportFileNaming.fileName(for: date, timeZone: utc) == "Stabilyz-Backup-2027-01-15-080000.stabilyz")
    #expect(ExportFileNaming.fileName(for: date, timeZone: TimeZone(identifier: "Asia/Jakarta")!)
        == "Stabilyz-Backup-2027-01-15-150000.stabilyz")
    // Seconds and single-digit fields are zero-padded.
    #expect(ExportFileNaming.fileName(for: Date(timeIntervalSince1970: 1_767_229_445), timeZone: utc)
        == "Stabilyz-Backup-2026-01-01-010405.stabilyz")
}

@Test func thePreparedFileIsNamedByTheSpecInItsOwnTemporaryDirectory() async throws {
    let fixture = try await populatedStore()
    let sandbox = SandboxFileIO()
    defer { sandbox.tearDown() }

    let prepared = try await service(fixture, fileIO: sandbox).prepare(request)

    #expect(prepared.fileURL.lastPathComponent == "Stabilyz-Backup-2027-01-15-080000.stabilyz")
    #expect(prepared.fileURL.deletingLastPathComponent() == prepared.directoryURL)
    #expect(prepared.directoryURL.deletingLastPathComponent().lastPathComponent == ArchiveExportService.exportsDirectoryName)
    #expect(prepared.directoryURL.path.hasPrefix(sandbox.root.path))
    #expect(sandbox.fileExists(at: prepared.fileURL))
}

@Test func twoExportsInTheSameSecondDoNotCollide() async throws {
    let fixture = try await populatedStore()
    let sandbox = SandboxFileIO()
    defer { sandbox.tearDown() }
    let exporter = service(fixture, fileIO: sandbox)

    let first = try await exporter.prepare(request)
    let second = try await exporter.prepare(request)

    #expect(first.fileURL.lastPathComponent == second.fileURL.lastPathComponent)
    #expect(first.fileURL != second.fileURL)
    #expect(sandbox.fileExists(at: first.fileURL) && sandbox.fileExists(at: second.fileURL))
}

// MARK: - Cleanup

@Test func discardingDeletesTheFileAndItsDirectory() async throws {
    let fixture = try await populatedStore()
    let sandbox = SandboxFileIO()
    defer { sandbox.tearDown() }
    let exporter = service(fixture, fileIO: sandbox)

    let prepared = try await exporter.prepare(request)
    await exporter.discard(prepared)

    #expect(sandbox.fileExists(at: prepared.fileURL) == false)
    #expect(sandbox.fileExists(at: prepared.directoryURL) == false)

    // A second discard — the sheet and a close both reporting — is harmless.
    await exporter.discard(prepared)
}

@Test func staleExportsAreSweptAway() async throws {
    let fixture = try await populatedStore()
    let sandbox = SandboxFileIO()
    defer { sandbox.tearDown() }
    let exporter = service(fixture, fileIO: sandbox)

    let abandoned = [try await exporter.prepare(request), try await exporter.prepare(request)]
    await exporter.discardStaleExports()

    #expect(abandoned.allSatisfy { !sandbox.fileExists(at: $0.fileURL) })
    #expect(try sandbox.contentsOfDirectory(at: exporter.exportsDirectory).isEmpty)
    // Nothing to sweep is not an error.
    await exporter.discardStaleExports()
}

// MARK: - Failures leave nothing behind

@Test func aMissingProfileFailsWithNoFileWritten() async throws {
    let store = try InMemoryStore()
    let fixture = Fixture(store: store, sessions: RecordingSessions(store.sessions), valid: [], invalid: [])
    let sandbox = SandboxFileIO()
    defer { sandbox.tearDown() }
    let exporter = service(fixture, fileIO: sandbox)

    await #expect(throws: StabilyzError.export(.archiveGenerationFailed)) {
        _ = try await exporter.prepare(request)
    }
    #expect(try sandbox.contentsOfDirectory(at: exporter.exportsDirectory).isEmpty)
}

@Test func anUnreadableStoreFailsWithNoFileWritten() async throws {
    let fixture = try await populatedStore()
    let sandbox = SandboxFileIO()
    defer { sandbox.tearDown() }
    let exporter = service(fixture, fileIO: sandbox, profiles: UnreadableProfiles())

    await #expect(throws: StabilyzError.export(.archiveGenerationFailed)) {
        _ = try await exporter.prepare(request)
    }
    #expect(try sandbox.contentsOfDirectory(at: exporter.exportsDirectory).isEmpty)
}

@Test func aStorageErrorFailsAsAFileWriteAndLeavesNoDirectory() async throws {
    let fixture = try await populatedStore()
    let sandbox = SandboxFileIO(failWrites: true)
    defer { sandbox.tearDown() }
    let exporter = service(fixture, fileIO: sandbox)

    await #expect(throws: StabilyzError.export(.fileWriteFailed)) {
        _ = try await exporter.prepare(request)
    }
    #expect(try sandbox.contentsOfDirectory(at: exporter.exportsDirectory).isEmpty)
}

@Test func sealingFailuresMapToTheirExportErrors() async throws {
    let fixture = try await populatedStore()
    let sandbox = SandboxFileIO()
    defer { sandbox.tearDown() }

    await #expect(throws: StabilyzError.export(.keyDerivationFailed)) {
        _ = try await service(fixture, fileIO: sandbox, coder: FailingCoder(error: .keyDerivationFailed)).prepare(request)
    }
    await #expect(throws: StabilyzError.export(.archiveGenerationFailed)) {
        _ = try await service(fixture, fileIO: sandbox, coder: FailingCoder(error: .encryptionFailed)).prepare(request)
    }
}

@Test func theLogCarriesCountsButNeverThePassphrase() async throws {
    let fixture = try await populatedStore()
    let sandbox = SandboxFileIO()
    defer { sandbox.tearDown() }
    let log = QuietLog()

    _ = try await service(fixture, fileIO: sandbox, log: log).prepare(request)

    let lines = log.entries.withLock { $0 }
    #expect(lines.contains { $0.contains("sessions=2") })
    #expect(lines.allSatisfy { !$0.contains("correct horse") })
}

@Test func everyExportFailureSaysNothingWasChanged() {
    for failure in [StabilyzError.Export.archiveGenerationFailed, .fileWriteFailed, .keyDerivationFailed, .shareFailed] {
        let presentation = ErrorPresenter.presentation(for: .export(failure))
        #expect(presentation?.message == "Export didn't complete — nothing was changed.")
        #expect(presentation?.isRecoverable == true)
    }
}
