import Foundation
@testable import Stabilyz

// MARK: - Signal specification

/// The parameters a synthetic session is generated from.
///
/// A golden case stores this rather than a waveform: the signal is reproducible
/// from a handful of numbers a reviewer can read, and every expected value can
/// be traced back to a parameter that produced it.
struct GoldenSignalSpec: Codable, Equatable {
    /// Total session length.
    var seconds: Double
    /// Duration of the first half-cycle. Unequal halves are timing asymmetry.
    var firstHalf: Double = 0.55
    /// Duration of the second half-cycle.
    var secondHalf: Double = 0.55
    /// How hard the first footfall lands. Unequal amplitudes separate Ad1 from
    /// Ad2 without being timing asymmetry.
    var firstAmplitude: Double = 1.0
    var secondAmplitude: Double = 1.0
    /// Whether the trunk leans opposite ways on consecutive footfalls — the
    /// reliability gate for asymmetry (docs/decisions.md entry 13).
    var mediolateralAlternates: Bool = true
    /// Deterministic wobble added to step times, in seconds.
    var stepJitter: Double = 0
    /// Amplitude of an added high-frequency component.
    var vibrationAmplitude: Double = 0
    /// Frequency of that component. Above the 20 Hz cleaning cutoff it is
    /// removed from the channels but still judged by the noise gate (entry 8).
    var vibrationHz: Double = 35
    /// Seconds of walking before a standing pause, if any.
    var walkBeforePause: Double?
    /// Length of that pause.
    var pauseSeconds: Double?
    /// Seconds of walking before a sensor dropout, if any.
    var walkBeforeGap: Double?
    /// Length of that dropout — no samples at all.
    var gapSeconds: Double?

    var strideSeconds: Double { firstHalf + secondHalf }
    /// Cadence the signal was built to produce, steps per minute.
    var expectedCadence: Double { 120 / strideSeconds }
    /// `(τ2 − τ1) / (τ1 + τ2)` for these half-cycles — the analytic asymmetry.
    var expectedAsymmetry: Double {
        abs(secondHalf - firstHalf) / strideSeconds
    }
}

// MARK: - Generation

enum GoldenSignal {
    static let sampleRate = AlgorithmConfiguration.v1.preprocessing.targetSampleRateHz
    static let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 0)

    private static func pulse(phase: Double, width: Double) -> Double {
        phase < width ? sin(.pi * phase / width) : 0
    }

    /// Builds the sample stream for a spec.
    ///
    /// Walking is periodic footfalls; a pause is a stretch of near-stillness; a
    /// gap is samples that simply are not there, which is how a suspension
    /// arrives from CoreMotion.
    static func samples(for spec: GoldenSignalSpec, pulseWidth: Double = 0.12) -> [SensorSample] {
        var footfalls: [(time: Double, amplitude: Double, lean: Double)] = []
        var cursor = 0.0
        var index = 0

        let pauseStart = spec.walkBeforePause
        let pauseEnd: Double? = if let start = spec.walkBeforePause, let length = spec.pauseSeconds {
            start + length
        } else {
            nil
        }

        while cursor < spec.seconds + spec.strideSeconds {
            let isFirst = index.isMultiple(of: 2)
            let inPause = pauseStart.map { cursor >= $0 && cursor < (pauseEnd ?? $0) } ?? false
            if !inPause {
                let wobble = spec.stepJitter * ((index % 3 == 0) ? 1.0 : (index % 3 == 1 ? -1.0 : 0.4))
                footfalls.append((
                    cursor + wobble,
                    isFirst ? spec.firstAmplitude : spec.secondAmplitude,
                    spec.mediolateralAlternates ? (isFirst ? 1.0 : -1.0) : 1.0
                ))
            }
            cursor += isFirst ? spec.firstHalf : spec.secondHalf
            index += 1
        }

        let gapStart = spec.walkBeforeGap
        let gapEnd: Double? = if let start = spec.walkBeforeGap, let length = spec.gapSeconds {
            start + length
        } else {
            nil
        }

        return (0..<Int(spec.seconds * sampleRate)).compactMap { sampleIndex in
            let time = Double(sampleIndex) / sampleRate

            // A dropout is absence, not silence.
            if let gapStart, let gapEnd, time >= gapStart, time < gapEnd { return nil }

            var vertical = 0.0
            var mediolateral = 0.0
            for footfall in footfalls where time >= footfall.time && time < footfall.time + pulseWidth {
                let shape = pulse(phase: time - footfall.time, width: pulseWidth)
                vertical += footfall.amplitude * shape
                mediolateral += footfall.lean * 0.4 * shape
            }
            if spec.vibrationAmplitude > 0 {
                vertical += spec.vibrationAmplitude * sin(2 * .pi * spec.vibrationHz * time)
            }

            return SensorSample(
                deviceTimestamp: time,
                anchor: anchor,
                acceleration: Vector3(x: mediolateral, y: 0, z: -vertical),
                gravity: Vector3(x: 0, y: 0, z: -1)
            )
        }
    }

    /// `audioConfig` is a parameter only so Task 7.2.3 can vary it and show it
    /// changes nothing. Every golden case uses the default.
    static func buffer(
        for spec: GoldenSignalSpec,
        mode: TestMode,
        audioConfig: SessionAudioConfig = .none
    ) -> RawSessionBuffer {
        let raw = samples(for: spec)
        let aligned = SampleIngestion.align(
            raw,
            sampleRateHz: sampleRate,
            policy: AlgorithmConfiguration.v1.gapDetection
        )
        return RawSessionBuffer(
            mode: mode,
            audioConfig: audioConfig,
            anchor: anchor,
            series: aligned,
            pedometerEvents: [],
            startedAt: anchor.wallClock,
            endedAt: anchor.wallClock.addingTimeInterval(spec.seconds),
            advertisedClockElapsed: .seconds(spec.seconds),
            interruptionCount: 0,
            pedometerAvailable: false
        )
    }
}

// MARK: - Golden case

/// Which profile a case runs under.
enum GoldenProfile: String, Codable {
    case none
    case unilateral
    case bilateral

    var profile: UserProfile? {
        switch self {
        case .none: nil
        case .unilateral: UserProfile.fixture(level: .transtibial, side: .left)
        case .bilateral: UserProfile.fixture(level: .bilateral, side: .both)
        }
    }
}

/// One recorded end-to-end result.
///
/// `derived` values are computable from the signal parameters and are asserted
/// against physics. `recorded` values have no closed form and exist as
/// regression anchors — see Goldens/README.md.
struct GoldenCase: Codable, Equatable {
    var name: String
    var notes: String
    var mode: String
    var profile: GoldenProfile
    var signal: GoldenSignalSpec
    /// When present, five sessions are generated from this spec and a real
    /// baseline is built from them before `signal` is scored against it.
    var calibration: GoldenSignalSpec?
    var expected: GoldenExpectation

    var testMode: TestMode { TestMode(rawValue: mode) ?? .quickTest }
}

struct GoldenExpectation: Codable, Equatable {
    var valid: Bool
    var invalidReason: String?
    /// Derived: from the mode minimum and the signal's walking content.
    var validWalkingSeconds: Double
    /// Derived: 120 / stride seconds.
    var cadenceMean: Double?
    /// Derived: |secondHalf − firstHalf| / stride, or absent.
    var stepTimeAsymmetry: Double?
    /// True when asymmetry is reported at all — the nil-versus-zero distinction.
    var asymmetryReported: Bool
    /// Recorded regression anchors.
    var stepRegularity: Double?
    var strideRegularity: Double?
    var stepTimeCV: Double?
    var trunkMotionML: Double?
    var trunkMotionVT: Double?
    var validStrideCount: Int?
    var windowCount: Int?
    /// Derived: a calibration session scored against its own baseline sits at
    /// the centre by construction.
    var calibrationRelativeIndex: Int?
    /// Recorded: the scored session's index. The signal-level deviation has no
    /// closed form, so this is a regression anchor.
    var relativeIndex: Int?
    /// Recorded: the composite the index was mapped from.
    var compositeZ: Double?
    /// Quality facts.
    var exceededNoiseLimit: Bool
    var highFrequencyPowerRatio: Double
    var gapCount: Int
}

// MARK: - Storage

/// Golden files live beside the tests in the source tree, not in the test
/// bundle: they are meant to be read and diffed in review, and a bundle
/// resource is neither.
enum GoldenStore {
    static func directory(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: String(describing: file))
            .deletingLastPathComponent()
            .appendingPathComponent("Goldens")
    }

    static func load(_ name: String) throws -> GoldenCase {
        let url = directory().appendingPathComponent("\(name).json")
        return try JSONDecoder().decode(GoldenCase.self, from: try Data(contentsOf: url))
    }

    static func write(_ golden: GoldenCase) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory(), withIntermediateDirectories: true)
        try encoder.encode(golden).write(to: directory().appendingPathComponent("\(golden.name).json"))
    }

    /// Regeneration is opt-in and explicit. See Goldens/README.md: a failing
    /// golden is either a regression to fix or an intended change to approve.
    /// There is no third option, and nothing here runs by default.
    static var isRegenerating: Bool {
        ProcessInfo.processInfo.environment["STABILYZ_REGENERATE_GOLDENS"] == "1"
    }
}

// MARK: - Scored cases

extension GoldenSignal {
    /// Builds a real baseline by running five calibration sessions through the
    /// pipeline and the calculation service — the same path the app takes.
    static func baseline(
        from spec: GoldenSignalSpec,
        mode: TestMode,
        profile: UserProfile?,
        configuration: AlgorithmConfiguration
    ) async throws -> Baseline {
        let pipeline = GaitAnalysisPipeline(configuration: configuration)
        var sessions: [GaitSession] = []

        for index in 0..<Baseline.requiredValidSessionCount {
            let session = buffer(for: spec, mode: mode)
            let outcome = try await pipeline.analyze(
                buffer: session, baseline: nil, profile: profile, progress: { _ in }
            )
            guard case .valid(let metrics, let walking, _) = outcome else {
                throw GoldenError.calibrationSessionInvalid
            }
            // Distinct start times so the set is chronological and distinct.
            let start = anchor.wallClock.addingTimeInterval(Double(index) * 86_400)
            sessions.append(
                GaitSession.valid(
                    id: UUID(), mode: mode, startedAt: start,
                    endedAt: start.addingTimeInterval(spec.seconds),
                    advertisedClockElapsed: mode.advertisedDuration,
                    validWalkingDuration: walking, metrics: metrics,
                    audioConfig: .none, algorithmVersion: configuration.version,
                    appVersion: "1.0", deviceModel: "iPhone17,1"
                )
            )
        }

        return try BaselineCalculationService.calculate(
            from: sessions, mode: mode,
            establishedAt: anchor.wallClock.addingTimeInterval(500_000),
            configuration: configuration
        )
    }

    enum GoldenError: Error { case calibrationSessionInvalid }
}
