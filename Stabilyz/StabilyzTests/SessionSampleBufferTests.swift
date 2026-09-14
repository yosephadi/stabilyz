import Foundation
import Testing
@testable import Stabilyz

private let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 1_000)

private func sample(_ offset: Double) -> SensorSample {
    // Acceleration carries the offset as written, not as recovered from the
    // timestamp: `(1000 + 0.03) - 1000` is not `0.03`, and these values are
    // asserted on exactly by the round-trip test.
    SensorSample(
        deviceTimestamp: anchor.uptime + offset,
        anchor: anchor,
        acceleration: Vector3(x: offset, y: -offset, z: 1),
        gravity: Vector3(x: 0, y: 0, z: -1)
    )
}

/// A sample at an exact device timestamp, for the boundary cases — see the note
/// in `SampleAdmissionTests` on why `nextDown` rather than `.ulpOfOne`.
private func sampleAt(_ timestamp: TimeInterval) -> SensorSample {
    SensorSample(
        deviceTimestamp: timestamp,
        anchor: anchor,
        acceleration: Vector3(x: 1, y: -1, z: 1),
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
    func writeProtected(_ data: Data, to url: URL) throws { throw Failure() }
    func createDirectory(at url: URL) throws { throw Failure() }
    func contentsOfDirectory(at url: URL) throws -> [URL] { [] }
}

/// Armed at the shared anchor by default: every test below that is about
/// capacity, spilling or scratch lifetime assumes an open buffer, and the
/// admission gate has its own section at the end.
private func makeBuffer(
    capacity: Int = 4,
    fileIO: FileIO = FileManagerFileIO(),
    armed: Bool = true
) -> SessionSampleBuffer {
    let buffer = SessionSampleBuffer(fileIO: fileIO, logService: SilentBufferLog(), capacity: capacity)
    if armed { buffer.arm(at: anchor) }
    return buffer
}

// MARK: - In-memory behaviour

@Test func aSmallSessionNeverTouchesDisk() {
    let buffer = makeBuffer(capacity: 100)
    for index in 0..<10 { buffer.append(sample(Double(index) / 100)) }

    #expect(buffer.count == 10)
    #expect(buffer.isSpilling == false)
    #expect(buffer.freeze().count == 10)
}

@Test func freezingReturnsSamplesInAcquisitionOrder() {
    let buffer = makeBuffer(capacity: 3)
    let offsets = (0..<10).map { Double($0) / 100 }
    for offset in offsets { buffer.append(sample(offset)) }

    let frozen = buffer.freeze()

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

    let frozen = buffer.freeze()
    #expect(frozen.count == 13)
    #expect(frozen.map(\.deviceTimestamp) == (0..<13).map { anchor.uptime + Double($0) / 100 })
}

@Test func spilledSamplesSurviveTheRoundTripIntact() {
    let buffer = makeBuffer(capacity: 2)
    for index in 0..<6 { buffer.append(sample(Double(index) / 100)) }

    let frozen = buffer.freeze()

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
    buffer.arm(at: anchor)

    for index in 0..<6 { buffer.append(sample(Double(index) / 100)) }
    #expect(fileIO.fileExists(at: url))

    _ = buffer.freeze()
    // Raw samples never outlive the session.
    #expect(fileIO.fileExists(at: url) == false)
}

@Test func discardingAlsoRemovesTheScratchFile() {
    let fileIO = FileManagerFileIO()
    let name = "test-\(UUID().uuidString).ndjson"
    let url = fileIO.temporaryDirectory().appendingPathComponent(name)
    let buffer = SessionSampleBuffer(fileIO: fileIO, logService: SilentBufferLog(), capacity: 2, scratchName: name)
    buffer.arm(at: anchor)

    for index in 0..<6 { buffer.append(sample(Double(index) / 100)) }
    buffer.discard()

    #expect(fileIO.fileExists(at: url) == false)
    #expect(buffer.count == 0)
}

@Test func aBufferIsReusableAfterFreezingOnceItIsArmedAgain() {
    let buffer = makeBuffer(capacity: 2)
    for index in 0..<6 { buffer.append(sample(Double(index) / 100)) }
    _ = buffer.freeze()

    #expect(buffer.count == 0)
    // Freezing disarmed it: T-0 belongs to the session that just ended.
    #expect(buffer.isArmed == false)

    buffer.arm(at: anchor)
    buffer.append(sample(9))
    #expect(buffer.freeze().count == 1)
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
    buffer.arm(at: anchor)

    for index in 0..<8 { buffer.append(sample(Double(index) / 100)) }

    #expect(buffer.count == 8)
    #expect(buffer.isSpilling == false)
    #expect(buffer.freeze().count == 8)
    #expect(log.entries.withLock { $0.contains { $0.contains("scratch spill failed") } })
}

// MARK: - The T-0 admission gate ([PRD OQ-6], docs/07 §7.3)

@Test func anUnarmedBufferAdmitsNothing() {
    // Sensors can be delivering before a session exists — priming runs inside
    // the countdown. Until T-0 is known there is nothing for a sample to
    // belong to, so it is dropped rather than held on speculation.
    let buffer = makeBuffer(capacity: 100, armed: false)

    #expect(buffer.isArmed == false)
    for index in 0..<10 { #expect(buffer.append(sample(Double(index) / 100)) == false) }

    #expect(buffer.count == 0)
    #expect(buffer.rejectedSampleCount == 10)
    #expect(buffer.freeze().isEmpty)
}

@Test func samplesFromBeforeT0AreDroppedAtAdmission() {
    let buffer = makeBuffer(capacity: 100)

    // Five seconds of countdown lead-in, then the walk.
    for offset in stride(from: -5.0, to: 0, by: 0.01) {
        #expect(buffer.append(sample(offset)) == false)
    }
    for index in 0..<10 { #expect(buffer.append(sample(Double(index) / 100))) }

    #expect(buffer.count == 10)
    #expect(buffer.rejectedSampleCount == 500)
}

@Test func theFirstAdmittedSampleIsAtOrAfterT0() {
    let buffer = makeBuffer(capacity: 3)

    for offset in [-2.0, -1.5, -0.01, 0.0, 0.01, 0.02] { buffer.append(sample(offset)) }

    let frozen = buffer.freeze()
    #expect(frozen.isEmpty == false)
    // The contract, stated as the contract: nothing here predates the session.
    #expect(frozen.allSatisfy { $0.deviceTimestamp >= anchor.uptime })
    #expect(frozen.first?.deviceTimestamp == anchor.uptime)
}

@Test func aSampleExactlyAtT0IsAdmitted() {
    // The boundary is closed on the session's side: an exact hit is the first
    // sample of the walk, not the last of the countdown.
    let buffer = makeBuffer(capacity: 100)

    #expect(buffer.append(sample(0)))
    #expect(buffer.count == 1)
    #expect(buffer.rejectedSampleCount == 0)
}

@Test func theSampleImmediatelyBeforeT0IsNot() {
    let buffer = makeBuffer(capacity: 100)

    #expect(buffer.append(sampleAt(anchor.uptime.nextDown)) == false)
    #expect(buffer.count == 0)
    #expect(buffer.rejectedSampleCount == 1)
}

@Test func admissionIsDeterministicAcrossRepeatedRuns() {
    // Same offsets, same verdicts, every time — no float comparison luck at
    // the boundary.
    let offsets = [-0.02, -0.01, 0.0, 0.01, 0.02]
    let verdicts = (0..<25).map { _ -> [Bool] in
        let buffer = makeBuffer(capacity: 100)
        return offsets.map { buffer.append(sample($0)) }
    }

    #expect(verdicts.allSatisfy { $0 == [false, false, true, true, true] })
}

@Test func theGateIsOrderPreservingAndDoesNotResort() {
    // Ordering and de-duplication belong to pipeline stage 1; the gate must
    // filter without rearranging, or there would be two sources of truth.
    let buffer = makeBuffer(capacity: 3)
    let offered = [0.05, -1.0, 0.01, 0.03, -0.5, 0.02]

    for offset in offered { buffer.append(sample(offset)) }

    let expected = offered.filter { $0 >= 0 }.map { anchor.uptime + $0 }
    #expect(buffer.freeze().map(\.deviceTimestamp) == expected)
}

@Test func rejectedSamplesNeverReachTheScratchFile() {
    // "Dropped at admission" has to mean the disk too: a spilled buffer must
    // not smuggle the countdown back in at freeze.
    let fileIO = FileManagerFileIO()
    let name = "test-\(UUID().uuidString).ndjson"
    let buffer = SessionSampleBuffer(fileIO: fileIO, logService: SilentBufferLog(), capacity: 2, scratchName: name)
    buffer.arm(at: anchor)

    for offset in [-3.0, -2.0, -1.0, 0.0, 0.01, 0.02, 0.03, 0.04, 0.05, 0.06] {
        buffer.append(sample(offset))
    }

    #expect(buffer.isSpilling)
    let frozen = buffer.freeze()
    #expect(frozen.count == 7)
    #expect(frozen.allSatisfy { $0.deviceTimestamp >= anchor.uptime })
}

@Test func armingAtALaterT0MovesTheBoundary() {
    // A new session is a new origin. The previous one's samples are simply
    // before this session's T-0, and get the same treatment as a countdown.
    let buffer = makeBuffer(capacity: 100)
    let later = TimeAnchor(wallClock: anchor.wallClock.addingTimeInterval(60), uptime: anchor.uptime + 60)

    buffer.append(sample(0))
    _ = buffer.freeze()

    buffer.arm(at: later)
    #expect(buffer.append(sample(30)) == false)
    #expect(buffer.append(sample(60)))
    #expect(buffer.count == 1)
}

@Test func discardingDisarmsSoTheNextSessionCannotInheritT0() {
    let buffer = makeBuffer(capacity: 100)
    buffer.append(sample(0.01))
    buffer.discard()

    #expect(buffer.isArmed == false)
    #expect(buffer.rejectedSampleCount == 0)
    #expect(buffer.append(sample(0.02)) == false)
}

@Test func theGateStillHoldsWhenSpillingIsDegraded() {
    // A disk problem must not widen the gate: rejection is independent of
    // whether the scratch file is working.
    let buffer = makeBuffer(capacity: 2, fileIO: UnwritableFileIO())

    for offset in [-1.0, 0.0, 0.01, -0.5, 0.02, 0.03] { buffer.append(sample(offset)) }

    #expect(buffer.isSpilling == false)
    #expect(buffer.count == 4)
    #expect(buffer.freeze().allSatisfy { $0.deviceTimestamp >= anchor.uptime })
}

@Test func theDropIsLoggedOnceAtFreezeWithACount() {
    let log = SilentBufferLog()
    let buffer = SessionSampleBuffer(fileIO: FileManagerFileIO(), logService: log, capacity: 100)
    buffer.arm(at: anchor)

    for offset in [-2.0, -1.0, 0.0, 0.01] { buffer.append(sample(offset)) }
    _ = buffer.freeze()

    #expect(log.entries.withLock { $0.filter { $0.contains("admission gate dropped") }.count } == 1)
    #expect(log.entries.withLock { $0.contains { $0.contains("dropped 2 pre-T-0 samples") } })
}
