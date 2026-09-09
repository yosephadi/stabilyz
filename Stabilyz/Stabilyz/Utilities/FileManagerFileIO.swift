import Foundation

/// Production `FileIO` over `FileManager` (docs/12 §12.2).
///
/// Used for export archives, the recorder scratch file, and the pre-restore
/// store snapshot (docs/06 §6.1, docs/13 §13.5).
struct FileManagerFileIO: FileIO {
    /// `FileManager` is not `Sendable`, so it is not stored. `FileManager.default`
    /// is documented as thread-safe for the operations used here, and reaching
    /// for it per call keeps this type trivially `Sendable`.
    private var fileManager: FileManager { .default }

    init() {}

    func temporaryDirectory() -> URL {
        fileManager.temporaryDirectory
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        // Atomic so a crash mid-write cannot leave a half-written archive.
        try data.write(to: url, options: .atomic)
    }

    func remove(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try fileManager.copyItem(at: source, to: destination)
    }
}
