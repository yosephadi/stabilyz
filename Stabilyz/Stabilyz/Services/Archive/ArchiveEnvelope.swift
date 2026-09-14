import Foundation

/// The plaintext header: everything needed to derive the key and check it
/// (docs/13 §13.1).
///
/// Wire layout, big-endian:
///
/// ```
/// magic "STBLYZ"            6
/// envelopeVersion           u16
/// cryptoSuite               u8
/// schemaVersion             u16   ─ read only after decryption [PRD]
/// algorithmVersion length   u8
/// algorithmVersion (UTF-8)  1…64
/// iterations                u32   ─ capped before any derivation
/// salt length               u8
/// salt                      16…64
/// key-check nonce           12
/// key-check ciphertext      16
/// key-check tag             16
/// ─── the bytes above are the payload's associated data ───
/// payload nonce             12
/// payload ciphertext        …
/// payload tag               16
/// ```
///
/// **Every header byte is authenticated.** The bytes above the line are the
/// payload seal's associated data, and the payload nonce is authenticated by
/// GCM itself, so no field can be edited without the payload failing to open.
/// That is what makes the plaintext `schemaVersion` safe to act on once
/// decryption has succeeded.
struct ArchiveHeader: Equatable, Sendable {
    let envelopeVersion: Int
    let cryptoSuite: Int
    let schemaVersion: Int
    let algorithmVersion: String
    let iterations: Int
    let salt: [UInt8]
    let keyCheck: EncryptedPayload

    /// The authenticated header bytes.
    ///
    /// Checks only that each field fits its wire width. Policy — the
    /// iteration ceiling, supported versions — is the parser's and the
    /// encoder's to enforce, so a test can still build a header that breaks it.
    func serialized() throws -> Data {
        let algorithmBytes = Array(algorithmVersion.utf8)
        guard (0...Int(UInt16.max)).contains(envelopeVersion),
              (0...Int(UInt8.max)).contains(cryptoSuite),
              (0...Int(UInt16.max)).contains(schemaVersion),
              (1...Int(UInt8.max)).contains(algorithmBytes.count),
              (0...Int(UInt32.max)).contains(iterations),
              (1...Int(UInt8.max)).contains(salt.count),
              keyCheck.nonce.count == EncryptionPolicy.nonceByteCount,
              keyCheck.ciphertext.count == ArchiveFormat.keyCheckPlaintext.count,
              keyCheck.tag.count == EncryptionPolicy.tagByteCount
        else { throw ArchiveEncodingError.headerNotRepresentable }

        var data = Data(ArchiveFormat.magic)
        data.appendBigEndian(UInt16(envelopeVersion))
        data.append(UInt8(cryptoSuite))
        data.appendBigEndian(UInt16(schemaVersion))
        data.append(UInt8(algorithmBytes.count))
        data.append(contentsOf: algorithmBytes)
        data.appendBigEndian(UInt32(iterations))
        data.append(UInt8(salt.count))
        data.append(contentsOf: salt)
        data.append(keyCheck.nonce)
        data.append(keyCheck.ciphertext)
        data.append(keyCheck.tag)
        return data
    }
}

/// A whole export file, split into its parts without decrypting anything.
struct ArchiveEnvelope: Equatable, Sendable {
    let header: ArchiveHeader
    /// The header exactly as it appeared in the file — the payload's
    /// associated data. Kept as read rather than re-serialized, so a header
    /// that parses the same but was written differently still fails to open.
    let authenticatedHeader: Data
    let payload: EncryptedPayload

    var serialized: Data {
        authenticatedHeader + payload.nonce + payload.ciphertext + payload.tag
    }

    /// Parses the envelope. **No key derivation and no decryption happen
    /// here** — this is docs/13 §13.4 step 2, and the iteration ceiling is
    /// enforced before the caller can spend a single PBKDF2 round.
    ///
    /// - Throws: `StabilyzError.archiveImport(.notAStabilyzArchive)` without
    ///   the magic; `.schemaCompatibility(.unsupportedEnvelope)` for an envelope
    ///   or crypto suite this build does not read; `.archiveImport(
    ///   .corruptedArchive)` for anything truncated, malformed or outside the
    ///   format's limits.
    static func parse(_ data: Data) throws -> ArchiveEnvelope {
        var reader = ByteReader(data)

        guard let magic = reader.readIfAvailable(ArchiveFormat.magic.count), magic == ArchiveFormat.magic else {
            throw StabilyzError.archiveImport(.notAStabilyzArchive)
        }

        let envelopeVersion = Int(try reader.uint16())
        guard envelopeVersion == ArchiveFormat.envelopeVersion else {
            throw StabilyzError.schemaCompatibility(.unsupportedEnvelope(version: envelopeVersion))
        }
        let cryptoSuite = Int(try reader.uint8())
        guard cryptoSuite == ArchiveFormat.cryptoSuite else {
            throw StabilyzError.schemaCompatibility(.unsupportedEnvelope(version: envelopeVersion))
        }

        let schemaVersion = Int(try reader.uint16())

        let algorithmLength = Int(try reader.uint8())
        guard (1...ArchiveFormat.maximumAlgorithmVersionByteCount).contains(algorithmLength),
              let algorithmVersion = String(bytes: try reader.read(algorithmLength), encoding: .utf8)
        else { throw ByteReader.corrupted }

        let iterations = Int(try reader.uint32())
        guard (1...ArchiveFormat.maximumIterations).contains(iterations) else {
            throw ByteReader.corrupted
        }

        let saltLength = Int(try reader.uint8())
        guard (KeyDerivationPolicy.saltByteCount...ArchiveFormat.maximumSaltByteCount).contains(saltLength) else {
            throw ByteReader.corrupted
        }
        let salt = try reader.read(saltLength)

        let keyCheck = EncryptedPayload(
            nonce: Data(try reader.read(EncryptionPolicy.nonceByteCount)),
            ciphertext: Data(try reader.read(ArchiveFormat.keyCheckPlaintext.count)),
            tag: Data(try reader.read(EncryptionPolicy.tagByteCount))
        )
        let authenticatedHeader = Data(data.prefix(reader.offset))

        let payloadNonce = Data(try reader.read(EncryptionPolicy.nonceByteCount))
        let body = try reader.readRemaining()
        guard body.count >= EncryptionPolicy.tagByteCount else { throw ByteReader.corrupted }

        return ArchiveEnvelope(
            header: ArchiveHeader(
                envelopeVersion: envelopeVersion,
                cryptoSuite: cryptoSuite,
                schemaVersion: schemaVersion,
                algorithmVersion: algorithmVersion,
                iterations: iterations,
                salt: salt,
                keyCheck: keyCheck
            ),
            authenticatedHeader: authenticatedHeader,
            payload: EncryptedPayload(
                nonce: payloadNonce,
                ciphertext: Data(body.dropLast(EncryptionPolicy.tagByteCount)),
                tag: Data(body.suffix(EncryptionPolicy.tagByteCount))
            )
        )
    }
}

/// Bounds-checked sequential reads. Every overrun is a corrupted archive.
private struct ByteReader {
    static let corrupted = StabilyzError.archiveImport(.corruptedArchive)

    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    mutating func read(_ count: Int) throws -> [UInt8] {
        guard let slice = readIfAvailable(count) else { throw Self.corrupted }
        return slice
    }

    mutating func readIfAvailable(_ count: Int) -> [UInt8]? {
        guard count >= 0, bytes.count - offset >= count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func readRemaining() throws -> [UInt8] {
        try read(bytes.count - offset)
    }

    mutating func uint8() throws -> UInt8 {
        try read(1)[0]
    }

    mutating func uint16() throws -> UInt16 {
        let b = try read(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    mutating func uint32() throws -> UInt32 {
        let b = try read(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}
