import Foundation
import Testing
@testable import Stabilyz

/// Atomic store replacement and rollback (Task 10.3.4, docs/13 §13.5, docs/15
/// §15.1, [PRD §7 hard requirement]).

// MARK: - Doubles

private struct SimulatedFailure: Error {}

/// A real replacer whose `replaceAll` follows a script, call by call, so a
/// test can fail the first write in a chosen way and let the rollback write
/// through for real.
private final class ScriptedReplacer: StoreReplacing, @unchecked Sendable {
    typealias Script = @Sendable (_ call: Int, _ contents: StoreContents, _ base: SwiftDataStoreReplacer, _ writer: StoreWriter) async throws -> Void

    let base: SwiftDataStoreReplacer
    let writer: StoreWriter
    let script: Script
    let replaceCalls = Locked(0)

    init(_ store: InMemoryStore, script: @escaping Script) {
        base = SwiftDataStoreReplacer(reader: store.reader, writer: store.writer)
        writer = store.writer
        self.script = script
    }

    func contents() async throws -> StoreContents { try await base.contents() }

    func replaceAll(with contents: StoreContents) async throws {
        let call = replaceCalls.withLock { (count: inout Int) -> Int in
            count += 1
            return count
        }
        try await script(call, contents, base, writer)
    }
}

/// Cannot read the store.
private final class UnreadableReplacer: StoreReplacing, @unchecked Sendable {
    let replaceCalls = Locked(0)
    func contents() async throws -> StoreContents { throw SimulatedFailure() }
    func replaceAll(with contents: StoreContents) async throws { replaceCalls.withLock { $0 += 1 } }
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

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

/// A clinically consistent backup: five Quick Test calibration walks with the
/// baseline built from them, a scored sixth, and two Full Test walks with no
/// baseline yet.
private func backupPayload() throws -> ArchivePayload {
    let calibration = (0..<5).map { GaitSession.fixtureValid(mode: .quickTest, startedAt: at(Double($0) * 3_600)) }
    let sixth = GaitSession.fixtureValid(mode: .quickTest, startedAt: at(6 * 3_600), score: .fixture(relativeIndex: 108))
    let full = (0..<2).map { GaitSession.fixtureValid(mode: .fullTest, startedAt: at(Double(10 + $0) * 3_600)) }
    let baseline = try Baseline(
        id: UUID(),
        mode: .quickTest,
        stats: [BaselineMetricStat(metricID: .cadenceMean, mean: 104, sd: 2, n: 5, sdFloorApplied: true)],
        cadenceBPM: 104,
        algorithmVersion: "1.0.0",
        establishedAt: at(5 * 3_600),
        sourceSessionIDs: calibration.map(\.id)
    )
    return ArchivePayload(
        profile: .fixture(level: .transfemoral, side: .right, prosthesisType: "Backup profile"),
        baselines: [baseline],
        sessions: calibration + [sixth] + full,
        appVersion: "1.0 (7)",
        algorithmVersion: "1.0.0",
        exportedAt: at(20 * 3_600)
    )
}

private func staged(_ payload: ArchivePayload) -> DecodedArchivePayload {
    DecodedArchivePayload(payload: payload, schemaVersion: 1)
}

/// A local store that is not the backup: its own profile and baseline, a valid
/// session, and two invalid ones.
private func localStore() async throws -> InMemoryStore {
    let store = try InMemoryStore()
    try await store.profiles.save(.fixture(prosthesisType: "Local profile"))
    try await store.baselines.save(.fixture(mode: .fullTest))
    for session in [
        GaitSession.fixtureValid(mode: .fullTest, startedAt: at(-86_400)),
        GaitSession.fixtureInvalid(mode: .quickTest, reason: .excessiveNoise, startedAt: at(-80_000)),
        GaitSession.fixtureInvalid(mode: .fullTest, startedAt: at(-70_000))
    ] {
        try await store.sessions.save(session)
    }
    return store
}

private func contents(_ store: InMemoryStore) async throws -> StoreContents {
    try await SwiftDataStoreReplacer(reader: store.reader, writer: store.writer).contents()
}

private func restorer(
    _ replacer: StoreReplacing,
    events: StoreReplacementEvents = StoreReplacementEvents(),
    rebuilds: Locked<Int> = Locked(0),
    log: QuietLog = QuietLog()
) -> ArchiveRestoreService {
    ArchiveRestoreService(
        replacer: replacer,
        events: events,
        logService: log,
        rebuildBaselineStates: { rebuilds.withLock { $0 += 1 } }
    )
}

private func realRestorer(_ store: InMemoryStore, events: StoreReplacementEvents = StoreReplacementEvents(), rebuilds: Locked<Int> = Locked(0)) -> ArchiveRestoreService {
    restorer(SwiftDataStoreReplacer(reader: store.reader, writer: store.writer), events: events, rebuilds: rebuilds)
}

// MARK: - A successful replace

@Test func aStagedBackupReplacesTheWholeStoreAndIsQueryable() async throws {
    let store = try await localStore()
    let payload = try backupPayload()

    let receipt = try await realRestorer(store).restore(staged(payload))

    #expect(receipt == RestoreReceipt(schemaVersion: 1, sessionCount: 8, baselineModes: [.quickTest]))
    #expect(try await contents(store) == StoreContents(profile: payload.profile, baselines: payload.baselines, sessions: payload.sessions))

    // Queryable through the same repositories and derivation every screen uses.
    #expect(try await store.profiles.fetchProfile() == payload.profile)
    #expect(try await store.baselines.baseline(mode: .quickTest) == payload.baselines.first)
    #expect(try await store.baselines.baseline(mode: .fullTest) == nil)
    #expect(try await store.sessions.validSessionCount(mode: .quickTest) == 6)
    #expect(try await store.sessions.validSessionCount(mode: .fullTest) == 2)
    #expect(try await store.baselineState(for: .quickTest) == .established(payload.baselines[0]))
    #expect(try await store.baselineState(for: .fullTest) == .building(validCount: 2))
}

@Test func invalidLocalSessionsAreWipedLeavingOnlyTheBackupsValidSessions() async throws {
    let store = try await localStore()
    let payload = try backupPayload()
    let invalidBefore = try await contents(store).sessions.filter { !$0.isValid }
    #expect(invalidBefore.count == 2)

    _ = try await realRestorer(store).restore(staged(payload))

    let after = try await contents(store).sessions
    #expect(after.allSatisfy { $0.isValid })
    #expect(Set(after.map(\.id)) == Set(payload.sessions.map(\.id)))
    #expect(Set(after.map(\.id)).isDisjoint(with: invalidBefore.map(\.id)))
}

@Test func restoringABackupOfTheSameDataKeepsEveryRow() async throws {
    // Restoring your own export: every id in the archive is already a row.
    // Deleting and re-inserting the same unique ids in one save must not lose
    // any of them.
    let payload = try backupPayload()
    let store = try InMemoryStore()
    try await store.writer.replaceAll(profile: payload.profile, sessions: payload.sessions, baselines: payload.baselines)

    _ = try await realRestorer(store).restore(staged(payload))

    #expect(try await contents(store) == StoreContents(profile: payload.profile, baselines: payload.baselines, sessions: payload.sessions))
}

@Test func aSuccessfulRestoreRebuildsBaselineStatesAndBroadcastsOnce() async throws {
    let store = try await localStore()
    let events = StoreReplacementEvents()
    let rebuilds = Locked(0)
    var subscription = events.subscribe().makeAsyncIterator()

    let receipt = try await realRestorer(store, events: events, rebuilds: rebuilds).restore(staged(try backupPayload()))

    #expect(rebuilds.withLock { $0 } == 1)
    // Read outside `#expect`, where `next()` resolves to the stream's own
    // non-throwing overload rather than the protocol requirement.
    let heard = await subscription.next()
    #expect(heard == StoreReplacement(receipt: receipt))
}

@Test func everySubscriberHearsAboutTheReplacement() async throws {
    let events = StoreReplacementEvents()
    var first = events.subscribe().makeAsyncIterator()
    var second = events.subscribe().makeAsyncIterator()
    let replacement = StoreReplacement(receipt: RestoreReceipt(schemaVersion: 1, sessionCount: 0, baselineModes: []))

    events.publish(replacement)

    let heardFirst = await first.next()
    let heardSecond = await second.next()
    #expect(heardFirst == replacement)
    #expect(heardSecond == replacement)
    #expect(events.subscriberCount == 2)
}

// MARK: - Failure rolls back to exactly the pre-restore state

@Test func aFailedSaveLeavesTheStoreExactlyAsItWas() async throws {
    let store = try await localStore()
    let before = try await contents(store)
    let rebuilds = Locked(0)
    // The real transaction, failed at the moment of saving.
    let replacer = ScriptedReplacer(store) { call, contents, base, writer in
        guard call == 1 else { return try await base.replaceAll(with: contents) }
        try await writer.replaceAll(
            profile: contents.profile, sessions: contents.sessions, baselines: contents.baselines,
            beforeSave: { throw SimulatedFailure() }
        )
    }

    await #expect(throws: StabilyzError.archiveImport(.restoreFailed)) {
        _ = try await restorer(replacer, rebuilds: rebuilds).restore(staged(try backupPayload()))
    }

    #expect(try await contents(store) == before)
    // The transaction rolled back on its own; the snapshot was not needed.
    #expect(replacer.replaceCalls.withLock { $0 } == 1)
    #expect(rebuilds.withLock { $0 } == 0)
}

@Test func aWriteThatFailsAfterChangingTheStoreIsRolledBackToTheSnapshot() async throws {
    let store = try await localStore()
    let before = try await contents(store)
    // A failure the transaction did not contain: the store is wiped, then the
    // write reports an error.
    let replacer = ScriptedReplacer(store) { call, contents, base, writer in
        guard call == 1 else { return try await base.replaceAll(with: contents) }
        try await writer.replaceAll(profile: nil, sessions: [], baselines: [])
        throw SimulatedFailure()
    }

    await #expect(throws: StabilyzError.archiveImport(.restoreFailed)) {
        _ = try await restorer(replacer).restore(staged(try backupPayload()))
    }

    #expect(try await contents(store) == before)
    #expect(replacer.replaceCalls.withLock { $0 } == 2, "the snapshot was not written back")
}

@Test func aWriteThatDoesNotReadBackAsTheBackupIsRolledBack() async throws {
    let store = try await localStore()
    let before = try await contents(store)
    let events = StoreReplacementEvents()
    let rebuilds = Locked(0)
    // Reports success, but a session went missing on the way in.
    let replacer = ScriptedReplacer(store) { call, contents, base, _ in
        guard call == 1 else { return try await base.replaceAll(with: contents) }
        try await base.replaceAll(with: StoreContents(
            profile: contents.profile, baselines: contents.baselines, sessions: Array(contents.sessions.dropLast())
        ))
    }

    await #expect(throws: StabilyzError.archiveImport(.restoreFailed)) {
        _ = try await restorer(replacer, events: events, rebuilds: rebuilds).restore(staged(try backupPayload()))
    }

    #expect(try await contents(store) == before)
    // Caches are rebuilt and the replacement broadcast only after verification.
    #expect(rebuilds.withLock { $0 } == 0)
}

@Test func aRollbackThatCannotCompleteIsReportedAsIncomplete() async throws {
    let store = try await localStore()
    // Every write wipes the store and fails — the rollback included.
    let replacer = ScriptedReplacer(store) { _, _, _, writer in
        try await writer.replaceAll(profile: nil, sessions: [], baselines: [])
        throw SimulatedFailure()
    }

    await #expect(throws: StabilyzError.archiveImport(.restoreIncomplete)) {
        _ = try await restorer(replacer).restore(staged(try backupPayload()))
    }
    #expect(ErrorPresenter.presentation(for: .archiveImport(.restoreIncomplete))?.reassuresDataUnchanged == false)
}

@Test func anUnreadableStoreIsNeverWrittenTo() async throws {
    let replacer = UnreadableReplacer()

    await #expect(throws: StabilyzError.archiveImport(.restoreFailed)) {
        _ = try await restorer(replacer).restore(staged(try backupPayload()))
    }
    #expect(replacer.replaceCalls.withLock { $0 } == 0)
}

// MARK: - Clinical rules, before anything is touched

@Test func aBaselineWhoseSourceSessionsAreMissingIsRefusedBeforeTheStoreIsTouched() async throws {
    let store = try await localStore()
    let before = try await contents(store)
    let replacer = ScriptedReplacer(store) { _, contents, base, _ in try await base.replaceAll(with: contents) }

    let good = try backupPayload()
    let orphaned = ArchivePayload(
        profile: good.profile,
        baselines: good.baselines,
        // The five calibration walks the baseline was built from are gone.
        sessions: Array(good.sessions.dropFirst(5)),
        appVersion: good.appVersion, algorithmVersion: good.algorithmVersion, exportedAt: good.exportedAt
    )

    await #expect(throws: StabilyzError.archiveImport(.corruptedArchive)) {
        _ = try await restorer(replacer).restore(staged(orphaned))
    }
    #expect(replacer.replaceCalls.withLock { $0 } == 0)
    #expect(try await contents(store) == before)
}

@Test func aBaselineBuiltFromTheOtherModesSessionsIsRefused() throws {
    let good = try backupPayload()
    let fullIDs = good.sessions.filter { $0.mode == .fullTest }.map(\.id)
    let extraFull = (0..<3).map { GaitSession.fixtureValid(mode: .fullTest, startedAt: at(Double(30 + $0) * 3_600)) }
    let crossed = try Baseline(
        id: UUID(), mode: .quickTest, stats: [], cadenceBPM: 100, algorithmVersion: "1.0.0",
        establishedAt: at(0), sourceSessionIDs: fullIDs + extraFull.map(\.id)
    )
    let payload = ArchivePayload(
        profile: good.profile, baselines: [crossed], sessions: good.sessions + extraFull,
        appVersion: good.appVersion, algorithmVersion: good.algorithmVersion, exportedAt: good.exportedAt
    )
    #expect(ArchiveRestoreService.target(for: payload) == nil)
    #expect(ArchiveRestoreService.target(for: good) != nil)
}

@Test func theRestoreCopyPromisesOnlyWhatIsTrue() {
    let failed = ErrorPresenter.presentation(for: .archiveImport(.restoreFailed))
    #expect(failed?.message == "The backup couldn't be restored. Your existing data hasn't changed.")
    #expect(failed?.reassuresDataUnchanged == true)

    let incomplete = ErrorPresenter.presentation(for: .archiveImport(.restoreIncomplete))
    #expect(incomplete?.message.contains("hasn't changed") == false)
    #expect(incomplete?.isRecoverable == true)
}

// MARK: - End to end: export, inspect, restore

@Test func anExportInspectedAndRestoredReproducesTheSourceStore() async throws {
    let payload = try backupPayload()
    let coder = SecureArchiveCoder(minimumEncodeIterations: 1)
    let archive = try await coder.encode(payload, passphrase: PassphraseEncoding.bytes(from: "correct horse battery"), iterations: 1_000)

    let inspected = try await ArchiveInspectionService(coder: coder, fileIO: FileManagerFileIO(), logService: QuietLog())
        .inspect(archiveData: archive, passphrase: "correct horse battery")
    let store = try await localStore()
    _ = try await realRestorer(store).restore(inspected)

    #expect(try await contents(store) == StoreContents(profile: payload.profile, baselines: payload.baselines, sessions: payload.sessions))
}
