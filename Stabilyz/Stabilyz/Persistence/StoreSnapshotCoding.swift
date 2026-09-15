import CryptoKit
import Foundation

/// The on-disk form of a pre-restore store snapshot (docs/13 §13.5 steps 2
/// and 4, Task 10.3.5).
///
/// **Every row, in the store's own format.** Unlike the export archive, which
/// can hold valid sessions only, a snapshot has to put the store back exactly —
/// invalid sessions included. So rows are written as the entity columns
/// `EntityMapping` produces and read back through `EntityMapping`, and a row the
/// store itself could not have held is refused the same way a bad store row is.
///
/// **Damage is detected, not guessed at.** The body carries a SHA-256 digest; a
/// truncated, edited or bit-flipped snapshot fails to decode rather than
/// becoming a plausible-looking store.
///
/// Not an interchange format and never leaves the device: it lives only
/// between the start of a restore and its verified end.
enum StoreSnapshotCoding {
    static let formatVersion = 1

    enum DecodingError: Error, Equatable {
        /// Not JSON of the expected shape — truncated or not a snapshot.
        case malformed
        case unsupportedFormat(Int)
        /// The body is not what was written.
        case digestMismatch
        /// A row the store could not have held.
        case invalidRow
    }

    static func encode(_ contents: StoreContents, createdAt: Date) throws -> Data {
        let body = SnapshotBody(
            profile: contents.profile.map { ProfileRow(EntityMapping.entity(from: $0)) },
            baselines: try contents.baselines.map { BaselineRow(try EntityMapping.entity(from: $0)) },
            sessions: try contents.sessions.map { SessionRow(try EntityMapping.entity(from: $0)) }
        )
        let bodyData = try encoder().encode(body)
        let file = SnapshotFile(
            formatVersion: formatVersion,
            createdAt: createdAt,
            bodySHA256: sha256Hex(bodyData),
            body: bodyData
        )
        return try encoder().encode(file)
    }

    static func decode(_ data: Data) throws -> StoreContents {
        guard let file = try? JSONDecoder().decode(SnapshotFile.self, from: data) else {
            throw DecodingError.malformed
        }
        guard file.formatVersion == formatVersion else {
            throw DecodingError.unsupportedFormat(file.formatVersion)
        }
        guard sha256Hex(file.body) == file.bodySHA256 else {
            throw DecodingError.digestMismatch
        }
        guard let body = try? JSONDecoder().decode(SnapshotBody.self, from: file.body) else {
            throw DecodingError.malformed
        }

        do {
            return StoreContents(
                profile: try body.profile.map { try EntityMapping.profile(from: $0.entity()) },
                baselines: try body.baselines.map { try EntityMapping.baseline(from: $0.entity()) },
                sessions: try body.sessions.map { try EntityMapping.session(from: $0.entity()) }
            )
        } catch {
            throw DecodingError.invalidRow
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - File shape

private struct SnapshotFile: Codable {
    let formatVersion: Int
    let createdAt: Date
    let bodySHA256: String
    let body: Data
}

private struct SnapshotBody: Codable {
    let profile: ProfileRow?
    let baselines: [BaselineRow]
    let sessions: [SessionRow]
}

/// `UserProfileEntity`'s columns.
private struct ProfileRow: Codable {
    let id: UUID
    let amputationLevel: String
    let side: String
    let timeSinceAmputationMonths: Int
    let prosthesisType: String?
    let kLevel: String?
    let disclaimerAcceptedAt: Date
    let createdAt: Date

    init(_ entity: UserProfileEntity) {
        id = entity.id
        amputationLevel = entity.amputationLevel
        side = entity.side
        timeSinceAmputationMonths = entity.timeSinceAmputationMonths
        prosthesisType = entity.prosthesisType
        kLevel = entity.kLevel
        disclaimerAcceptedAt = entity.disclaimerAcceptedAt
        createdAt = entity.createdAt
    }

    func entity() -> UserProfileEntity {
        UserProfileEntity(
            id: id,
            amputationLevel: amputationLevel,
            side: side,
            timeSinceAmputationMonths: timeSinceAmputationMonths,
            prosthesisType: prosthesisType,
            kLevel: kLevel,
            disclaimerAcceptedAt: disclaimerAcceptedAt,
            createdAt: createdAt
        )
    }
}

/// `BaselineEntity`'s columns, payload blob included.
private struct BaselineRow: Codable {
    let id: UUID
    let mode: String
    let cadenceBPM: Double
    let establishedAt: Date
    let algorithmVersion: String
    let payload: Data

    init(_ entity: BaselineEntity) {
        id = entity.id
        mode = entity.mode
        cadenceBPM = entity.cadenceBPM
        establishedAt = entity.establishedAt
        algorithmVersion = entity.algorithmVersion
        payload = entity.payload
    }

    func entity() -> BaselineEntity {
        BaselineEntity(
            id: id,
            mode: mode,
            cadenceBPM: cadenceBPM,
            establishedAt: establishedAt,
            algorithmVersion: algorithmVersion,
            payload: payload
        )
    }
}

/// `GaitSessionEntity`'s columns, payload blob included.
private struct SessionRow: Codable {
    let id: UUID
    let mode: String
    let startedAt: Date
    let validity: String
    let relativeIndex: Int?
    let algorithmVersion: String
    let payload: Data

    init(_ entity: GaitSessionEntity) {
        id = entity.id
        mode = entity.mode
        startedAt = entity.startedAt
        validity = entity.validity
        relativeIndex = entity.relativeIndex
        algorithmVersion = entity.algorithmVersion
        payload = entity.payload
    }

    func entity() -> GaitSessionEntity {
        GaitSessionEntity(
            id: id,
            mode: mode,
            startedAt: startedAt,
            validity: validity,
            relativeIndex: relativeIndex,
            algorithmVersion: algorithmVersion,
            payload: payload
        )
    }
}
