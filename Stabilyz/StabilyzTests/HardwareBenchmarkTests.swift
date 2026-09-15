#if DEBUG
import Foundation
import Testing
@testable import Stabilyz

/// The debug-only on-device benchmark (Task 11.2.2). What it reports is only
/// meaningful on hardware; these pin that it measures what it says it measures.

private struct CountingDerivation: KeyDerivation {
    let calibration: Int
    let asked = Locked<[Int]>([])

    func deriveKey(passphrase: [UInt8], salt: [UInt8], iterations: Int, keyByteCount: Int) throws -> [UInt8] {
        asked.withLock { $0.append(iterations) }
        return [UInt8](repeating: 1, count: keyByteCount)
    }

    func calibratedIterationCount(targetDuration: TimeInterval) -> Int { calibration }
}

private final class QuietLog: LogService, @unchecked Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

@Test func theBenchmarkTimesEachIterationCountInOrder() throws {
    let derivation = CountingDerivation(calibration: 1_200_000)
    let benchmark = HardwareBenchmark(keyDerivation: derivation, logService: QuietLog())

    let report = try benchmark.measureKeyDerivation()

    #expect(HardwareBenchmark.iterationCounts == [100_000, 200_000, 300_000])
    #expect(derivation.asked.withLock { $0 } == [100_000, 200_000, 300_000])
    #expect(report.timings.map(\.iterations) == [100_000, 200_000, 300_000])
    #expect(report.timings.allSatisfy { $0.milliseconds >= 0 })
    #expect(report.calibratedIterations == 1_200_000)
    #expect(report.exportIterations == ArchiveFormat.exportIterations(calibrated: 1_200_000))
}

@Test func theRealDerivationIsMeasurableOnThisMachine() throws {
    let benchmark = HardwareBenchmark(keyDerivation: CommonCryptoKeyDerivation(), logService: QuietLog())

    let report = try benchmark.measureKeyDerivation(iterationCounts: [1_000])

    #expect(report.timings.count == 1)
    #expect(report.timings[0].milliseconds > 0)
    #expect(report.exportIterations >= KeyDerivationPolicy.minimumIterations)
}

@Test func withNoAudioEngineThereIsNoRouteToReport() async {
    let benchmark = HardwareBenchmark(keyDerivation: CountingDerivation(calibration: 0), logService: QuietLog())
    #expect(await benchmark.readAudio() == nil)
}

@Test func theAudioRouteComesFromTheSessionsOwner() async {
    let engine = EngineAudioFeedbackService(logService: QuietLog())
    let benchmark = HardwareBenchmark(
        keyDerivation: CountingDerivation(calibration: 0),
        logService: QuietLog(),
        audioRoute: { await engine.debugRouteReport() }
    )

    let report = await benchmark.readAudio()
    #expect(report != nil)
    #expect((report?.ioBufferDuration ?? -1) >= 0)
}
#endif
