import Foundation

/// The payload schema's forward migration chain (docs/13 §13.6).
///
/// Each step takes a decrypted document written at schema N and returns it
/// as schema N + 1. Steps run in sequence, so an archive from any supported
/// older version reaches the current one through every intermediate shape
/// [PRD: "so a future app version can correctly decrypt and migrate an older
/// export"].
///
/// v1 is the first schema, so production has no steps yet. The first schema
/// change adds `steps[1]`.
struct ArchiveMigrations: Sendable {
    typealias Step = @Sendable (Data) throws -> Data

    /// Keyed by the version a step migrates *from*.
    let steps: [Int: Step]

    static let production = ArchiveMigrations(steps: [:])

    /// - Throws: `StabilyzError.archiveImport(.corruptedArchive)` when a step
    ///   in the chain is missing — a version this build claims to read but
    ///   cannot reach is not a file it can restore.
    func migrate(_ document: Data, from version: Int, to target: Int) throws -> Data {
        var data = document
        var current = version
        while current < target {
            guard let step = steps[current] else {
                throw StabilyzError.archiveImport(.corruptedArchive)
            }
            data = try step(data)
            current += 1
        }
        return data
    }
}
