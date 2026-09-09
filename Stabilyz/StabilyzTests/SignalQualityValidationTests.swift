import Foundation
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1
private let rate = config.preprocessing.targetSampleRateHz
private let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 0)

/// A scripted session phase.
private enum Phase {
    /// Walking at 1.8 Hz.
    case walk(seconds: Double)
    /// Walking with a strong high-frequency component on top — a phone against
    /// a vibrating surface, or a rough vehicle ride.
    case walkWithVibration(seconds: Double, amplitude: Double)
    case still(seconds: Double)
}

private func samples(for phases: [Phase]) -> [SensorSample] {
    var result: [SensorSample] = []
    var t = 0.0

    for phase in phases {
        let seconds: Double
        switch phase {
        case .walk(let s), .still(let s): seconds = s
        case .walkWithVibration(let s, _): seconds = s
        }

        for _ in 0..<Int(seconds * rate) {
            let magnitude: Double
            switch phase {
            case .walk:
                magnitude = 0.5 * sin(2 * .pi * 1.8 * t)
            case .walkWithVibration(_, let amplitude):
                // 35 Hz is above the 20 Hz cleaning cutoff, so the filtered
                // channels will look fine while the raw signal does not.
                magnitude = 0.5 * sin(2 * .pi * 1.8 * t) + amplitude * sin(2 * .pi * 35 * t)
            case .still:
                magnitude = 0.001 * sin(2 * .pi * 11 * t)
            }
            result.append(
                SensorSample(
                    deviceTimestamp: t,
                    anchor: anchor,
                    acceleration: Vector3(x: 0, y: 0, z: -magnitude),
                    gravity: Vector3(x: 0, y: 0, z: -1)
                )
            )
            t += 1 / rate
        }
    }
    return result
}

private func buffer(mode: TestMode, samples: [SensorSample]) -> RawSessionBuffer {
    RawSessionBuffer(
        mode: mode,
        audioConfig: .none,
        anchor: anchor,
        series: SampleIngestion.align(samples, sampleRateHz: rate, policy: config.gapDetection),
        pedometerEvents: [],
        startedAt: anchor.wallClock,
        endedAt: anchor.wallClock.addingTimeInterval(300),
        advertisedClockElapsed: mode.advertisedDuration,
        interruptionCount: 0,
        pedometerAvailable: true
    )
}

private func report(mode: TestMode = .quickTest, _ phases: [Phase]) -> SessionQualityReport {
    let raw = samples(for: phases)
    let session = buffer(mode: mode, samples: raw)
    let series = Preprocessing.process(session.series, configuration: config)
    let segmentation = WalkingSegmentDetector.detect(
        in: series,
        pedometerEvents: session.pedometerEvents,
        configuration: config
    )
    return SignalQualityValidation.validate(
        series: series,
        segmentation: segmentation,
        buffer: session,
        configuration: config
    )
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

// MARK: - Mode minimums [PRD OQ-3]

@Test func oneHundredSecondsPassesQuickTestAndFailsFullTest() {
    // The same walk, judged against each mode's own requirement.
    let phases: [Phase] = [.walk(seconds: 105)]

    let quick = report(mode: .quickTest, phases)
    let full = report(mode: .fullTest, phases)

    #expect(quick.isValid)
    #expect(quick.invalidReason == nil)

    #expect(full.isValid == false)
    #expect(full.invalidReason == .insufficientValidWalking)
    #expect(full.requiredWalkingDuration == .seconds(240))
}

@Test func aFullLengthClockWithTooLittleWalkingStillFails() {
    // [PRD OQ-3] the clock ran the whole time, but most of it was standing.
    let result = report(mode: .quickTest, [
        .walk(seconds: 40),
        .still(seconds: 80)
    ])

    #expect(result.invalidReason == .insufficientValidWalking)
    #expect(seconds(result.excludedDuration) > 70)
    // The report says how short it fell, so the screen can explain it.
    #expect(seconds(result.walkingShortfall) > 45)
}

@Test func aSessionSpentStandingFailsAndSaysNoWalkingWasFound() {
    let result = report([.still(seconds: 120)])

    #expect(result.foundNoWalking)
    #expect(result.walkingIntervalCount == 0)
    #expect(result.invalidReason == .insufficientValidWalking)
    #expect(result.dominantFrequencies.isEmpty)
}

@Test func aComfortablyLongWalkPasses() {
    let result = report(mode: .quickTest, [.walk(seconds: 120)])

    #expect(result.isValid)
    #expect(seconds(result.validWalkingDuration) > 90)
    #expect(result.exceededNoiseLimit == false)
}

// MARK: - Noise is judged before cleaning (entry 8, BINDING)

@Test func vibrationThatTheFilterRemovesStillFailsTheNoiseGate() {
    // The whole point of entry 8. A 35 Hz component is far above the 20 Hz
    // cleaning cutoff, so the filtered channels look like a clean walk — but
    // the session was recorded against heavy vibration and must not be scored.
    let result = report(mode: .quickTest, [.walkWithVibration(seconds: 120, amplitude: 2.0)])

    #expect(result.exceededNoiseLimit)
    #expect(result.invalidReason == .excessiveNoise)
    #expect(result.highFrequencyPowerRatio > result.noiseThreshold)

    // There was plenty of walking: the failure is noise, not duration.
    #expect(seconds(result.validWalkingDuration) > 90)
    #expect(result.walkingShortfall == .zero)
}

@Test func theCleanedChannelsAloneWouldHaveLookedFine() {
    // Demonstrates the ordering matters rather than asserting it indirectly:
    // measured on the filtered channels, the same vibrating session is clean.
    let raw = samples(for: [.walkWithVibration(seconds: 120, amplitude: 2.0)])
    let session = buffer(mode: .quickTest, samples: raw)
    let series = Preprocessing.process(session.series, configuration: config)
    let segmentation = WalkingSegmentDetector.detect(in: series, configuration: config)

    let beforeCleaning = SignalQualityValidation.highFrequencyPowerRatio(
        series: series,
        segmentation: segmentation,
        configuration: config
    )

    // The same calculation over the cleaned vertical channel.
    let cleaned = segmentation.intervals.flatMap { interval -> [Double] in
        let segment = series.segments[interval.segmentIndex]
        return Array(segment.vertical[interval.startIndex..<min(interval.endIndex, segment.vertical.count)])
    }
    let highPass = Biquad.highPass(cutoffHz: config.noise.highFrequencyCutoffHz, sampleRateHz: rate)
    let filtered = highPass.filtfilt(cleaned)
    func meanSquare(_ s: [Double]) -> Double { s.reduce(0) { $0 + $1 * $1 } / Double(s.count) }
    let afterCleaning = meanSquare(filtered) / meanSquare(cleaned)

    #expect(beforeCleaning > config.noise.maximumHighFrequencyPowerRatio)
    #expect(afterCleaning < config.noise.maximumHighFrequencyPowerRatio)
}

@Test func aCleanWalkHasALowNoiseRatio() {
    let result = report(mode: .quickTest, [.walk(seconds: 120)])

    #expect(result.highFrequencyPowerRatio < config.noise.maximumHighFrequencyPowerRatio)
    #expect(result.highFrequencyPowerRatio >= 0)
}

// MARK: - Both failure modes together

@Test func bothFailuresAtOnceReportTheDurationAndRecordTheNoise() {
    // Short *and* noisy. The verdict is the plainer explanation, but the noise
    // fact stays in the report so the screen can mention both.
    let result = report(mode: .quickTest, [.walkWithVibration(seconds: 30, amplitude: 2.0)])

    #expect(result.invalidReason == .insufficientValidWalking)
    #expect(result.exceededNoiseLimit)
    #expect(seconds(result.walkingShortfall) > 55)
}

@Test func theThreeOutcomesAreDistinguishable() {
    let short = report(mode: .quickTest, [.walk(seconds: 30)])
    let noisy = report(mode: .quickTest, [.walkWithVibration(seconds: 120, amplitude: 2.0)])
    let fine = report(mode: .quickTest, [.walk(seconds: 120)])

    #expect(short.invalidReason == .insufficientValidWalking)
    #expect(short.exceededNoiseLimit == false)

    #expect(noisy.invalidReason == .excessiveNoise)
    #expect(noisy.walkingShortfall == .zero)

    #expect(fine.isValid)
}

// MARK: - The report explains its verdict [PRD §5]

@Test func theReportCarriesEverythingTheNoisyScreenNeeds() {
    let result = report(mode: .fullTest, [
        .walk(seconds: 20),
        .still(seconds: 15),
        .walk(seconds: 20)
    ])

    // Walking against the requirement.
    #expect(result.mode == .fullTest)
    #expect(result.requiredWalkingDuration == .seconds(240))
    #expect(result.validWalkingDuration > .zero)
    #expect(result.walkingShortfall > .zero)

    // Noise against its limit.
    #expect(result.noiseThreshold == config.noise.maximumHighFrequencyPowerRatio)

    // How the session was shaped.
    #expect(result.walkingIntervalCount == 2)
    #expect(result.excludedDuration > .zero)
    #expect(result.transientDuration > .zero)
    #expect(result.gapInfo == .none)
    #expect(result.interruptionCount == 0)
    #expect(result.pedometerAvailable)

    // Every verdict has its evidence behind it.
    #expect(result.isValid == false)
}

@Test func gapAndInterruptionContextReachesTheReport() {
    let before = samples(for: [.walk(seconds: 40)])
    let after = samples(for: [.walk(seconds: 40)]).map {
        SensorSample(
            deviceTimestamp: $0.deviceTimestamp + 60,
            anchor: $0.anchor,
            acceleration: $0.acceleration,
            gravity: $0.gravity
        )
    }
    var session = buffer(mode: .quickTest, samples: before + after)
    session = RawSessionBuffer(
        mode: session.mode,
        audioConfig: session.audioConfig,
        anchor: session.anchor,
        series: session.series,
        pedometerEvents: [],
        startedAt: session.startedAt,
        endedAt: session.endedAt,
        advertisedClockElapsed: session.advertisedClockElapsed,
        interruptionCount: 2,
        pedometerAvailable: false
    )

    let series = Preprocessing.process(session.series, configuration: config)
    let segmentation = WalkingSegmentDetector.detect(in: series, configuration: config)
    let result = SignalQualityValidation.validate(
        series: series, segmentation: segmentation, buffer: session, configuration: config
    )

    #expect(result.gapInfo.gapCount == 1)
    #expect(result.interruptionCount == 2)
    #expect(result.pedometerAvailable == false)
}

@Test func pedometerContextIsCarriedWithoutAffectingTheVerdict() {
    let raw = samples(for: [.walk(seconds: 120)])
    var session = buffer(mode: .quickTest, samples: raw)
    session = RawSessionBuffer(
        mode: session.mode, audioConfig: session.audioConfig, anchor: session.anchor,
        series: session.series,
        pedometerEvents: [PedometerEvent(steps: 216, timestamp: anchor.wallClock.addingTimeInterval(120))],
        startedAt: session.startedAt, endedAt: session.endedAt,
        advertisedClockElapsed: session.advertisedClockElapsed,
        interruptionCount: 0, pedometerAvailable: true
    )

    let series = Preprocessing.process(session.series, configuration: config)
    let segmentation = WalkingSegmentDetector.detect(
        in: series, pedometerEvents: session.pedometerEvents, configuration: config
    )
    let result = SignalQualityValidation.validate(
        series: series, segmentation: segmentation, buffer: session, configuration: config
    )

    #expect(result.pedometerAgreement?.pedometerSteps == 216)
    #expect(result.isValid)
}

// MARK: - Dominant frequency diagnostic (entry 9 evidence)

@Test func theDominantFrequencyOfAWalkMatchesItsStrideRate() {
    // The signal is 1.8 Hz; the diagnostic should say so.
    let result = report(mode: .quickTest, [.walk(seconds: 120)])

    #expect(result.dominantFrequencies.count == 1)
    let dominant = try! #require(result.dominantFrequencies.first)
    #expect(abs(dominant - 1.8) < 0.15)
}

@Test func eachWalkingIntervalGetsItsOwnDiagnostic() {
    let result = report(mode: .quickTest, [
        .walk(seconds: 30),
        .still(seconds: 10),
        .walk(seconds: 30)
    ])

    #expect(result.walkingIntervalCount == 2)
    #expect(result.dominantFrequencies.count == 2)
}

@Test func theDiagnosticNeverGatesTheVerdict() {
    // Entry 9: recorded, not enforced. A vibrating session fails on noise, and
    // the diagnostic is present either way.
    let noisy = report(mode: .quickTest, [.walkWithVibration(seconds: 120, amplitude: 2.0)])

    #expect(noisy.invalidReason == .excessiveNoise)
    #expect(noisy.dominantFrequencies.isEmpty == false)
}

@Test func theSearchBandComesFromTheConfiguredCadenceRange() {
    // No tunable of its own: 30-200 spm is 0.5-3.33 Hz.
    let signal = (0..<600).map { sin(2 * .pi * 1.8 * Double($0) / rate) }
    let dominant = SignalQualityValidation.dominantFrequency(
        signal, sampleRateHz: rate,
        lowHz: config.walkingDetection.plausibleCadenceRange.lowerBound / 60,
        highHz: config.walkingDetection.plausibleCadenceRange.upperBound / 60
    )

    #expect(dominant != nil)
    #expect(abs((dominant ?? 0) - 1.8) < 0.15)
}
