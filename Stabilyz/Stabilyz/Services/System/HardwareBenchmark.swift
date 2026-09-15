// On-device calibration for Task 11.2.2 (docs/22 Phase 12).

#if DEBUG
import Foundation

/// Measures what only real hardware can answer: how long PBKDF2 takes on this
/// iPhone, and the latency the audio route reports.
///
/// **Debug builds only.** The whole file is inside `#if DEBUG`, and
/// `DebugIsolationGuardTests` holds that nothing outside a `#if DEBUG` block
/// names it, so a release build cannot reach it.
///
/// Nothing here changes the app's behaviour. The key derivation measured is the
/// real `KeyDerivation` the export uses. The audio reading comes from
/// `EngineAudioFeedbackService.debugRouteReport()`: that service is the audio
/// session's only owner (docs/10 §10.2), so the benchmark asks it rather than
/// reading the session itself.
struct HardwareBenchmark: Sendable {
    /// The iteration counts Task 11.2.2 calibrates against.
    static let iterationCounts = [100_000, 200_000, 300_000]

    struct DerivationTiming: Sendable, Equatable, Identifiable {
        let iterations: Int
        let duration: Duration

        var id: Int { iterations }

        var milliseconds: Double {
            let parts = duration.components
            return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        }
    }

    struct DerivationReport: Sendable, Equatable {
        let timings: [DerivationTiming]
        /// CommonCrypto's own calibration for `KeyDerivationPolicy.targetDuration`.
        let calibratedIterations: Int
        /// What an export on this device would actually use, after the floor
        /// and ceiling (`ArchiveFormat.exportIterations`).
        let exportIterations: Int
    }

    private let keyDerivation: KeyDerivation
    private let logService: LogService
    private let audioRoute: (@Sendable () async -> AudioRouteReport?)?

    /// - Parameter audioRoute: the audio engine's route report; nil where the
    ///   graph has no engine to ask.
    init(
        keyDerivation: KeyDerivation,
        logService: LogService,
        audioRoute: (@Sendable () async -> AudioRouteReport?)? = nil
    ) {
        self.keyDerivation = keyDerivation
        self.logService = logService
        self.audioRoute = audioRoute
    }

    /// Times one derivation per count, in order, with the archive's real shape
    /// (16-byte salt, 32-byte key). Deliberately slow: call it off the main
    /// actor (docs/14 §14.2).
    func measureKeyDerivation(iterationCounts: [Int] = Self.iterationCounts) throws -> DerivationReport {
        let passphrase = Array("stabilyz benchmark passphrase".utf8)
        let salt = [UInt8](repeating: 0x5A, count: KeyDerivationPolicy.saltByteCount)
        let clock = ContinuousClock()

        var timings: [DerivationTiming] = []
        for iterations in iterationCounts {
            let start = clock.now
            var derived = try keyDerivation.deriveKey(
                passphrase: passphrase,
                salt: salt,
                iterations: iterations,
                keyByteCount: KeyDerivationPolicy.keyByteCount
            )
            let timing = DerivationTiming(iterations: iterations, duration: start.duration(to: clock.now))
            SecureBytes.zeroize(&derived)
            timings.append(timing)
            logService.log(.info, .backup, "benchmark: PBKDF2 \(iterations) iterations took \(Int(timing.milliseconds.rounded())) ms")
        }

        let calibrated = keyDerivation.calibratedIterationCount(targetDuration: KeyDerivationPolicy.targetDuration)
        let report = DerivationReport(
            timings: timings,
            calibratedIterations: calibrated,
            exportIterations: ArchiveFormat.exportIterations(calibrated: calibrated)
        )
        logService.log(.info, .backup, "benchmark: calibration gives \(calibrated) iterations, export uses \(report.exportIterations)")
        return report
    }

    /// The route as it is right now, or nil with no audio engine to ask. Values
    /// are most meaningful while a walk's audio is active; outside one, they
    /// describe the idle route.
    func readAudio() async -> AudioRouteReport? {
        guard let report = await audioRoute?() else { return nil }
        logService.log(
            .info, .audio,
            "benchmark: output latency \(Int((report.outputLatency * 1_000).rounded())) ms, IO buffer \(Int((report.ioBufferDuration * 1_000).rounded())) ms, \(Int(report.sampleRate)) Hz, route \(report.outputPorts.joined(separator: "+"))"
        )
        return report
    }
}
#endif
