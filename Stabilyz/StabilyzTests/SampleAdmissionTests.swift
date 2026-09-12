import Foundation
import Testing
@testable import Stabilyz

/// The T-0 admission contract as a domain rule ([PRD OQ-6], docs/07 §7.3).
///
/// `SessionSampleBufferTests` holds the buffer to this contract; these tests
/// hold the rule itself, so a change to the comparison fails here first and
/// with a clearer cause.

private let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 1_000)

private func sample(_ offset: Double, at anchor: TimeAnchor = anchor) -> SensorSample {
    sampleAt(anchor.uptime + offset, anchor: anchor)
}

/// A sample at an exact device timestamp.
///
/// Needed for the boundary cases: at an uptime of 1000 the representable gap is
/// ~1.1e-13, so `uptime - .ulpOfOne` rounds straight back to `uptime` and would
/// test admission *at* T-0 while claiming to test just before it. `nextDown` is
/// the real predecessor at whatever magnitude the anchor happens to sit.
private func sampleAt(_ timestamp: TimeInterval, anchor: TimeAnchor = anchor) -> SensorSample {
    SensorSample(
        deviceTimestamp: timestamp,
        anchor: anchor,
        acceleration: Vector3(x: 1, y: -1, z: 1),
        gravity: Vector3(x: 0, y: 0, z: -1)
    )
}

// MARK: - The rule

@Test func theAnchorIsTheOrigin() {
    // T-0 and the session's time anchor are the same instant by construction,
    // which is what makes `startedAt` and the first admissible sample agree.
    #expect(SampleAdmission(anchor: anchor).t0 == anchor.uptime)
}

@Test func aSampleAfterT0IsAdmitted() {
    #expect(SampleAdmission(anchor: anchor).admits(sample(0.01)))
}

@Test func aSampleBeforeT0IsNot() {
    #expect(SampleAdmission(anchor: anchor).admits(sample(-0.01)) == false)
}

@Test func theBoundaryIsClosedOnTheSessionsSide() {
    // Exactly at T-0 is the first sample of the walk, not the last of the
    // countdown — at-or-after, never strictly after.
    let admission = SampleAdmission(anchor: anchor)

    #expect(admission.admits(sample(0)))
    #expect(admission.admits(sampleAt(anchor.uptime.nextDown)) == false)
}

@Test func theVerdictAtTheBoundaryIsDeterministic() {
    let admission = SampleAdmission(anchor: anchor)
    let exactly = sample(0)

    #expect((0..<100).allSatisfy { _ in admission.admits(exactly) })
}

// MARK: - Filtering a batch

@Test func filteringKeepsOnlyTheSessionsOwnSamples() {
    let admission = SampleAdmission(anchor: anchor)
    let offered = [-5.0, -1.0, -0.001, 0.0, 0.01, 0.02].map { sample($0) }

    let admitted = admission.admitting(offered)

    #expect(admitted.count == 3)
    #expect(admitted.allSatisfy(admission.admits))
}

@Test func filteringPreservesTheOrderGiven() {
    // Ordering and de-duplication are pipeline stage 1's job (docs/08). The
    // rule filters; it must not quietly also sort.
    let admission = SampleAdmission(anchor: anchor)
    let offered = [0.05, -1.0, 0.01, 0.03, -0.5, 0.02]

    let admitted = admission.admitting(offered.map { sample($0) })

    #expect(admitted.map(\.deviceTimestamp) == offered.filter { $0 >= 0 }.map { anchor.uptime + $0 })
}

@Test func filteringAnEmptyBatchIsEmpty() {
    #expect(SampleAdmission(anchor: anchor).admitting([]).isEmpty)
}

@Test func aBatchEntirelyBeforeT0FiltersToNothing() {
    // The whole countdown, and not one sample of it survives.
    let admission = SampleAdmission(anchor: anchor)
    let countdown = stride(from: -5.0, to: 0, by: 0.01).map { sample($0) }

    #expect(countdown.count == 500)
    #expect(admission.admitting(countdown).isEmpty)
}

// MARK: - The rule is about uptime, not wall clock

@Test func theBoundaryDoesNotMoveWithTheWallClock() {
    // Durations and ordering come from the monotonic timebase alone
    // (docs/07 §7.4), so an NTP correction or a timezone change mid-countdown
    // cannot shift where the session starts.
    let shifted = TimeAnchor(wallClock: anchor.wallClock.addingTimeInterval(-3_600), uptime: anchor.uptime)

    #expect(SampleAdmission(anchor: shifted) == SampleAdmission(anchor: anchor))
    #expect(SampleAdmission(anchor: shifted).admits(sample(0)))
}

@Test func aLaterAnchorIsALaterBoundary() {
    let later = TimeAnchor(wallClock: anchor.wallClock.addingTimeInterval(60), uptime: anchor.uptime + 60)
    let admission = SampleAdmission(anchor: later)

    #expect(admission.admits(sample(30)) == false)
    #expect(admission.admits(sample(60)))
}

// MARK: - The frozen buffer's invariant

private func rawBuffer(offsets: [Double]) -> RawSessionBuffer {
    RawSessionBuffer(
        mode: .quickTest,
        audioConfig: .none,
        anchor: anchor,
        series: AlignedSampleSeries(samples: offsets.map { sample($0) }, gaps: []),
        pedometerEvents: [],
        startedAt: anchor.wallClock,
        endedAt: anchor.wallClock.addingTimeInterval(120),
        advertisedClockElapsed: .seconds(120),
        interruptionCount: 0,
        pedometerAvailable: true
    )
}

@Test func aBufferStartingAtT0HonoursTheContract() {
    #expect(rawBuffer(offsets: [0, 0.01, 0.02]).honoursAdmissionContract)
}

@Test func aBufferStartingAfterT0HonoursIt() {
    // Normal: the first sample lands a fraction of a period after Go.
    #expect(rawBuffer(offsets: [0.004, 0.014, 0.024]).honoursAdmissionContract)
}

@Test func aBufferCarryingACountdownSampleBreachesTheContract() {
    // The invariant has to be able to fail, or it asserts nothing. A breach
    // means the gate was bypassed upstream — the buffer reports it rather than
    // filtering, so the bug is findable.
    #expect(rawBuffer(offsets: [-0.01, 0, 0.01]).honoursAdmissionContract == false)
}

@Test func anEmptyBufferHonoursItVacuously() {
    // Sensor failure is docs/08 stage 1's call, not the admission rule's.
    #expect(rawBuffer(offsets: []).honoursAdmissionContract)
}

@Test func theBufferExposesTheRuleItWasGatedBy() {
    #expect(rawBuffer(offsets: [0]).admission == SampleAdmission(anchor: anchor))
}
