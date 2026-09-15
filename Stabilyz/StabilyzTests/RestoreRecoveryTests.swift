import Foundation
import Testing
@testable import Stabilyz

/// The on-disk restore safety net and launch recovery (Task 10.3.5, docs/13
/// §13.5 steps 2 and 4, [PRD §7 hard requirement]).

// MARK: - Doubles

private struct SimulatedFailure: Error {}

/// A scratch staging directory, removed by the test.
private struct StagingScratch: Sendable {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "restore-staging-\(UUID().uuidString)", directoryHint: .isDirectory)

    func area(fileIO: FileIO = FileManagerFileIO()) -> RestoreStagingArea {
        RestoreStagingArea(directory: directory, fileIO: fileIO, clock: FixedStoreClock())
    }

    var markerExists: Bool { FileManager.default.fileExists(atPath: area().markerURL.path) }
    var snapshotExists: Bool { FileManager.default.fileExists(atPath: area().snapshotURL.path) }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// A real replacer whose `replaceAll` follows a script, and which records what
/// was on disk at the moment of the first write.
private final class ObservingReplacer: StoreReplacing, @unchecked Sendable {
    typealias Script = @Sendable (_ call: Int, _ contents: StoreContents, _ base: SwiftDataStoreReplacer) async throws -> Void

    struct Sighting: Equatable {
        let marker: Bool
        let snapshot: StoreContents?
    }

    let base: SwiftDataStoreReplacer
    let scratch: StagingScratch
    let script: Script
    let calls = Locked(0)
    let atFirstWrite = Locked<Sighting?>(nil)

    init(_ store: InMemoryStore, scratch: StagingScratch, script: @escaping Script) {
        base = SwiftDataStoreReplacer(reader: store.reader, writer: store.writer)
        self.scratch = scratch
        self.script = script
    }

    func contents() async throws -> StoreContents { try await base.contents() }

    func replaceAll(with contents: StoreContents) async throws {
        let call = calls.withLock { (count: inout Int) -> Int in
            count += 1
            return count
        }
        if call == 1 {
            let data = try? Data(contentsOf: scratch.area().snapshotURL)
            let sighting = Sighting(marker: scratch.markerExists, snapshot: data.flatMap { try? StoreSnapshotCoding.decode($0) })
            atFirstWrite.withLock { $0 = sighting }
        }
        try await script(call, contents, base)
    }
}

/// Reads the store, refuses every write.
private struct UnwritableReplacer: StoreReplacing {
    let base: SwiftDataStoreReplacer
    func contents() async throws -> StoreContents { try await base.contents() }
    func replaceAll(with contents: StoreContents) async throws { throw SimulatedFailure() }
}

/// The file system of a device that is still locked: everything works except
/// reading a protected file.
private struct LockedDeviceFileIO: FileIO {
    let base = FileManagerFileIO()
    func temporaryDirectory() -> URL { base.temporaryDirectory() }
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func read(from url: URL) throws -> Data { throw CocoaError(.fileReadNoPermission) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func remove(at url: URL) throws { try base.remove(at: url) }
    func writeProtected(_ data: Data, to url: URL) throws { try base.writeProtected(data, to: url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
}

/// Counts launches of recovery; its one run writes a profile, so a router
/// that reads the store first would not see it.
private final class ProfileWritingRecovery: RestoreRecovering, @unchecked Sendable {
    let profiles: UserProfileRepository
    let runs = Locked(0)

    init(profiles: UserProfileRepository) { self.profiles = profiles }

    func recoverInterruptedRestore() async -> RestoreRecoveryOutcome {
        runs.withLock { $0 += 1 }
        try? await profiles.save(.fixture())
        return .recovered(sessionCount: 0)
    }
}

// MARK: - Fixtures

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

/// A local store with a profile, a baseline, a scored valid session and an
/// invalid one.
private func populatedStore() async throws -> InMemoryStore {
    let store = try InMemoryStore()
    try await store.profiles.save(.fixture(prosthesisType: "Local profile"))
    try await store.baselines.save(.fixture(mode: .fullTest))
    try await store.sessions.save(.fixtureValid(mode: .fullTest, startedAt: at(-86_400), score: .fixture(relativeIndex: 104)))
    try await store.sessions.save(.fixtureInvalid(mode: .quickTest, reason: .excessiveNoise, startedAt: at(-80_000)))
    return store
}

private func backupPayload() -> DecodedArchivePayload {
    DecodedArchivePayload(
        payload: ArchivePayload(
            profile: .fixture(level: .transfemoral, prosthesisType: "Backup profile"),
            baselines: [],
            sessions: [
                GaitSession.fixtureValid(mode: .quickTest, startedAt: at(0)),
                GaitSession.fixtureValid(mode: .fullTest, startedAt: at(3_600))
            ],
            appVersion: "1.0 (7)",
            algorithmVersion: "1.0.0",
            exportedAt: at(7_200)
        ),
        schemaVersion: 1
    )
}

private func target(of staged: DecodedArchivePayload) throws -> StoreContents {
    try #require(ArchiveRestoreService.target(for: staged.payload))
}

private func replacer(_ store: InMemoryStore) -> SwiftDataStoreReplacer {
    SwiftDataStoreReplacer(reader: store.reader, writer: store.writer)
}

private func recovery(_ store: InMemoryStore, _ scratch: StagingScratch, fileIO: FileIO = FileManagerFileIO()) -> RestoreRecoveryService {
    RestoreRecoveryService(staging: scratch.area(fileIO: fileIO), replacer: replacer(store), logService: SilentStoreLog())
}

private func expectRestoreError(_ expected: StabilyzError, _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("expected \(expected)")
    } catch {
        #expect(error as? StabilyzError == expected)
    }
}

// MARK: - The snapshot file

@Test func aSnapshotRoundTripsEveryRowIncludingInvalidAndScoredSessions() async throws {
    let store = try await populatedStore()
    let contents = try await replacer(store).contents()
    #expect(contents.sessions.contains { !$0.outcome.isValid }, "the fixture must hold an invalid session")
    #expect(contents.sessions.contains { $0.score != nil })
    #expect(contents.baselines.count == 1)

    let data = try StoreSnapshotCoding.encode(contents, createdAt: at(0))
    #expect(try StoreSnapshotCoding.decode(data) == contents)
}

@Test func anEmptyStoreRoundTrips() throws {
    let empty = StoreContents(profile: nil, baselines: [], sessions: [])
    #expect(try StoreSnapshotCoding.decode(StoreSnapshotCoding.encode(empty, createdAt: at(0))) == empty)
}

@Test func aDamagedSnapshotIsRefusedRatherThanRead() async throws {
    let store = try await populatedStore()
    let data = try StoreSnapshotCoding.encode(try await replacer(store).contents(), createdAt: at(0))

    #expect(throws: StoreSnapshotCoding.DecodingError.malformed) {
        try StoreSnapshotCoding.decode(data.prefix(data.count / 2))
    }
    #expect(throws: StoreSnapshotCoding.DecodingError.malformed) {
        try StoreSnapshotCoding.decode(Data("not a snapshot".utf8))
    }

    var file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    file["bodySHA256"] = String(repeating: "0", count: 64)
    #expect(throws: StoreSnapshotCoding.DecodingError.digestMismatch) {
        try StoreSnapshotCoding.decode(try JSONSerialization.data(withJSONObject: file))
    }

    file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    file["formatVersion"] = 99
    #expect(throws: StoreSnapshotCoding.DecodingError.unsupportedFormat(99)) {
        try StoreSnapshotCoding.decode(try JSONSerialization.data(withJSONObject: file))
    }
}

@Test func stagingNeverOverwritesASnapshotThatWasNotPutBack() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    let original = try await replacer(store).contents()
    let area = scratch.area()

    #expect(try area.stage(original))
    #expect(try area.stage(StoreContents(profile: nil, baselines: [], sessions: [])) == false)

    #expect(try StoreSnapshotCoding.decode(area.readSnapshot()) == original)
}

// MARK: - During a restore

@Test func aNormalRestoreStagesBeforeItsFirstWriteAndClearsAfter() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    let before = try await replacer(store).contents()
    let observing = ObservingReplacer(store, scratch: scratch) { _, contents, base in
        try await base.replaceAll(with: contents)
    }
    let service = ArchiveRestoreService(
        replacer: observing,
        events: StoreReplacementEvents(),
        logService: SilentStoreLog(),
        staging: scratch.area()
    )

    let staged = backupPayload()
    _ = try await service.restore(staged)

    #expect(observing.atFirstWrite.withLock { $0 } == .init(marker: true, snapshot: before))
    #expect(try await replacer(store).contents() == target(of: staged))
    #expect(scratch.markerExists == false)
    #expect(scratch.snapshotExists == false)
}

@Test func aRestoreThatRolledBackClearsItsStaging() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    let before = try await replacer(store).contents()
    let observing = ObservingReplacer(store, scratch: scratch) { _, _, _ in throw SimulatedFailure() }
    let service = ArchiveRestoreService(
        replacer: observing,
        events: StoreReplacementEvents(),
        logService: SilentStoreLog(),
        staging: scratch.area()
    )

    await expectRestoreError(.archiveImport(.restoreFailed)) { _ = try await service.restore(backupPayload()) }

    #expect(observing.atFirstWrite.withLock { $0 }?.marker == true)
    #expect(try await replacer(store).contents() == before)
    #expect(scratch.markerExists == false)
    #expect(scratch.snapshotExists == false)
}

@Test func aRestoreThatCouldNotBePutBackLeavesItsStagingForLaunch() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    let before = try await replacer(store).contents()
    // The write lands but reports failure; the rollback write then fails too.
    let observing = ObservingReplacer(store, scratch: scratch) { call, contents, base in
        if call == 1 { try await base.replaceAll(with: contents) }
        throw SimulatedFailure()
    }
    let service = ArchiveRestoreService(
        replacer: observing,
        events: StoreReplacementEvents(),
        logService: SilentStoreLog(),
        staging: scratch.area()
    )

    await expectRestoreError(.archiveImport(.restoreIncomplete)) { _ = try await service.restore(backupPayload()) }

    #expect(scratch.markerExists)
    #expect(scratch.snapshotExists)
    #expect(try await replacer(store).contents() != before)

    // The next launch puts it right.
    #expect(await recovery(store, scratch).recoverInterruptedRestore() == .recovered(sessionCount: before.sessions.count))
    #expect(try await replacer(store).contents() == before)
    #expect(scratch.markerExists == false)
}

@Test func stagingThatCannotBeWrittenRefusesTheRestoreBeforeTheStoreIsTouched() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    // A file where the staging directory should be.
    try Data("occupied".utf8).write(to: scratch.directory)
    let before = try await replacer(store).contents()
    let observing = ObservingReplacer(store, scratch: scratch) { _, contents, base in
        try await base.replaceAll(with: contents)
    }
    let service = ArchiveRestoreService(
        replacer: observing,
        events: StoreReplacementEvents(),
        logService: SilentStoreLog(),
        staging: scratch.area()
    )

    await expectRestoreError(.archiveImport(.restoreFailed)) { _ = try await service.restore(backupPayload()) }

    #expect(observing.calls.withLock { $0 } == 0)
    #expect(try await replacer(store).contents() == before)
}

// MARK: - At launch

@MainActor
@Test func launchingAfterARestoreDiedMidWriteRecoversTheSnapshot() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    let before = try await replacer(store).contents()

    // A restore staged, wrote, and the process ended before it could clear.
    #expect(try scratch.area().stage(before))
    try await replacer(store).replaceAll(with: target(of: backupPayload()))
    #expect(try await replacer(store).contents() != before)

    // The next launch: a fresh graph over the same store and staging.
    let dependencies = AppDependencies.live(container: store.container, restoreStagingDirectory: scratch.directory)
    let router = AppRouter(
        profiles: dependencies.userProfileRepository,
        drafts: EmptyOnboardingDraftStore(),
        logService: SilentStoreLog(),
        recovery: dependencies.restoreRecovery
    )
    await router.resolve()

    #expect(try await replacer(store).contents() == before)
    #expect(scratch.markerExists == false)
    #expect(scratch.snapshotExists == false)
    #expect(router.phase == .main)
    #expect(try await store.profiles.fetchProfile()?.prosthesisType == "Local profile")
}

@Test func aRestoreKilledBeforeItsWriteRecoversToTheSameStore() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    let before = try await replacer(store).contents()
    #expect(try scratch.area().stage(before))

    #expect(await recovery(store, scratch).recoverInterruptedRestore() == .recovered(sessionCount: before.sessions.count))

    #expect(try await replacer(store).contents() == before)
    #expect(scratch.markerExists == false)
    #expect(scratch.snapshotExists == false)
}

@MainActor
@Test func aDamagedSnapshotAtLaunchIsDiscardedAndLaunchGoesOn() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    let area = scratch.area()
    #expect(try area.stage(try await replacer(store).contents()))
    try Data("{\"formatVersion\":1,\"trunc".utf8).write(to: area.snapshotURL)
    let written = try target(of: backupPayload())
    try await replacer(store).replaceAll(with: written)

    let service = recovery(store, scratch)
    let router = AppRouter(
        profiles: store.profiles,
        drafts: EmptyOnboardingDraftStore(),
        logService: SilentStoreLog(),
        recovery: service
    )
    await router.resolve()

    // Nothing to put back: the store is left as its last transaction left it.
    #expect(try await replacer(store).contents() == written)
    #expect(scratch.markerExists == false)
    #expect(scratch.snapshotExists == false)
    #expect(router.phase == .main)
    #expect(router.launchFailure == nil)
}

@Test func aDamagedSnapshotReportsItself() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    let area = scratch.area()
    #expect(try area.stage(try await replacer(store).contents()))
    try Data("garbage".utf8).write(to: area.snapshotURL)

    #expect(await recovery(store, scratch).recoverInterruptedRestore() == .snapshotUnusable)
}

@Test func anUnreadableSnapshotIsKeptForTheNextLaunch() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    let before = try await replacer(store).contents()
    #expect(try scratch.area().stage(before))
    let written = try target(of: backupPayload())
    try await replacer(store).replaceAll(with: written)

    let locked = recovery(store, scratch, fileIO: LockedDeviceFileIO())
    #expect(await locked.recoverInterruptedRestore() == .snapshotUnreadable)
    #expect(scratch.markerExists)
    #expect(scratch.snapshotExists)
    #expect(try await replacer(store).contents() == written, "nothing is guessed at")

    // Unlocked, the next launch recovers.
    #expect(await recovery(store, scratch).recoverInterruptedRestore() == .recovered(sessionCount: before.sessions.count))
    #expect(try await replacer(store).contents() == before)
}

@Test func aRecoveryThatCannotWriteKeepsTheStagingForAnotherTry() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    #expect(try scratch.area().stage(try await replacer(store).contents()))
    try await replacer(store).replaceAll(with: target(of: backupPayload()))

    let service = RestoreRecoveryService(
        staging: scratch.area(),
        replacer: UnwritableReplacer(base: replacer(store)),
        logService: SilentStoreLog()
    )

    #expect(await service.recoverInterruptedRestore() == .recoveryFailed)
    #expect(scratch.markerExists)
    #expect(scratch.snapshotExists)
}

@Test func aSnapshotThatWasNeverMarkedIsDiscardedWithoutTouchingTheStore() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    let before = try await replacer(store).contents()
    let area = scratch.area()
    #expect(try area.stage(StoreContents(profile: nil, baselines: [], sessions: [])))
    try FileManager.default.removeItem(at: area.markerURL)

    #expect(await recovery(store, scratch).recoverInterruptedRestore() == .discardedStaleSnapshot)
    #expect(scratch.snapshotExists == false)
    #expect(try await replacer(store).contents() == before)
}

@Test func withNothingStagedLaunchRecoveryDoesNothing() async throws {
    let store = try await populatedStore()
    let scratch = StagingScratch()
    defer { scratch.remove() }
    let before = try await replacer(store).contents()

    #expect(await recovery(store, scratch).recoverInterruptedRestore() == .nothingToRecover)
    #expect(try await replacer(store).contents() == before)
}

@MainActor
@Test func theRouterRecoversOnceAndBeforeItReadsTheStore() async throws {
    let store = try InMemoryStore()
    let recovery = ProfileWritingRecovery(profiles: store.profiles)
    let router = AppRouter(
        profiles: store.profiles,
        drafts: EmptyOnboardingDraftStore(),
        logService: SilentStoreLog(),
        recovery: recovery
    )

    await router.resolve()
    // The profile recovery wrote was already there when the router looked.
    #expect(router.phase == .main)

    await router.resolve()
    #expect(recovery.runs.withLock { $0 } == 1)
}

@Test func theLiveGraphRecoversInterruptedRestoresAndTheDegradedGraphCannot() throws {
    let live = AppDependencies.live(container: try StoreContainer.make(inMemory: true))
    #expect(live.restoreRecovery is RestoreRecoveryService)
    #expect(AppDependencies.storeUnavailable().restoreRecovery == nil)
}
