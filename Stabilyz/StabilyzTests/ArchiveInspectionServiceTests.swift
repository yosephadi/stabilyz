import CryptoKit
import Foundation
import Testing
@testable import Stabilyz

/// Restore ingestion: inspecting a picked export without touching anything
/// (Task 10.3.1, docs/13 §13.4, docs/15 §15.1).

// MARK: - Doubles

/// Counts derivations, so a test can prove a refusal cost none.
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

/// Real AES-GCM, counting opens. The key-check is opened without associated
/// data and the payload with the header as associated data, so the two can be
/// told apart.
private final class CountingEncryption: SymmetricEncryptionService, @unchecked Sendable {
    private let inner = AESGCMEncryptionService()
    let keyCheckOpens = Locked(0)
    let payloadOpens = Locked(0)

    func seal(_ plaintext: Data, using key: SymmetricKey, authenticating additionalData: Data?) throws -> EncryptedPayload {
        try inner.seal(plaintext, using: key, authenticating: additionalData)
    }

    func open(_ payload: EncryptedPayload, using key: SymmetricKey, authenticating additionalData: Data?) throws -> Data {
        if additionalData == nil {
            keyCheckOpens.withLock { $0 += 1 }
        } else {
            payloadOpens.withLock { $0 += 1 }
        }
        return try inner.open(payload, using: key, authenticating: additionalData)
    }
}

private final class QuietLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) { entries.withLock { $0.append(message) } }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// An inspector whose derivations and decryptions are counted.
private struct Probe {
    let kdf = CountingKeyDerivation()
    let encryption = CountingEncryption()
    let log = QuietLog()

    func inspector(maximumByteCount: Int = ArchiveInspectionService.maximumArchiveByteCount) -> ArchiveInspectionService {
        ArchiveInspectionService(
            coder: SecureArchiveCoder(keyDerivation: kdf, encryption: encryption, minimumEncodeIterations: 1),
            fileIO: FileManagerFileIO(),
            logService: log,
            maximumByteCount: maximumByteCount
        )
    }

    var derivations: Int { kdf.calls.withLock { $0 } }
    var keyCheckOpens: Int { encryption.keyCheckOpens.withLock { $0 } }
    var payloadOpens: Int { encryption.payloadOpens.withLock { $0 } }
}

// MARK: - Fixtures

private let passphrase = "correct horse battery"
/// Writes exports; separate from the probe so its counters see inspection only.
private let writer = SecureArchiveCoder(minimumEncodeIterations: 1)

private func exportPayload(prosthesis: String = "Ottobock C-Leg") -> ArchivePayload {
    ArchivePayload(
        profile: .fixture(prosthesisType: prosthesis),
        baselines: [.fixture(mode: .quickTest), .fixture(mode: .fullTest)],
        sessions: [
            GaitSession.fixtureValid(mode: .quickTest, startedAt: Date(timeIntervalSince1970: 1_700_000_000.25),
                                     score: .fixture(relativeIndex: 108), provisionalScore: .fixture(value: 71)),
            GaitSession.fixtureValid(mode: .fullTest, startedAt: Date(timeIntervalSince1970: 1_700_090_000))
        ],
        appVersion: "1.0 (7)",
        algorithmVersion: "1.0.0",
        exportedAt: Date(timeIntervalSince1970: 1_700_200_000)
    )
}

private func exportArchive(
    _ payload: ArchivePayload = exportPayload(),
    using coder: SecureArchiveCoder = writer
) async throws -> Data {
    try await coder.encode(payload, passphrase: PassphraseEncoding.bytes(from: passphrase), iterations: 1_000)
}

private func flipping(_ data: Data, at offset: Int) -> Data {
    var copy = data
    copy[copy.startIndex + offset] ^= 0x01
    return copy
}

private func rewritingHeader(of archive: Data, envelopeVersion: Int? = nil, iterations: Int? = nil) throws -> Data {
    let envelope = try ArchiveEnvelope.parse(archive)
    let h = envelope.header
    let forged = ArchiveHeader(
        envelopeVersion: envelopeVersion ?? h.envelopeVersion,
        cryptoSuite: h.cryptoSuite,
        schemaVersion: h.schemaVersion,
        algorithmVersion: h.algorithmVersion,
        iterations: iterations ?? h.iterations,
        salt: h.salt,
        keyCheck: h.keyCheck
    )
    return try forged.serialized() + envelope.payload.nonce + envelope.payload.ciphertext + envelope.payload.tag
}

/// A scratch directory for files a test picks.
private struct Scratch {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("InspectionTests-\(UUID().uuidString)", isDirectory: true)

    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func file(_ data: Data, named name: String = "Stabilyz-Backup-2027-01-15-080000.stabilyz") throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }
}

// MARK: - Staging a valid export

@Test func aValidExportIsStagedExactly() async throws {
    let probe = Probe()
    let original = exportPayload()

    let staged = try await probe.inspector().inspect(archiveData: try await exportArchive(original), passphrase: passphrase)

    #expect(staged.payload == original)
    #expect(staged.schemaVersion == 1)
    #expect(probe.keyCheckOpens == 1)
    #expect(probe.payloadOpens == 1)
}

@Test func aValidExportIsStagedFromThePickedFile() async throws {
    let scratch = Scratch()
    defer { scratch.tearDown() }
    let original = exportPayload()
    let url = try scratch.file(try await exportArchive(original))

    let staged = try await Probe().inspector().inspect(archiveAt: url, passphrase: passphrase)

    #expect(staged.payload == original)
    #expect(FileManager.default.fileExists(atPath: url.path), "inspection must not consume the picked file")
}

@Test func thePassphraseIsCanonicalizedExactlyAsExportDid() async throws {
    let archive = try await exportArchive()
    let staged = try await Probe().inspector().inspect(archiveData: archive, passphrase: "  correct horse battery \n")
    #expect(staged.payload.sessions.count == 2)
}

// MARK: - The passphrase is proven before the payload

@Test func aWrongPassphraseIsRejectedAtTheKeyCheckBeforeThePayloadIsOpened() async throws {
    let probe = Probe()
    let archive = try await exportArchive()

    await #expect(throws: ArchiveInspectionError.wrongPassphrase) {
        _ = try await probe.inspector().inspect(archiveData: archive, passphrase: "correct horse batterY")
    }
    #expect(probe.keyCheckOpens == 1)
    #expect(probe.payloadOpens == 0, "the payload was opened before the passphrase was proven")
}

@Test func aBlankPassphraseIsWrongWithoutDecryptingAnything() async throws {
    let probe = Probe()
    let archive = try await exportArchive()

    await #expect(throws: ArchiveInspectionError.wrongPassphrase) {
        _ = try await probe.inspector().inspect(archiveData: archive, passphrase: "   ")
    }
    #expect(probe.keyCheckOpens == 0)
    #expect(probe.payloadOpens == 0)
}

// MARK: - Damaged and tampered files

@Test func aTamperedHeaderIsAnInvalidArchive() async throws {
    let probe = Probe()
    // Byte 12 is the algorithm version: authenticated, and not a key input.
    let tampered = flipping(try await exportArchive(), at: 12)

    await #expect(throws: ArchiveInspectionError.invalidArchiveFormat) {
        _ = try await probe.inspector().inspect(archiveData: tampered, passphrase: passphrase)
    }
    // The passphrase was right, so this failed at the payload, not the key-check.
    #expect(probe.keyCheckOpens == 1)
    #expect(probe.payloadOpens == 1)
}

@Test func corruptCiphertextIsAnInvalidArchive() async throws {
    let archive = try await exportArchive()
    let inspector = Probe().inspector()

    for offset in [archive.count - 17, archive.count - 1] {
        await #expect(throws: ArchiveInspectionError.invalidArchiveFormat) {
            _ = try await inspector.inspect(archiveData: flipping(archive, at: offset), passphrase: passphrase)
        }
    }
}

@Test func aTruncatedFileIsAnInvalidArchive() async throws {
    let archive = try await exportArchive()
    let inspector = Probe().inspector()

    for length in [10, 50, 90, archive.count - 1] {
        await #expect(throws: ArchiveInspectionError.invalidArchiveFormat) {
            _ = try await inspector.inspect(archiveData: Data(archive.prefix(length)), passphrase: passphrase)
        }
    }
}

@Test func aFileThatIsNotAnExportIsSaidToBeNotAStabilyzBackup() async throws {
    let inspector = Probe().inspector()
    for data in [Data(), Data("%PDF-1.7".utf8), Data(repeating: 0xFF, count: 512)] {
        await #expect(throws: ArchiveInspectionError.notAStabilyzArchive) {
            _ = try await inspector.inspect(archiveData: data, passphrase: passphrase)
        }
    }
}

@Test func aFileThatCannotBeReadIsUnreadable() async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-backup-\(UUID().uuidString).stabilyz")
    await #expect(throws: ArchiveInspectionError.unreadableFile) {
        _ = try await Probe().inspector().inspect(archiveAt: missing, passphrase: passphrase)
    }
}

@Test func aFileTooLargeToBeAnExportIsRefusedBeforeItIsRead() async throws {
    let scratch = Scratch()
    defer { scratch.tearDown() }
    let probe = Probe()
    let archive = try await exportArchive()
    let small = probe.inspector(maximumByteCount: archive.count - 1)

    await #expect(throws: ArchiveInspectionError.invalidArchiveFormat) {
        _ = try await small.inspect(archiveData: archive, passphrase: passphrase)
    }
    await #expect(throws: ArchiveInspectionError.invalidArchiveFormat) {
        _ = try await small.inspect(archiveAt: try scratch.file(archive), passphrase: passphrase)
    }
    #expect(probe.derivations == 0)
}

// MARK: - Unsupported files

@Test func anIterationCountAboveTheCapIsRefusedBeforeAnyDerivation() async throws {
    let probe = Probe()
    let forged = try rewritingHeader(of: try await exportArchive(), iterations: 5_000_001)

    await #expect(throws: ArchiveInspectionError.unsupportedIterationCount(5_000_001)) {
        _ = try await probe.inspector().inspect(archiveData: forged, passphrase: passphrase)
    }
    #expect(probe.derivations == 0)
    #expect(probe.keyCheckOpens == 0)
}

@Test func aNewerSchemaIsUnsupportedAfterDecryption() async throws {
    let future = SecureArchiveCoder(minimumEncodeIterations: 1, writtenSchemaVersion: 2)
    let archive = try await exportArchive(using: future)

    await #expect(throws: ArchiveInspectionError.unsupportedSchemaVersion(2)) {
        _ = try await Probe().inspector().inspect(archiveData: archive, passphrase: passphrase)
    }
}

@Test func aNewerEnvelopeIsUnsupported() async throws {
    let forged = try rewritingHeader(of: try await exportArchive(), envelopeVersion: 2)
    await #expect(throws: ArchiveInspectionError.unsupportedEnvelopeVersion(2)) {
        _ = try await Probe().inspector().inspect(archiveData: forged, passphrase: passphrase)
    }
}

// MARK: - Preflight

@Test func preflightAcceptsAValidExportWithoutDerivingOrDecrypting() async throws {
    let scratch = Scratch()
    defer { scratch.tearDown() }
    let probe = Probe()
    let archive = try await exportArchive()

    try await probe.inspector().preflight(archiveData: archive)
    try await probe.inspector().preflight(archiveAt: try scratch.file(archive))

    #expect(probe.derivations == 0)
    #expect(probe.keyCheckOpens == 0)
    #expect(probe.payloadOpens == 0)
}

@Test func preflightRefusesWhatCanBeRefusedWithoutAPassphrase() async throws {
    let archive = try await exportArchive()
    let inspector = Probe().inspector()

    await #expect(throws: ArchiveInspectionError.notAStabilyzArchive) {
        try await inspector.preflight(archiveData: Data("PK\u{03}\u{04}".utf8))
    }
    await #expect(throws: ArchiveInspectionError.invalidArchiveFormat) {
        try await inspector.preflight(archiveData: Data(archive.prefix(40)))
    }
    await #expect(throws: ArchiveInspectionError.unsupportedIterationCount(9_000_000)) {
        try await inspector.preflight(archiveData: try rewritingHeader(of: archive, iterations: 9_000_000))
    }
}

@Test func preflightDoesNotJudgeTheUnauthenticatedSchemaVersion() async throws {
    // A future-schema export passes preflight: its header's schema version is
    // only acted on after decryption has authenticated it [PRD order].
    let archive = try await exportArchive(using: SecureArchiveCoder(minimumEncodeIterations: 1, writtenSchemaVersion: 2))
    try await Probe().inspector().preflight(archiveData: archive)
}

// MARK: - Nothing local is touched

private struct StoreState: Equatable {
    let profile: UserProfile?
    let baselines: [Baseline?]
    let sessions: [[GaitSession]]
    let validCounts: [Int]
}

private func state(of store: InMemoryStore) async throws -> StoreState {
    var baselines: [Baseline?] = []
    var sessions: [[GaitSession]] = []
    var counts: [Int] = []
    for mode in TestMode.allCases {
        baselines.append(try await store.baselines.baseline(mode: mode))
        sessions.append(try await store.sessions.sessions(mode: mode, includeInvalid: true, limit: nil))
        counts.append(try await store.sessions.validSessionCount(mode: mode))
    }
    return StoreState(profile: try await store.profiles.fetchProfile(), baselines: baselines, sessions: sessions, validCounts: counts)
}

@Test func inspectingSucceedingOrFailingLeavesTheActiveStoreExactlyAsItWas() async throws {
    let store = try InMemoryStore()
    try await store.profiles.save(.fixture(prosthesisType: "Local profile"))
    try await store.baselines.save(.fixture(mode: .quickTest))
    for session in [
        GaitSession.fixtureValid(mode: .quickTest, startedAt: Date(timeIntervalSince1970: 1_690_000_000)),
        GaitSession.fixtureInvalid(mode: .fullTest, startedAt: Date(timeIntervalSince1970: 1_690_000_500))
    ] {
        try await store.sessions.save(session)
    }
    let before = try await state(of: store)

    // A different person's backup: nothing about it may reach the store.
    let archive = try await exportArchive(exportPayload(prosthesis: "Backup profile"))
    let inspector = Probe().inspector()

    let staged = try await inspector.inspect(archiveData: archive, passphrase: passphrase)
    #expect(staged.payload.profile.prosthesisType == "Backup profile")
    try await inspector.preflight(archiveData: archive)
    _ = try? await inspector.inspect(archiveData: archive, passphrase: "wrong passphrase")
    _ = try? await inspector.inspect(archiveData: flipping(archive, at: archive.count - 1), passphrase: passphrase)
    _ = try? await inspector.inspect(archiveData: Data("nope".utf8), passphrase: passphrase)

    let after = try await state(of: store)
    #expect(after == before)
    #expect(after.profile?.prosthesisType == "Local profile")
}

// MARK: - What the person is told

@Test func everyInspectionFailureHasCopyThatSaysNothingChanged() {
    let failures: [ArchiveInspectionError] = [
        .unreadableFile, .notAStabilyzArchive, .invalidArchiveFormat, .wrongPassphrase,
        .unsupportedSchemaVersion(2), .unsupportedEnvelopeVersion(2), .unsupportedIterationCount(9_000_000)
    ]
    for failure in failures {
        let presentation = ErrorPresenter.presentation(for: failure.stabilyzError)
        #expect(presentation != nil, "\(failure) has no copy")
        #expect(presentation?.reassuresDataUnchanged == true, "\(failure)")
        #expect(presentation?.message.contains("hasn't changed") == true, "\(failure)")
        // The mapping is lossless both ways.
        #expect(ArchiveInspectionError(failure.stabilyzError) == failure)
    }
}

@Test func theFailuresTheRestoreFlowMustTellApartReadDifferently() {
    let messages = [
        ArchiveInspectionError.wrongPassphrase, .invalidArchiveFormat, .unsupportedSchemaVersion(2), .unsupportedIterationCount(9_000_000)
    ].compactMap { ErrorPresenter.presentation(for: $0.stabilyzError)?.message }

    #expect(Set(messages).count == 4)
    #expect(ErrorPresenter.presentation(for: ArchiveInspectionError.unsupportedIterationCount(9_000_000).stabilyzError)?
        .message.contains("Update the app") == true)
}

@Test func theLogNeverCarriesThePassphrase() async throws {
    let probe = Probe()
    let archive = try await exportArchive()

    _ = try await probe.inspector().inspect(archiveData: archive, passphrase: passphrase)
    _ = try? await probe.inspector().inspect(archiveData: archive, passphrase: "wrong horse battery")

    let lines = probe.log.entries.withLock { $0 }
    #expect(lines.contains { $0.contains("restore inspection passed") })
    #expect(lines.allSatisfy { !$0.contains("horse") })
}
