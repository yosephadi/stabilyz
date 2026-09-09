import Foundation
import Testing
@testable import Stabilyz

private let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 1_000)

private func sample(_ offset: Double) -> SensorSample {
    SensorSample(
        deviceTimestamp: anchor.uptime + offset,
        anchor: anchor,
        acceleration: Vector3(x: offset, y: -offset, z: 1),
        gravity: Vector3(x: 0, y: 0, z: -1)
    )
}

private final class SilentBufferLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// Fails every write, to prove a disk problem does not cost samples.
private struct UnwritableFileIO: FileIO {
    struct Failure: Error {}
    let inner = FileManagerFileIO()

    func temporaryDirectory() -> URL { inner.temporaryDirectory() }
    func fileExists(at url: URL) -> Bool { false }
    func read(from url: URL) throws -> Data { throw Failure() }
    func write(_ data: Data, to url: URL) throws { throw Failure() }
    func remove(at url: URL) throws {}
    func copyItem(at source: URL, to destination: URL) throws { throw Failure() }
}

private func makeBuffer(capacity: Int = 4, fileIO: FileIO = FileManagerFileIO()) -> SessionSampleBuffer {
    SessionSampleBuffer(fileIO: fileIO, logService: SilentBufferLog(), capacity: capacity)
}

// MARK: - In-memory behaviour

@Test func aSmallSessionNeverTouchesDisk() {
    let buffer = makeBuffer(capacity: 100)
    for index in 0..<10 { buffer.append(sample(Double(index) / 100)) }

    #expect(buffer.count == 10)
    #expect(buffer.isSpilling == false)
    #expect(buffer.freeze(anchor: anchor).count == 10)
}

@Test func freezingReturnsSamplesInAcquisitionOrder() {
    let buffer = makeBuffer(capacity: 3)
    let offsets = (0..<10).map { Double($0) / 100 }
    for offset in offsets { buffer.append(sample(offset)) }

    let frozen = buffer.freeze(anchor: anchor)

    #expect(frozen.count == 10)
    #expect(frozen.map(\.deviceTimestamp) == offsets.map { anchor.uptime + $0 })
}

// MARK: - Spilling

@Test func exceedingCapacitySpillsToScratchAndKeepsEverySample() {
    // docs/14 §14.3: a bounded buffer must never drop the irreplaceable data.
    let buffer = makeBuffer(capacity: 4)
    for index in 0..<13 { buffer.append(sample(Double(index) / 100)) }

    #expect(buffer.isSpilling)
    #expect(buffer.count == 13)

    let frozen = buffer.freeze(anchor: anchor)
    #expect(frozen.count == 13)
    #expect(frozen.map(\.deviceTimestamp) == (0..<13).map { anchor.uptime + Double($0) / 100 })
}

@Test func spilledSamplesSurviveTheRoundTripIntact() {
    let buffer = makeBuffer(capacity: 2)
    for index in 0..<6 { buffer.append(sample(Double(index) / 100)) }

    let frozen = buffer.freeze(anchor: anchor)

    #expect(frozen.count == 6)
    // Acceleration and gravity survive the encode/decode, not just timestamps.
    #expect(frozen[3].acceleration == Vector3(x: 0.03, y: -0.03, z: 1))
    #expect(frozen[3].gravity == Vector3(x: 0, y: 0, z: -1))
    // Every sample carries the session anchor it was frozen against.
    #expect(frozen.allSatisfy { $0.anchor == anchor })
}

// MARK: - Scratch lifetime (docs/06 §6.4)

@Test func theScratchFileIsDeletedOnFreeze() {
    let fileIO = FileManagerFileIO()
    let name = "test-\(UUID().uuidString).ndjson"
    let url = fileIO.temporaryDirectory().appendingPathComponent(name)
    let buffer = SessionSampleBuffer(fileIO: fileIO, logService: SilentBufferLog(), capacity: 2, scratchName: name)

    for index in 0..<6 { buffer.append(sample(Double(index) / 100)) }
    #expect(fileIO.fileExists(at: url))

    _ = buffer.freeze(anchor: anchor)
    // Raw samples never outlive the session.
    #expect(fileIO.fileExists(at: url) == false)
}

@Test func discardingAlsoRemovesTheScratchFile() {
    let fileIO = FileManagerFileIO()
    let name = "test-\(UUID().uuidString).ndjson"
    let url = fileIO.temporaryDirectory().appendingPathComponent(name)
    let buffer = SessionSampleBuffer(fileIO: fileIO, logService: SilentBufferLog(), capacity: 2, scratchName: name)

    for index in 0..<6 { buffer.append(sample(Double(index) / 100)) }
    buffer.discard()

    #expect(fileIO.fileExists(at: url) == false)
    #expect(buffer.count == 0)
}

@Test func aBufferIsReusableAfterFreezing() {
    let buffer = makeBuffer(capacity: 2)
    for index in 0..<6 { buffer.append(sample(Double(index) / 100)) }
    _ = buffer.freeze(anchor: anchor)

    #expect(buffer.count == 0)
    buffer.append(sample(9))
    #expect(buffer.freeze(anchor: anchor).count == 1)
}

// MARK: - Degradation

@Test func aFailedSpillHoldsSamplesInMemoryRatherThanLosingThem() {
    // A disk problem must degrade the buffer, never discard the recording.
    let log = SilentBufferLog()
    let buffer = SessionSampleBuffer(
        fileIO: UnwritableFileIO(),
        logService: log,
        capacity: 2
    )

    for index in 0..<8 { buffer.append(sample(Double(index) / 100)) }

    #expect(buffer.count == 8)
    #expect(buffer.isSpilling == false)
    #expect(buffer.freeze(anchor: anchor).count == 8)
    #expect(log.entries.withLock { $0.contains { $0.contains("scratch spill failed") } })
}
