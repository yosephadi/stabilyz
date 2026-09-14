import Foundation

/// File-system access, injected so export/restore work runs against a temp
/// sandbox in tests (docs/12 §12.2).
///
/// Used for export archives and the recorder's scratch file (docs/06 §6.1, §6.4).
protocol FileIO: Sendable {
    func temporaryDirectory() -> URL

    func fileExists(at url: URL) -> Bool
    func read(from url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func remove(at url: URL) throws

    /// Writes under complete data protection: the file is unreadable while
    /// the device is locked (docs/18 — temporary files). For export archives,
    /// which are written and shared in the foreground. **Not** for the
    /// recorder's scratch file, which is written in a locked pocket.
    func writeProtected(_ data: Data, to url: URL) throws

    /// Creates the directory and any missing parents.
    func createDirectory(at url: URL) throws

    /// The directory's immediate contents; empty when it does not exist.
    func contentsOfDirectory(at url: URL) throws -> [URL]

    /// Used for the pre-restore store snapshot (docs/13 §13.5 step 2).
    func copyItem(at source: URL, to destination: URL) throws
}
