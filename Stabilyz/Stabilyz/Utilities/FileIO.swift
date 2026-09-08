import Foundation

/// File-system access, injected so export/restore work runs against a temp
/// sandbox in tests (docs/12 §12.2).
///
/// Used for export archives and the recorder's scratch file (docs/06 §6.1, §6.4).
nonisolated protocol FileIO: Sendable {
    func temporaryDirectory() -> URL

    func fileExists(at url: URL) -> Bool
    func read(from url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func remove(at url: URL) throws

    /// Used for the pre-restore store snapshot (docs/13 §13.5 step 2).
    func copyItem(at source: URL, to destination: URL) throws
}
