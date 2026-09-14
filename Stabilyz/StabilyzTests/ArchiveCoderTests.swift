import CryptoKit
import Foundation
import Testing
@testable import Stabilyz

/// The export file (Task 10.1.3, docs/13 §13.1–13.6, docs/19 crypto row).

// MARK: - Doubles

/// Counts derivations, so a test can prove a header was refused before any.
private final class CountingKeyDerivation: KeyDerivation, @unchecked Sendable {
    let calls = Locked(0)

    func deriveKey(passphrase: [UInt8], salt: [UInt8], iterations: Int, keyByteCount: Int) throws -> [UInt8] {
        calls.withLock { $0 += 1 }
        return try CommonCryptoKeyDerivation().deriveKey(
            passphrase: passphrase, salt: salt, iterations: iterations, keyByteCount: keyByteCount
        )
    }

    func calibratedIterationCount(targetDuration: TimeInterval) -> Int { KeyDerivationPolicy.minimumIterations }
}

/// Always the same bytes. Tests only.
private struct RepeatingRandomSource: RandomSource {
    func bytes(count: Int) throws -> [UInt8] { [UInt8](repeating: 0x42, count: count) }
}

private struct StubBuildInfo: BuildInfoProviding {
    let appVersion = "1.0 (7)"
    let deviceModel = "iPhone17,1"
}

// MARK: - Fixtures

/// Fast derivation for tests: the format is what is under test here, and the
/// KDF's own costs are pinned in `KeyDerivationTests`.
private let testIterations = 1_000
private let passphrase = PassphraseEncoding.bytes(from: "correct horse battery")
private let coder = SecureArchiveCoder(minimumEncodeIterations: 1)

/// A session carrying every field the archive has to preserve, with a
/// sub-second start time that ISO 8601 would have truncated.
private func richSession(mode: TestMode, startedAt: TimeInterval) -> GaitSession {
    GaitSession.valid(
        id: UUID(),
        mode: mode,
        startedAt: Date(timeIntervalSince1970: startedAt),
        endedAt: Date(timeIntervalSince1970: startedAt + 121.375),
        advertisedClockElapsed: mode.advertisedDuration,
        validWalkingDuration: .milliseconds(95_250),
        metrics: .fixture(),
        score: .fixture(relativeIndex: 108),
        provisionalScore: .fixture(value: 73),
        audioConfig: .metronome(cue: .fixture(bpm: 104, mode: mode)),
        audioSilencedAt: .milliseconds(61_500),
        algorithmVersion: "1.0.0",
        appVersion: "1.0 (7)",
        deviceModel: "iPhone17,1",
        interruptionCount: 1,
        gapInfo: SessionGapInfo(gapCount: 2, totalGapDuration: .milliseconds(340), longestGapDuration: .milliseconds(210)),
        pedometerAvailable: false
    )
}

private func payload(
    sessions: [GaitSession]? = nil,
    baselines: [Baseline]? = nil,
    profile: UserProfile = .fixture(prosthesisType: "Ottobock C-Leg")
) -> ArchivePayload {
    ArchivePayload(
        profile: profile,
        baselines: baselines ?? [.fixture(mode: .quickTest), .fixture(mode: .fullTest)],
        sessions: sessions ?? [
            richSession(mode: .quickTest, startedAt: 1_700_000_000.123456),
            GaitSession.fixtureValid(mode: .fullTest, startedAt: Date(timeIntervalSince1970: 1_700_086_400.5))
        ],
        appVersion: "1.0 (7)",
        algorithmVersion: "1.0.0",
        exportedAt: Date(timeIntervalSince1970: 1_700_200_000.25)
    )
}

private func encoded(_ archive: ArchivePayload = payload(), using coder: SecureArchiveCoder = coder) async throws -> Data {
    try await coder.encode(archive, passphrase: passphrase, iterations: testIterations)
}

private func flipping(_ data: Data, at offset: Int) -> Data {
    var copy = data
    copy[copy.startIndex + offset] ^= 0x01
    return copy
}

/// The same file with one header field replaced, re-serialized as a real
/// writer would.
private func rewritingHeader(
    of archive: Data,
    envelopeVersion: Int? = nil,
    cryptoSuite: Int? = nil,
    iterations: Int? = nil
) throws -> Data {
    let envelope = try ArchiveEnvelope.parse(archive)
    let h = envelope.header
    let forged = ArchiveHeader(
        envelopeVersion: envelopeVersion ?? h.envelopeVersion,
        cryptoSuite: cryptoSuite ?? h.cryptoSuite,
        schemaVersion: h.schemaVersion,
        algorithmVersion: h.algorithmVersion,
        iterations: iterations ?? h.iterations,
        salt: h.salt,
        keyCheck: h.keyCheck
    )
    return try forged.serialized() + envelope.payload.nonce + envelope.payload.ciphertext + envelope.payload.tag
}

// MARK: - Round trip

@Test func aRoundTripRestoresTheProfileBaselinesAndSessionsExactly() async throws {
    let original = payload()
    let decoded = try await coder.decode(archiveData: try await encoded(original), passphrase: passphrase)

    #expect(decoded.schemaVersion == 1)
    #expect(decoded.payload.profile == original.profile)
    #expect(decoded.payload.baselines == original.baselines)
    // Every field, sub-second times, durations and the metronome cue included.
    #expect(decoded.payload.sessions == original.sessions)
    #expect(decoded.payload.appVersion == "1.0 (7)")
    #expect(decoded.payload.algorithmVersion == "1.0.0")
    #expect(decoded.payload.exportedAt == original.exportedAt)
    #expect(decoded.payload == original)
}

@Test func anArchiveWithNoBaselinesOrSessionsRoundTrips() async throws {
    // A user who finished onboarding and never walked still has a profile to
    // move to a new phone.
    let empty = payload(sessions: [], baselines: [])
    let decoded = try await coder.decode(archiveData: try await encoded(empty), passphrase: passphrase)
    #expect(decoded.payload == empty)
}

// MARK: - Valid sessions only (EPIC 6 audit)

@Test func invalidSessionsNeverEnterThePayload() async throws {
    let valid = GaitSession.fixtureValid(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let noisy = GaitSession.fixtureInvalid(reason: .excessiveNoise, startedAt: Date(timeIntervalSince1970: 1_700_000_100))
    let short = GaitSession.fixtureInvalid(reason: .insufficientValidWalking, startedAt: Date(timeIntervalSince1970: 1_700_000_200))

    let archive = payload(sessions: [valid, noisy, short])
    #expect(archive.sessions.map(\.id) == [valid.id])

    let decoded = try await coder.decode(archiveData: try await encoded(archive), passphrase: passphrase)
    #expect(decoded.payload.sessions.map(\.id) == [valid.id])
}

@Test func anInvalidSessionHasNoArchivedForm() {
    #expect(ArchivedSession(GaitSession.fixtureInvalid()) == nil)
    #expect(ArchivedSession(GaitSession.fixtureValid()) != nil)
}

@Test func aSnapshotOfAStoreHoldingInvalidSessionsExportsNoneOfThem() async throws {
    let store = try InMemoryStore()
    try await store.profiles.save(.fixture())
    try await store.baselines.save(.fixture(mode: .quickTest))

    let quick = GaitSession.fixtureValid(mode: .quickTest, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let full = GaitSession.fixtureValid(mode: .fullTest, startedAt: Date(timeIntervalSince1970: 1_700_000_500))
    let invalidQuick = GaitSession.fixtureInvalid(mode: .quickTest, startedAt: Date(timeIntervalSince1970: 1_700_000_250))
    let invalidFull = GaitSession.fixtureInvalid(mode: .fullTest, reason: .sensorFailure, startedAt: Date(timeIntervalSince1970: 1_700_000_750))
    for session in [quick, invalidQuick, full, invalidFull] {
        try await store.sessions.save(session)
    }

    let snapshot = try await ArchivePayload.snapshot(
        profiles: store.profiles,
        sessions: store.sessions,
        baselines: store.baselines,
        buildInfo: StubBuildInfo(),
        clock: FixedStoreClock()
    )
    #expect(snapshot.sessions.map(\.id) == [quick.id, full.id])
    #expect(snapshot.baselines.map(\.mode) == [.quickTest])
    #expect(snapshot.exportedAt == FixedStoreClock().now)

    let decoded = try await coder.decode(archiveData: try await encoded(snapshot), passphrase: passphrase)
    let exported = Set(decoded.payload.sessions.map(\.id))
    #expect(exported == [quick.id, full.id])
    #expect(exported.isDisjoint(with: [invalidQuick.id, invalidFull.id]))
}

@Test func aSnapshotWithoutAProfileRefusesToExport() async throws {
    let store = try InMemoryStore()
    await #expect(throws: ArchiveEncodingError.missingProfile) {
        _ = try await ArchivePayload.snapshot(
            profiles: store.profiles, sessions: store.sessions, baselines: store.baselines,
            buildInfo: StubBuildInfo(), clock: FixedStoreClock()
        )
    }
}

// MARK: - Wrong passphrase vs damaged file

@Test func aWrongPassphraseIsReportedAsAWrongPassphrase() async throws {
    let archive = try await encoded()

    for attempt in ["correct horse batterY", "correct horse", "x"] {
        await #expect(throws: StabilyzError.archiveImport(.wrongPassphrase)) {
            _ = try await coder.decode(archiveData: archive, passphrase: PassphraseEncoding.bytes(from: attempt))
        }
    }
    await #expect(throws: StabilyzError.archiveImport(.wrongPassphrase)) {
        _ = try await coder.decode(archiveData: archive, passphrase: [])
    }
}

@Test func tamperedCiphertextIsACorruptedArchiveNotAWrongPassphrase() async throws {
    let archive = try await encoded()
    let envelope = try ArchiveEnvelope.parse(archive)
    let ciphertextStart = envelope.authenticatedHeader.count + EncryptionPolicy.nonceByteCount

    for offset in [ciphertextStart, ciphertextStart + envelope.payload.ciphertext.count / 2, archive.count - 17] {
        await #expect(throws: StabilyzError.archiveImport(.corruptedArchive)) {
            _ = try await coder.decode(archiveData: flipping(archive, at: offset), passphrase: passphrase)
        }
    }
}

@Test func aTamperedTagOrPayloadNonceIsACorruptedArchive() async throws {
    let archive = try await encoded()
    let nonceOffset = try ArchiveEnvelope.parse(archive).authenticatedHeader.count

    for offset in [archive.count - 1, nonceOffset] {
        await #expect(throws: StabilyzError.archiveImport(.corruptedArchive)) {
            _ = try await coder.decode(archiveData: flipping(archive, at: offset), passphrase: passphrase)
        }
    }
}

@Test func anEditedHeaderFieldIsACorruptedArchive() async throws {
    // The header is the payload's associated data. Changing the schema version
    // (bytes 9–10) or the algorithm version (from byte 12) leaves the
    // passphrase provably right and the payload unopenable.
    let archive = try await encoded()

    for offset in [10, 12] {
        await #expect(throws: StabilyzError.archiveImport(.corruptedArchive)) {
            _ = try await coder.decode(archiveData: flipping(archive, at: offset), passphrase: passphrase)
        }
    }
}

@Test func aTamperedKeyCheckReadsAsAWrongPassphrase() async throws {
    // Documented limit: a key-check that does not open is indistinguishable
    // from a wrong passphrase. Pinned so the behaviour is a decision, not an
    // accident.
    let archive = try await encoded()
    let keyCheckTagOffset = try ArchiveEnvelope.parse(archive).authenticatedHeader.count - 1

    await #expect(throws: StabilyzError.archiveImport(.wrongPassphrase)) {
        _ = try await coder.decode(archiveData: flipping(archive, at: keyCheckTagOffset), passphrase: passphrase)
    }
}

@Test func truncatedFilesAreCorruptedArchives() async throws {
    let archive = try await encoded()

    for length in [8, 20, 60, 90, archive.count - 16, archive.count - 1] {
        await #expect(throws: StabilyzError.archiveImport(.corruptedArchive)) {
            _ = try await coder.decode(archiveData: Data(archive.prefix(length)), passphrase: passphrase)
        }
    }
}

// MARK: - The envelope is checked before any key derivation

@Test func iterationsAboveTheCeilingAreRejectedBeforeAnyDerivation() async throws {
    let archive = try await encoded()
    let counting = CountingKeyDerivation()
    let guarded = SecureArchiveCoder(keyDerivation: counting, minimumEncodeIterations: 1)

    for iterations in [ArchiveFormat.maximumIterations + 1, Int(UInt32.max)] {
        let forged = try rewritingHeader(of: archive, iterations: iterations)
        await #expect(throws: StabilyzError.schemaCompatibility(.unsupportedIterationCount(count: iterations))) {
            _ = try await guarded.decode(archiveData: forged, passphrase: passphrase)
        }
    }
    // Zero is not a setting anything could have written.
    await #expect(throws: StabilyzError.archiveImport(.corruptedArchive)) {
        _ = try await guarded.decode(archiveData: try rewritingHeader(of: archive, iterations: 0), passphrase: passphrase)
    }
    #expect(counting.calls.withLock { $0 } == 0, "a refused header still cost a key derivation")
}

@Test func theCeilingItselfIsAccepted() async throws {
    let forged = try rewritingHeader(of: try await encoded(), iterations: ArchiveFormat.maximumIterations)
    #expect(try ArchiveEnvelope.parse(forged).header.iterations == ArchiveFormat.maximumIterations)
}

@Test func aFileWithoutTheMagicIsNotAStabilyzArchive() async throws {
    let notOurs = [Data(), Data("PK\u{03}\u{04}".utf8), Data("STBLY".utf8), Data(repeating: 0, count: 200)]
    for data in notOurs {
        await #expect(throws: StabilyzError.archiveImport(.notAStabilyzArchive)) {
            _ = try await coder.decode(archiveData: data, passphrase: passphrase)
        }
    }
}

@Test func aNewerEnvelopeOrSuiteIsUnsupportedNotCorrupted() async throws {
    let archive = try await encoded()

    await #expect(throws: StabilyzError.schemaCompatibility(.unsupportedEnvelope(version: 2))) {
        _ = try await coder.decode(archiveData: try rewritingHeader(of: archive, envelopeVersion: 2), passphrase: passphrase)
    }
    await #expect(throws: StabilyzError.schemaCompatibility(.unsupportedEnvelope(version: 1))) {
        _ = try await coder.decode(archiveData: try rewritingHeader(of: archive, cryptoSuite: 2), passphrase: passphrase)
    }
}

// MARK: - Schema versions and migration

@Test func aFutureSchemaIsReportedAfterDecryptionAsIncompatible() async throws {
    let future = SecureArchiveCoder(minimumEncodeIterations: 1, writtenSchemaVersion: 2)
    let archive = try await encoded(using: future)

    // With the right passphrase: incompatible, not corrupted.
    await #expect(throws: StabilyzError.schemaCompatibility(.futureSchema(version: 2))) {
        _ = try await coder.decode(archiveData: archive, passphrase: passphrase)
    }
    // With the wrong one: the passphrase is checked first [PRD order].
    await #expect(throws: StabilyzError.archiveImport(.wrongPassphrase)) {
        _ = try await coder.decode(archiveData: archive, passphrase: [9, 9, 9])
    }
}

@Test func migrationStepsRunInSequenceFromTheWrittenVersion() throws {
    let chain = ArchiveMigrations(steps: [
        1: { Data($0 + Data("→2".utf8)) },
        2: { Data($0 + Data("→3".utf8)) }
    ])

    #expect(try chain.migrate(Data("v1".utf8), from: 1, to: 3) == Data("v1→2→3".utf8))
    #expect(try chain.migrate(Data("v2".utf8), from: 2, to: 3) == Data("v2→3".utf8))
    #expect(try chain.migrate(Data("v3".utf8), from: 3, to: 3) == Data("v3".utf8))
}

@Test func aGapInTheMigrationChainIsRefused() {
    let broken = ArchiveMigrations(steps: [1: { $0 }])
    #expect(throws: StabilyzError.archiveImport(.corruptedArchive)) {
        _ = try broken.migrate(Data(), from: 1, to: 3)
    }
    #expect(ArchiveMigrations.production.steps.isEmpty, "schema v1 has nothing to migrate from")
}

// MARK: - The header carries its parameters

@Test func theHeaderCarriesEverythingNeededToDecrypt() async throws {
    let header = try ArchiveEnvelope.parse(try await encoded()).header

    #expect(header.envelopeVersion == 1)
    #expect(header.cryptoSuite == 1)
    #expect(header.schemaVersion == 1)
    #expect(header.algorithmVersion == "1.0.0")
    #expect(header.iterations == testIterations)
    #expect(header.salt.count == 16)
    #expect(header.keyCheck.nonce.count == 12)
}

@Test func everyExportDrawsAFreshSaltAndFreshNonces() async throws {
    let first = try ArchiveEnvelope.parse(try await encoded())
    let second = try ArchiveEnvelope.parse(try await encoded())

    #expect(first.header.salt != second.header.salt)
    #expect(first.payload.nonce != second.payload.nonce)
    #expect(first.header.keyCheck.nonce != first.payload.nonce)
    #expect(first.payload.ciphertext != second.payload.ciphertext)
}

@Test func noPlaintextReachesTheFile() async throws {
    let marker = "PROFILE-MARKER-4f1c"
    let archive = try await encoded(payload(profile: .fixture(prosthesisType: marker)))

    #expect(archive.range(of: Data(marker.utf8)) == nil)
    #expect(archive.range(of: Data(Data(marker.utf8).base64EncodedString().utf8)) == nil)
}

// MARK: - Encoding refuses what it must not write

@Test func iterationsOutsideTheAllowedRangeAreRefused() async throws {
    let production = SecureArchiveCoder()
    let tooFew = KeyDerivationPolicy.minimumIterations - 1
    await #expect(throws: ArchiveEncodingError.iterationsOutOfRange(tooFew)) {
        _ = try await production.encode(payload(), passphrase: passphrase, iterations: tooFew)
    }

    let tooMany = ArchiveFormat.maximumIterations + 1
    await #expect(throws: ArchiveEncodingError.iterationsOutOfRange(tooMany)) {
        _ = try await coder.encode(payload(), passphrase: passphrase, iterations: tooMany)
    }
}

@Test func anInconsistentPayloadIsRefused() async throws {
    await #expect(throws: ArchiveEncodingError.emptyPassphrase) {
        _ = try await coder.encode(payload(), passphrase: [], iterations: testIterations)
    }
    await #expect(throws: ArchiveEncodingError.duplicateBaselineMode(.quickTest)) {
        _ = try await encoded(payload(baselines: [.fixture(mode: .quickTest), .fixture(mode: .quickTest)]))
    }

    let unaccepted = try UserProfile(
        id: UUID(), amputationLevel: .transtibial, side: .left, timeSinceAmputationMonths: 12,
        disclaimerAcceptedAt: .distantPast, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    await #expect(throws: ArchiveEncodingError.disclaimerNotAccepted) {
        _ = try await encoded(payload(profile: unaccepted))
    }

    let session = GaitSession.fixtureValid()
    await #expect(throws: ArchiveEncodingError.duplicateSessionID) {
        _ = try await encoded(payload(sessions: [session, session]))
    }
}

@Test func aNonceCollisionIsRefusedRatherThanWritten() async throws {
    let repeating = SecureArchiveCoder(
        encryption: AESGCMEncryptionService(randomSource: RepeatingRandomSource()),
        minimumEncodeIterations: 1
    )
    await #expect(throws: ArchiveEncodingError.nonceCollision) {
        _ = try await encoded(using: repeating)
    }
}

// MARK: - The file type

@Test func theFileTypeIsStabilyz() {
    #expect(ArchiveFormat.fileExtension == "stabilyz")
    #expect(ArchiveFormat.typeIdentifier == "com.adi.stabilyz.backup")
    #expect(ArchiveFormat.magic == Array("STBLYZ".utf8))
    #expect(ArchiveFormat.maximumIterations == 5_000_000)
    // The KDF floor must fit under the ceiling, or no export could be written.
    #expect(KeyDerivationPolicy.minimumIterations <= ArchiveFormat.maximumIterations)
}
