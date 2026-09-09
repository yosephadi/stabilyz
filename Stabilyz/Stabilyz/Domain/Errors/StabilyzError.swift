/// The single error taxonomy (docs/15 §15.1).
///
/// Thrown from services and domain code, and translated at the view-model
/// boundary by `ErrorPresenter`. Technical detail is carried for logging and is
/// **never shown to the user** [PRD rule: do not expose technical errors].
nonisolated enum StabilyzError: Error, Equatable {
    case permission(Permission)
    case sensor(Sensor)
    case recording(Recording)
    case processing(Processing)
    case persistence(Persistence)
    case export(Export)
    case archiveImport(ArchiveImport)
    case schemaCompatibility(SchemaCompatibility)
    case audio(Audio)
    case crypto(Crypto)

    /// Motion & Fitness authorization (docs/15 §15.1).
    nonisolated enum Permission: Equatable {
        case motionDenied
        case motionRestricted
    }

    /// Sensor availability and lifecycle (docs/07 §7.3, §7.6).
    nonisolated enum Sensor: Equatable {
        case unavailable
        case primingTimeout
        case midSessionFailure
    }

    /// Interruption and gap outcomes (docs/07 §7.7).
    nonisolated enum Recording: Equatable {
        case unrecoverableInterruption
    }

    /// Pipeline validity outcomes (docs/08 stages 3-5).
    nonisolated enum Processing: Equatable {
        case noWalkingDetected
        case insufficientValidWalking
        case tooFewStrides
        case excessiveNoise
        /// A cancelled run marks the session invalid rather than half-processed
        /// (docs/14 §14.3).
        case cancelled
    }

    nonisolated enum Persistence: Equatable {
        case saveFailed
        case storeCorruption
    }

    nonisolated enum Export: Equatable {
        case keyDerivationFailed
        case fileWriteFailed
        case shareFailed
    }

    /// Import failures. The key-check value is what lets a wrong passphrase be
    /// distinguished from a corrupted file [PRD; docs/13 §13.4].
    nonisolated enum ArchiveImport: Equatable {
        case wrongPassphrase
        case corruptedArchive
        case notAStabilyzArchive
    }

    nonisolated enum SchemaCompatibility: Equatable {
        case futureSchema(version: Int)
        case unsupportedEnvelope(version: Int)
    }

    nonisolated enum Audio: Equatable {
        case routeLost
        case interrupted
        case engineFailure
    }

    nonisolated enum Crypto: Equatable {
        case tagVerificationFailed
        case randomGenerationFailed
    }

    /// Category name for logging (docs/20). Carries no values.
    var logCategory: LogCategory {
        switch self {
        case .permission, .sensor, .recording: .session
        case .processing: .processing
        case .persistence: .persistence
        case .export, .archiveImport, .schemaCompatibility: .backup
        case .audio: .audio
        case .crypto: .backup
        }
    }

    /// Technical description for the log only — never surfaced to the user
    /// (docs/15 §15.1). Contains no passphrases, keys, or metric values.
    var technicalDescription: String {
        switch self {
        case .permission(let error): "permission.\(error)"
        case .sensor(let error): "sensor.\(error)"
        case .recording(let error): "recording.\(error)"
        case .processing(let error): "processing.\(error)"
        case .persistence(let error): "persistence.\(error)"
        case .export(let error): "export.\(error)"
        case .archiveImport(let error): "import.\(error)"
        case .schemaCompatibility(let error): "schema.\(error)"
        case .audio(let error): "audio.\(error)"
        case .crypto(let error): "crypto.\(error)"
        }
    }
}
