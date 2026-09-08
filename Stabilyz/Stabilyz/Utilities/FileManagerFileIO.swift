import Foundation

/// Production `FileIO` over `FileManager` (docs/12 §12.2).
///
/// Used for export archives, the recorder scratch file, and the pre-restore
/// store snapshot (docs/06 §6.1, docs/13 §13.5).
nonisolated struct FileManagerFileIO: FileIO {
    private let fileManager: FileManager

    /// `FileManager.default` is thread-safe for the operations used here.
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

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
