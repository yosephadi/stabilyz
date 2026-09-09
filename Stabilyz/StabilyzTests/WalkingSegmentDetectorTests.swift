import Foundation
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1
private let policy = config.walkingDetection
private let rate = config.preprocessing.targetSampleRateHz
private let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 0)

/// One phase of a scripted session.
private enum Phase {
    /// Walking at 1.8 Hz with trunk-scale amplitude.
    case walk(seconds: Double)
    /// Standing: essentially no trunk acceleration.
    case still(seconds: Double)

    var seconds: Double {
        switch self {
        case .walk(let s), .still(let s): s
        }
    }
}

/// Builds a capture from a script, so a test states the session's structure and
/// then asserts what came out of it.
private func session(_ phases: [Phase]) -> [SensorSample] {
    var samples: [SensorSample] = []
    var t = 0.0

    for phase in phases {
        let count = Int(phase.seconds * rate)
        for _ in 0..<count {
            let magnitude: Double
            switch phase {
            case .walk:
                magnitude = 0.5 * sin(2 * .pi * 1.8 * t)
            case .still:
                // Not perfectly zero: a real phone at rest still registers a
                // little sensor noise.
                magnitude = 0.001 * sin(2 * .pi * 11 * t)
            }
            samples.append(
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
    return samples
}

private func detect(_ phases: [Phase], pedometer: [PedometerEvent] = []) -> WalkingSegmentation {
    let series = Preprocessing.process(
        SampleIngestion.align(session(phases), sampleRateHz: rate, policy: config.gapDetection),
        configuration: config
    )
    return WalkingSegmentDetector.detect(in: series, pedometerEvents: pedometer, configuration: config)
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

// MARK: - The scripted session [PRD §6]

@Test func walkPauseStandWalkYieldsExactlyTwoWalkingIntervals() {
    // The PRD's own edge case: the user answers the door mid-session.
    let result = detect([
        .walk(seconds: 20),
        .still(seconds: 10),
        .walk(seconds: 20)
    ])

    #expect(result.intervals.count == 2)
    #expect(result.foundNoWalking == false)

    // Each bout is 20 s minus 1 s initiation and 1 s termination.
    for interval in result.intervals {
        #expect(abs(seconds(interval.duration) - 18) < 1.5)
    }
}

@Test func standingTimeNeverCountsTowardValidWalking() {
    // [PRD OQ-3] pauses, setup and standing do not count, even though the clock
    // ran the whole time.
    let result = detect([
        .walk(seconds: 20),
        .still(seconds: 30),
        .walk(seconds: 20)
    ])

    // 40 s of walking in a 70 s session, less 4 s of trimmed transients.
    #expect(seconds(result.walkingDuration) < 40)
    #expect(seconds(result.walkingDuration) > 32)
    // The standing shows up as excluded, not as walking.
    #expect(seconds(result.excludedDuration) > 25)
}

@Test func setupTimeAtTheStartIsExcluded() {
    // Standing while starting the session is not walking.
    let result = detect([
        .still(seconds: 15),
        .walk(seconds: 30)
    ])

    #expect(result.intervals.count == 1)
    let interval = try! #require(result.intervals.first)
    // The walking starts around 15 s in, plus the initiation trim.
    #expect(interval.startTimestamp > 15)
    #expect(interval.startTimestamp < 18)
}

// MARK: - The stage-3 failure path (docs/08)

@Test func aSessionSpentEntirelyStandingFindsNoWalking() {
    // docs/08 stage 3: zero walking intervals is the failure condition that
    // routes the session to the noisy/insufficient-data path.
    let result = detect([.still(seconds: 120)])

    #expect(result.foundNoWalking)
    #expect(result.intervals.isEmpty)
    #expect(result.walkingDuration == .zero)
    // The time is accounted for as excluded rather than silently vanishing.
    #expect(seconds(result.excludedDuration) > 100)
}

@Test func anEmptySeriesFindsNoWalking() {
    let empty = Preprocessing.process(
        SampleIngestion.align([], sampleRateHz: rate, policy: config.gapDetection),
        configuration: config
    )
    let result = WalkingSegmentDetector.detect(in: empty, configuration: config)

    #expect(result.foundNoWalking)
    #expect(result.walkingDuration == .zero)
}

// MARK: - Transients [PRD OQ-1, Tura note]

@Test func gaitInitiationAndTerminationAreTrimmedFromEachBout() {
    let result = detect([.walk(seconds: 30)])
    let interval = try! #require(result.intervals.first)

    // 30 s of movement, less 1 s at each end.
    #expect(abs(seconds(interval.duration) - 28) < 1.5)
    #expect(seconds(result.transientDuration) > 1.5)
    // The interval does not start at the very beginning of the movement.
    #expect(interval.startTimestamp > 0.5)
}

@Test func aBoutThatIsAllTransientIsDiscardedAndCounted() {
    // Two seconds of walking is entirely initiation and termination.
    let result = detect([
        .still(seconds: 10),
        .walk(seconds: 2),
        .still(seconds: 10)
    ])

    #expect(result.foundNoWalking)
    #expect(result.discardedBoutCount >= 1)
}

@Test func aBoutShorterThanTheMinimumIsDiscarded() {
    // 3.5 s of movement leaves 1.5 s after trimming, below the 3 s minimum.
    let result = detect([
        .still(seconds: 10),
        .walk(seconds: 3.5),
        .still(seconds: 10)
    ])

    #expect(result.intervals.isEmpty)
    #expect(result.discardedBoutCount >= 1)
}

// MARK: - Bridging

@Test func aBriefHesitationDoesNotSplitOneWalkIntoTwo() {
    // Pausing momentarily at a kerb is one walk, not two.
    let result = detect([
        .walk(seconds: 15),
        .still(seconds: 0.3),
        .walk(seconds: 15)
    ])

    #expect(result.intervals.count == 1)
    #expect(seconds(result.walkingDuration) > 25)
}

@Test func aRealPauseDoesSplitTheWalk() {
    let result = detect([
        .walk(seconds: 15),
        .still(seconds: 8),
        .walk(seconds: 15)
    ])

    #expect(result.intervals.count == 2)
}

// MARK: - Pedometer is a hint, never authority

@Test func pedometerAgreementIsRecordedWithoutChangingTheResult() {
    let phases: [Phase] = [.walk(seconds: 30)]
    let withoutPedometer = detect(phases)
    let withPedometer = detect(
        phases,
        pedometer: [PedometerEvent(steps: 54, timestamp: anchor.wallClock.addingTimeInterval(30))]
    )

    // The accelerometer decides; the hint only annotates.
    #expect(withPedometer.intervals == withoutPedometer.intervals)
    #expect(withPedometer.walkingDuration == withoutPedometer.walkingDuration)

    let agreement = try! #require(withPedometer.pedometerAgreement)
    #expect(agreement.pedometerSteps == 54)
    #expect(agreement.isPlausible)
}

@Test func disagreementIsInformationNotAnError() {
    // The pedometer counted nothing across a walk we clearly detected. That is
    // recorded, and the session proceeds on the accelerometer's evidence.
    let result = detect(
        [.walk(seconds: 30)],
        pedometer: [PedometerEvent(steps: 0, timestamp: anchor.wallClock)]
    )

    let agreement = try! #require(result.pedometerAgreement)
    #expect(agreement.disagreesOnWalkingPresence)
    #expect(result.intervals.isEmpty == false)
    #expect(result.walkingDuration > .zero)
}

@Test func anImplausibleCadenceIsFlaggedButNotEnforced() {
    // 600 steps in 30 seconds is not walking, but it does not invalidate the
    // accelerometer's own finding.
    let result = detect(
        [.walk(seconds: 30)],
        pedometer: [PedometerEvent(steps: 600, timestamp: anchor.wallClock.addingTimeInterval(30))]
    )

    let agreement = try! #require(result.pedometerAgreement)
    #expect(agreement.isPlausible == false)
    #expect(result.foundNoWalking == false)
}

@Test func noPedometerDataMeansNoAgreementRatherThanDisagreement() {
    // A session recorded without the pedometer must not look like a conflict.
    let result = detect([.walk(seconds: 30)])
    #expect(result.pedometerAgreement == nil)
}

// MARK: - Counts flow forward to stage 4

@Test func discardedSegmentCountIsCarriedForwardFromPreprocessing() {
    // A sliver between dropouts is dropped in stage 2; stage 4 still needs to
    // know the session was fragmented.
    let long = session([.walk(seconds: 20)])
    let sliver = session([.walk(seconds: 0.5)]).map {
        SensorSample(
            deviceTimestamp: $0.deviceTimestamp + 60,
            anchor: $0.anchor,
            acceleration: $0.acceleration,
            gravity: $0.gravity
        )
    }

    let series = Preprocessing.process(
        SampleIngestion.align(long + sliver, sampleRateHz: rate, policy: config.gapDetection),
        configuration: config
    )
    let result = WalkingSegmentDetector.detect(in: series, configuration: config)

    #expect(series.discardedSegmentCount == 1)
    #expect(result.discardedSegmentCount == 1)
}

@Test func everySampleIsAccountedForAsWalkingTransientOrExcluded() {
    // Nothing should silently disappear between stages.
    let result = detect([
        .walk(seconds: 20),
        .still(seconds: 10),
        .walk(seconds: 20)
    ])

    let total = seconds(result.walkingDuration)
        + seconds(result.transientDuration)
        + seconds(result.excludedDuration)
    #expect(abs(total - 50) < 1.0)
}

// MARK: - Interval placement

@Test func intervalsStayOnTheSessionTimeline() {
    let result = detect([.still(seconds: 12), .walk(seconds: 20)])
    let interval = try! #require(result.intervals.first)

    #expect(interval.endTimestamp > interval.startTimestamp)
    #expect(interval.endTimestamp < 32.5)
    #expect(interval.sampleRateHz == rate)
}
